"""Benchmarks T14 (R15, attach latency) and T15 (R16, added input latency) for `cmux tmux-mirror`.

Run through scripts/remote-tmux-local-bench.sh. Both measure from outside the app:

- T14 starts a private server with N sessions of M windows, asks the socket to mirror it, and
  times from the request to the moment every session reports all M windows mirrored. It repeats
  that `--runs` times and compares the median with `--attach-limit-ms`.
- T15 types `--keystrokes` characters into one pane twice: once through the local mirror, and
  once through a plain `tmux attach` client running in an ordinary cmux terminal. A separate
  control-mode client (`tmux -C`) timestamps the pane's echo. The added latency is the mirror's
  95th percentile minus the plain client's, compared with `--added-p95-limit-ms`.

Results go to <artifacts>/bench.json. Exit status: 0 when both hold; otherwise the number of
benchmarks that failed or could not run because the local transport is missing.
"""

from __future__ import annotations

import argparse
import json
import os
import pty
import select
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    CheckFailed, Harness, Mirror, Tmux, local_host, wait_until,
)


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


class EchoObserver:
    """A tmux control-mode client on its own pty that timestamps `%output` for one pane."""

    def __init__(self, server, session, pane_id):
        self.pane_id = pane_id
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(server.argv("-C", "attach-session", "-r", "-t", f"={session}"),
                                     env=server.env(), stdin=slave, stdout=slave, stderr=slave,
                                     close_fds=True, start_new_session=True)
        os.close(slave)
        self.buffer = b""

    def drain(self):
        while True:
            ready, _, _ = select.select([self.master], [], [], 0)
            if not ready:
                return
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buffer += chunk

    def wait_for(self, char, timeout=2.0):
        """Returns the monotonic time at which `%output <pane> ...char...` arrived."""
        needle = f"%output {self.pane_id} ".encode()
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line.startswith(needle) and char.encode() in line[len(needle):]:
                    return time.monotonic()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CheckFailed(f"no echo of {char!r} on {self.pane_id} within {timeout}s")
            ready, _, _ = select.select([self.master], [], [], remaining)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    raise CheckFailed("the observer's control client ended")
                self.buffer += chunk

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        os.close(self.master)


def measure_typing(cmux, surface_id, observer, keystrokes):
    alphabet = "abcdefghijklmnopqrstuvwxyz"
    samples = []
    for i in range(keystrokes):
        char = alphabet[i % len(alphabet)]
        observer.drain()
        observer.buffer = b""
        start = time.monotonic()
        cmux.result("surface.send_text", {"surface_id": surface_id, "text": char}, timeout=10.0)
        arrived = observer.wait_for(char)
        samples.append((arrived - start) * 1000.0)
    return samples


def bench_attach(h, args, report):
    server = Tmux(os.path.join(h.state, "attach.sock"), h.tmux_bin)
    sessions = [f"b{i:02d}" for i in range(args.sessions)]
    try:
        for name in sessions:
            server.new_session(name)
            for _ in range(args.windows - 1):
                server.run("new-window", "-d", "-t", f"={name}")
        mirror = Mirror(h.cmux, local_host(server.socket_path))
        if not h.features.get("rpc"):
            report["T14"] = {"status": "NOT-IMPLEMENTED", "detail": h.feature_notes.get("rpc")}
            return False
        timings = []
        for run in range(args.runs):
            start = time.monotonic()
            mirror.attach()

            def all_published():
                for name in sessions:
                    shape = mirror.shape(name)
                    if shape is None or len(shape) != args.windows:
                        return False
                return True
            wait_until(all_published, timeout=30.0, interval=0.005, what="every workspace published")
            timings.append((time.monotonic() - start) * 1000.0)
            print(f"    run {run + 1}: {timings[-1]:.0f} ms", flush=True)
            mirror.detach_all(sessions)
            wait_until(lambda: not server.control_clients(), timeout=15.0, what="the mirror to detach")
        median = statistics.median(timings)
        ok = median <= args.attach_limit_ms
        report["T14"] = {
            "status": "PASS" if ok else "FAIL",
            "requirement": "R15",
            "sessions": args.sessions, "windows": args.windows,
            "runs_ms": [round(t, 1) for t in timings],
            "median_ms": round(median, 1), "limit_ms": args.attach_limit_ms,
        }
        print(f"=== T14 (R15): median {median:.0f} ms against a limit of {args.attach_limit_ms} ms: "
              f"{'PASS' if ok else 'FAIL'}", flush=True)
        return ok
    finally:
        server.kill()


