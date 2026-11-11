"""Benchmarks T14 (R15, attach latency) and T15 (R16, added input latency) for `cmux tmux-mirror`.

Run through scripts/remote-tmux-local-bench.sh. Both measure from outside the app:

- T14 starts a private server with N sessions of M windows, asks the socket to mirror it, and
  times from the request to the moment every session reports all M windows mirrored. It repeats
  that through ssh-tmux (with the ssh shim) on the same server and app, in `--pairs`
  interleaved pairs, and passes when the local median is at most the ssh-tmux median plus
  `--attach-tolerance-pct` (R15 v1.1; see T14_RULE below).
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


def build_attach_server(h, socket_path, args):
    server = Tmux(socket_path, h.tmux_bin)
    sessions = [f"b{i:02d}" for i in range(args.sessions)]
    for name in sessions:
        server.new_session(name)
        for _ in range(args.windows - 1):
            server.run("new-window", "-d", "-t", f"={name}")
    return server, sessions


def time_attach(h, args, server, sessions, mirror, label, keep_log=False):
    """Times one attach of `mirror`, from the request until every session shows all its
    windows, then detaches. With keep_log, saves the app's debug log for that attach."""
    debug_log = f"/tmp/cmux-debug-{h.app.slug}.log"
    offset = os.path.getsize(debug_log) if os.path.exists(debug_log) else 0
    start = time.monotonic()
    mirror.attach()

    def all_published():
        for name in sessions:
            shape = mirror.shape(name)
            if shape is None or len(shape) != args.windows:
                return False
        return True
    wait_until(all_published, timeout=60.0, interval=0.005, what=f"{label}: every workspace published")
    elapsed = (time.monotonic() - start) * 1000.0
    if keep_log and os.path.exists(debug_log):
        # Where the time goes (Q-A8): the app's own records for this attach.
        with open(debug_log, "rb") as handle:
            handle.seek(offset)
            segment = handle.read().decode("utf-8", "replace")
        with open(os.path.join(h.artifacts, f"t14-{label}-debug.log"), "w") as out:
            out.write(segment)
    mirror.detach_all(sessions)
    wait_until(lambda: not server.control_clients(), timeout=30.0, what=f"{label}: the mirror to detach")
    return elapsed


T14_RULE = (
    "R15 (v1.1): the local attach is no slower than ssh-tmux on the same server. Measured as "
    "{pairs} interleaved pairs on one server and one app process, alternating which transport goes "
    "first in each pair so warm-up and drift fall on both equally. PASS when the median local time is "
    "at most the median ssh-tmux time plus {tol:g}%. The margin is about twice the run-to-run spread "
    "measured so far (about +/-5% around the median), so it absorbs noise without hiding a "
    "consistent slowdown; ssh-tmux runs through scripts/remote-tmux-e2e-ssh-shim.sh, so it pays "
    "no network or login cost."
)


def bench_attach(h, args, report):
    """T14 (R15 v1.1): local against ssh-tmux, interleaved, on one server and one app.

    The app is launched with the ssh shim and a TMUX_TMPDIR whose default server is the test
    server, so ssh-tmux reaches it through the shim, and the local mirror reaches the very
    same server through its explicit socket path (R21: the app's TMUX_TMPDIR does not steer it).
    """
    shim = os.path.join(h.repo, "scripts", "remote-tmux-e2e-ssh-shim.sh")
    tmpdir = os.path.join(h.state, "t14")
    server, sessions = build_attach_server(h, os.path.join(tmpdir, f"tmux-{os.getuid()}", "default"), args)
    rule = T14_RULE.format(pairs=args.pairs, tol=args.attach_tolerance_pct)
    print(f"    rule: {rule}", flush=True)
    try:
        h.app.launch({"CMUX_REMOTE_TMUX_SSH_FOR_TESTING": shim, "TMUX_TMPDIR": tmpdir}, label="t14-shim")
        ssh = Mirror(h.cmux, {"host": "bench-shim-host"})
        local = Mirror(h.cmux, local_host(server.socket_path))
        have_local = bool(h.features.get("rpc"))
        times = {"ssh": [], "local": []}
        for pair in range(args.pairs):
            order = ("ssh", "local") if pair % 2 == 0 else ("local", "ssh")
            for kind in order:
                if kind == "local" and not have_local:
                    continue
                mirror = ssh if kind == "ssh" else local
                times[kind].append(time_attach(h, args, server, sessions, mirror, kind, keep_log=pair == 0))
            print(f"    pair {pair + 1}: " + ", ".join(f"{k} {times[k][-1]:.0f} ms" for k in order if times[k]),
                  flush=True)
        ssh_median = statistics.median(times["ssh"])
        entry = {
            "requirement": "R15 v1.1",
            "rule": rule,
            "sessions": args.sessions, "windows": args.windows, "pairs": args.pairs,
            "ssh_runs_ms": [round(t, 1) for t in times["ssh"]],
            "ssh_median_ms": round(ssh_median, 1),
            "tolerance_pct": args.attach_tolerance_pct,
            "former_absolute_limit_ms": args.attach_limit_ms,
        }
        if not have_local:
            entry.update({"status": "NOT-IMPLEMENTED", "detail": h.feature_notes.get("rpc")})
            report["T14"] = entry
            print(f"=== T14 (R15): ssh-tmux median {ssh_median:.0f} ms; local not implemented", flush=True)
            return False
        local_median = statistics.median(times["local"])
        limit = ssh_median * (1 + args.attach_tolerance_pct / 100.0)
        ok = local_median <= limit
        faster_pairs = sum(1 for l, s in zip(times["local"], times["ssh"]) if l <= s)
        entry.update({
            "status": "PASS" if ok else "FAIL",
            "local_runs_ms": [round(t, 1) for t in times["local"]],
            "local_median_ms": round(local_median, 1),
            "limit_ms": round(limit, 1),
            "local_to_ssh_ratio": round(local_median / ssh_median, 3),
            "pairs_where_local_was_no_slower": faster_pairs,
        })
        report["T14"] = entry
        print(f"=== T14 (R15): local median {local_median:.0f} ms, ssh-tmux median {ssh_median:.0f} ms "
              f"(ratio {local_median / ssh_median:.2f}; limit {limit:.0f} ms = ssh + {args.attach_tolerance_pct:g}%; "
              f"local no slower in {faster_pairs} of {args.pairs} pairs; the former absolute limit was "
              f"{args.attach_limit_ms:.0f} ms): {'PASS' if ok else 'FAIL'}", flush=True)
        return ok
    finally:
        server.kill()
        h.app.launch(label="base")


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
                      f"attach-session -t \'=bench\'")  # quoted: zsh expands a bare =word
        # Focused, because a terminal in a background workspace may not start until shown.
        rc, out, err = h.app.cli(["new-workspace", "--command", attach_cmd, "--focus", "true"])
        if rc != 0:
            raise CheckFailed(f"new-workspace failed ({rc}: {(out + err).strip()[:200]})")
        new_ids = wait_until(lambda: h.cmux.workspace_ids() - before, timeout=10.0,
                             what="the plain-client workspace to appear")
        plain_workspace = sorted(new_ids)[0]
        surfaces = h.cmux.result("surface.list", {"workspace_id": plain_workspace}).get("surfaces") or []
        plain_surface = str(surfaces[0].get("id"))
        try:
            wait_until(lambda: any(not c["control"] for c in server.clients()), timeout=20.0,
                       what="the plain tmux client to attach")
        except CheckFailed as error:
            screen = h.cmux.call("surface.read_text", {"surface_id": plain_surface})
            text = json.dumps((screen.get("result") or screen.get("error") or {}))[:600]
            raise CheckFailed(f"{error}; the plain terminal shows: {text}")
        time.sleep(0.5)
        plain = measure_typing(h.cmux, plain_surface, observer, args.keystrokes)
        plain_p95 = percentile(plain, 0.95)
        print(f"    plain client: p50 {percentile(plain, 0.5):.1f} ms, p95 {plain_p95:.1f} ms", flush=True)
        # Detach the plain client through tmux, so only the observer and the mirror stay attached.
        names = server.run("list-clients", "-F", "#{client_control_mode} #{client_name}").stdout.split("\n")
        for line in names:
            control, _, name = line.partition(" ")
            if name and control != "1":
                server.run("detach-client", "-t", name, check=False)
        h.cmux.call("workspace.close", {"workspace_id": plain_workspace})
        plain_workspace = None
        wait_until(lambda: not any(not c["control"] for c in server.clients()), timeout=10.0,
                   what="the plain client to go away")

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
    parser.add_argument("--runs", type=int, default=5, help="unused since R15 v1.1; kept so old callers still parse")
    parser.add_argument("--pairs", type=int, default=7, help="T14: interleaved local and ssh-tmux attach pairs")
    parser.add_argument("--attach-tolerance-pct", type=float, default=10.0,
                        help="T14: the local median may exceed the ssh-tmux median by this much")
    parser.add_argument("--attach-limit-ms", type=float, default=1000.0,
                        help="R15 v1.0's absolute limit, reported for information only")
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