def bench_input(h, args, report):
    server = Tmux(os.path.join(h.state, "input.sock"), h.tmux_bin)
    observer = None
    plain_workspace = None
    try:
        # The pane echoes each byte as it arrives: non-canonical mode with echo on, input discarded.
        server.new_session("bench", command="/bin/sh -c 'stty -icanon echo; exec cat > /dev/null'")
        pane = server.panes("=bench:0")[0]
        observer = EchoObserver(server, "bench", pane)
        wait_until(lambda: len(server.control_clients()) >= 1, timeout=10.0, what="the observer to attach")

        # Baseline: a plain tmux client in an ordinary cmux terminal.
        # Started through the public `new-workspace --command`, so the client runs as the
        # workspace's own command instead of depending on a shell prompt being ready.
        before = h.cmux.workspace_ids()
        attach_cmd = (f"env -u TMUX -u TMUX_PANE {h.tmux_bin} -f /dev/null -S {server.socket_path} "
                      f"attach-session -t =bench")
        rc, out, err = h.app.cli(["new-workspace", "--command", attach_cmd, "--focus", "false"])
        if rc != 0:
            raise CheckFailed(f"new-workspace failed ({rc}: {(out + err).strip()[:200]})")
        new_ids = wait_until(lambda: h.cmux.workspace_ids() - before, timeout=10.0,
                             what="the plain-client workspace to appear")
        plain_workspace = sorted(new_ids)[0]
        wait_until(lambda: any(not c["control"] for c in server.clients()), timeout=20.0,
                   what="the plain tmux client to attach")
        surfaces = h.cmux.result("surface.list", {"workspace_id": plain_workspace}).get("surfaces") or []
        plain_surface = str(surfaces[0].get("id"))
        time.sleep(0.5)
        plain = measure_typing(h.cmux, plain_surface, observer, args.keystrokes)
        h.cmux.call("workspace.close", {"workspace_id": plain_workspace})
        plain_workspace = None
        wait_until(lambda: not any(not c["control"] for c in server.clients()), timeout=10.0,
                   what="the plain client to go away")
        plain_p95 = percentile(plain, 0.95)
        print(f"    plain client: p50 {percentile(plain, 0.5):.1f} ms, p95 {plain_p95:.1f} ms", flush=True)

        if not h.features.get("rpc"):
            report["T15"] = {"status": "NOT-IMPLEMENTED", "detail": h.feature_notes.get("rpc"),
                             "plain_p95_ms": round(plain_p95, 2)}
            return False
        mirror = Mirror(h.cmux, local_host(server.socket_path))
        mirror.attach(session="bench")
        surface = wait_until(lambda: mirror.surface_for_pane("bench", pane), timeout=15.0,
                             what="the mirrored pane's surface")
        time.sleep(0.5)
        mirrored = measure_typing(h.cmux, surface, observer, args.keystrokes)
        mirror.detach("bench")
        mirror_p95 = percentile(mirrored, 0.95)
        added = mirror_p95 - plain_p95
        ok = added <= args.added_p95_limit_ms
        report["T15"] = {
            "status": "PASS" if ok else "FAIL",
            "requirement": "R16",
            "keystrokes": args.keystrokes,
            "plain_p50_ms": round(percentile(plain, 0.5), 2), "plain_p95_ms": round(plain_p95, 2),
            "mirror_p50_ms": round(percentile(mirrored, 0.5), 2), "mirror_p95_ms": round(mirror_p95, 2),
            "added_p95_ms": round(added, 2), "limit_ms": args.added_p95_limit_ms,
        }
        print(f"=== T15 (R16): mirror p95 {mirror_p95:.1f} ms, plain p95 {plain_p95:.1f} ms, added {added:.1f} ms "
              f"against a limit of {args.added_p95_limit_ms} ms: {'PASS' if ok else 'FAIL'}", flush=True)
        return ok
    finally:
        if plain_workspace:
            h.cmux.call("workspace.close", {"workspace_id": plain_workspace})
        if observer:
            observer.close()
        server.kill()


def main():
    parser = argparse.ArgumentParser(description="R15 and R16 benchmarks for cmux tmux-mirror.")
    parser.add_argument("--artifacts")
    parser.add_argument("--sessions", type=int, default=10)
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--attach-limit-ms", type=float, default=1000.0)
    parser.add_argument("--keystrokes", type=int, default=200)
    parser.add_argument("--added-p95-limit-ms", type=float, default=5.0)
    parser.add_argument("--only", choices=["attach", "input"])
    args = parser.parse_args()

    h = Harness("remote-tmux-local-bench", "T14 T15")
    h.setup(args)
    report = {"tmux": h.tmux_bin}
    failures = 0
    if not h.tmux_bin:
        print("tmux is not installed; the benchmarks are skipped, not passed")
        report["skipped"] = "no tmux"
        failures = 2
    else:
        problem = h.prepare_app()
        if problem is None:
            try:
                h.probe_features()
            except Exception as error:
                problem = f"feature probe failed: {error}"
        if problem:
            print(f"=== setup failed: {problem}")
            report["setup_error"] = problem
            failures = 2
        else:
            for name, fn in (("attach", bench_attach), ("input", bench_input)):
                if args.only and args.only != name:
                    continue
                print(f"\n--- {'T14 attach latency' if name == 'attach' else 'T15 input latency'}", flush=True)
                try:
                    if not fn(h, args, report):
                        failures += 1
                except Exception as error:
                    failures += 1
                    key = "T14" if name == "attach" else "T15"
                    report.setdefault(key, {})
                    report[key].update({"status": "FAIL", "detail": f"{error}"})
                    print(f"=== {key}: FAIL - {error}", flush=True)
            try:
                h.app.ensure_base()
            except Exception:
                pass
    report["features"] = h.feature_notes
    with open(os.path.join(h.artifacts, "bench.json"), "w") as handle:
        json.dump(report, handle, indent=2)
    print("\n=== bench summary: " + json.dumps({k: v.get("status") for k, v in report.items()
                                                if isinstance(v, dict) and "status" in v}))
    return failures


if __name__ == "__main__":
    sys.exit(main())
