"""Shared plumbing for the `cmux tmux-mirror` requirements harness (DESIGN.md T1-T20, R15, R16).

Everything here talks to cmux through its public surfaces only: the tagged app's control socket
(`/tmp/cmux-debug-<tag>.sock`, one JSON request per line), the tagged CLI through
`scripts/cmux-debug-cli.sh`, and tmux servers this harness starts itself on private sockets.
Nothing reads cmux's source or private state.

Rules the helpers enforce, because the tests must never touch anything they did not create:

- Every tmux command carries `-S <socket>` and `-f /dev/null`, and runs with `TMUX`, `TMUX_PANE`
  and `TMUX_TMPDIR` removed from its environment, so no test can reach the default server or a
  server some other process owns.
- Every socket lives under one private directory in `/tmp` (a unix socket path is capped near
  104 bytes, and macOS's `$TMPDIR` is too long for it).
- The app is relaunched only through `App.launch`, which always ends with the base environment
  restored by the runner, so later check.sh stages find the app as they expect it.

Python 3.9 compatible: the VM may run Xcode's `/usr/bin/python3`.
"""

from __future__ import annotations

import json
import os
import plistlib
import pty
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback

PASS = "PASS"
FAIL = "FAIL"
NOTIMPL = "NOT-IMPLEMENTED"
SKIP = "SKIP"


class CheckFailed(Exception):
    """A requirement does not hold. The message says which observable did not match."""


class NotImplementedYet(Exception):
    """The feature under test does not exist in this build yet (the expected state on main)."""


class Skipped(Exception):
    """The test cannot run here, for a stated reason. A skip is never a pass."""


def sanitize_path(raw):
    cleaned = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "agent"


def sanitize_bundle(raw):
    cleaned = re.sub(r"[^a-z0-9]+", ".", raw.lower()).strip(".")
    cleaned = re.sub(r"\.+", ".", cleaned)
    return cleaned or "agent"


def now_ms():
    return time.monotonic() * 1000.0


def wait_until(fn, timeout=10.0, interval=0.05, what="condition"):
    """Polls `fn` until it returns a truthy value, or raises CheckFailed after `timeout` seconds.

    Polling an external process is the only option a black-box harness has; the deadline is the
    requirement's own limit or a generous bound, never a fixed grace period that a pass depends on.
    """
    deadline = time.monotonic() + timeout
    last_error = None
    while True:
        try:
            value = fn()
            if value:
                return value
        except (CheckFailed, OSError, ValueError, KeyError) as error:
            last_error = error
        if time.monotonic() >= deadline:
            suffix = f" (last error: {last_error})" if last_error else ""
            raise CheckFailed(f"timed out after {timeout:.1f}s waiting for {what}{suffix}")
        time.sleep(interval)


# --------------------------------------------------------------------------------------------
# The app's control socket
# --------------------------------------------------------------------------------------------


class Cmux:
    """A minimal client for the v2 control socket: one JSON request per line, one reply per line."""

    def __init__(self, socket_path):
        self.socket_path = socket_path
        self._next_id = 1

    def call(self, method, params=None, timeout=30.0):
        """Returns the decoded reply: {"ok": bool, "result": ..., "error": {...}}."""
        request_id = self._next_id
        self._next_id += 1
        line = json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            sock.connect(self.socket_path)
            sock.sendall(line.encode("utf-8"))
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
        finally:
            sock.close()
        text = buffer.split(b"\n", 1)[0].decode("utf-8", "replace")
        if not text:
            raise CheckFailed(f"{method}: the socket closed without a reply")
        reply = json.loads(text)
        if not isinstance(reply, dict):
            raise CheckFailed(f"{method}: reply is not an object: {text[:200]}")
        return reply

    def result(self, method, params=None, timeout=30.0):
        """Returns the result of a call that must succeed, or raises CheckFailed with its error."""
        reply = self.call(method, params, timeout)
        if reply.get("ok") is not True:
            raise CheckFailed(f"{method} failed: {error_text(reply)}")
        return reply.get("result") or {}

    def ping(self):
        try:
            return self.call("system.ping", {}, timeout=3.0).get("ok") is True
        except (OSError, ValueError, CheckFailed):
            return False

    # Workspaces and windows, as the socket reports them.

    def window_ids(self):
        windows = self.result("window.list").get("windows") or []
        ids = []
        for window in windows:
            wid = window.get("id") or window.get("window_id")
            if wid:
                ids.append(str(wid))
        return ids

    def workspaces(self):
        """Every workspace in every window: list of dicts with id, title, selected, window_id."""
        rows = []
        for wid in self.window_ids():
            for ws in self.result("workspace.list", {"window_id": wid}).get("workspaces") or []:
                rows.append({
                    "id": str(ws.get("id")),
                    "title": str(ws.get("title") or ""),
                    "selected": bool(ws.get("selected")),
                    "window_id": wid,
                })
        return rows

    def workspace_ids(self):
        return {row["id"] for row in self.workspaces()}

    def current_workspace(self):
        return str(self.result("workspace.current").get("workspace_id") or "")

    def workspace_of_surface(self, surface_id):
        """The workspace that holds `surface_id`, as `surface.list` reports it, or None.

        Surface-targeted CLI commands resolve the surface inside the routed workspace, which
        is the selected one unless `--workspace` names another; a mirror attached without
        focus is not selected, so callers pass the workspace this returns.
        """
        for row in self.workspaces():
            listing = self.call("surface.list", {"workspace_id": row["id"]})
            for surface in (listing.get("result") or {}).get("surfaces") or []:
                if str(surface.get("id")) == str(surface_id):
                    return row["id"]
        return None

    def new_plain_workspace(self, select_it=True):
        """Creates an ordinary (non-mirror) workspace, selects it, and returns its id."""
        wsid = str(self.result("workspace.create", {}).get("workspace_id") or "")
        if not wsid:
            raise CheckFailed("workspace.create returned no workspace_id")
        if select_it:
            self.result("workspace.select", {"workspace_id": wsid})
        return wsid


def error_text(reply):
    error = reply.get("error") or {}
    code = error.get("code") or "error"
    message = error.get("message") or "(no message)"
    return f"{code}: {message}"


def error_message(reply):
    return str((reply.get("error") or {}).get("message") or "")


# --------------------------------------------------------------------------------------------
# Private tmux servers
# --------------------------------------------------------------------------------------------


def clean_environment(extra=None, path=None):
    """The environment every child the harness starts gets: the caller's, minus every variable
    that could point tmux at a server the harness did not create."""
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE", "TMUX_TMPDIR")}
    for key in ("CMUX_FOCUS_NEW",):
        env.pop(key, None)
    if path is not None:
        env["PATH"] = path
    if extra:
        env.update(extra)
    return env


class Tmux:
    """One tmux server on an explicit socket path, started and owned by the harness."""

    def __init__(self, socket_path, binary, shell="/bin/sh", env_extra=None):
        self.socket_path = socket_path
        self.binary = binary
        self.shell = shell
        self.env_extra = dict(env_extra or {})
        os.makedirs(os.path.dirname(socket_path), mode=0o700, exist_ok=True)

    def argv(self, *args):
        return [self.binary, "-f", "/dev/null", "-S", self.socket_path] + list(args)

    def env(self):
        extra = {"SHELL": self.shell}
        extra.update(self.env_extra)
        return clean_environment(extra)

    def run(self, *args, check=True, timeout=15.0, cwd=None):
        proc = subprocess.run(
            self.argv(*args), env=self.env(), cwd=cwd, timeout=timeout,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if check and proc.returncode != 0:
            raise CheckFailed(f"tmux {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}")
        return proc

    def new_session(self, name, cwd=None, command=None, size=(200, 50)):
        args = ["new-session", "-d", "-s", name, "-x", str(size[0]), "-y", str(size[1])]
        if cwd:
            args += ["-c", cwd]
        if command:
            args.append(command)
        self.run(*args)
        return name

    def alive(self):
        return self.run("list-sessions", check=False).returncode == 0

    def sessions(self):
        proc = self.run("list-sessions", "-F", "#{session_name}", check=False)
        if proc.returncode != 0:
            return []
        return [line for line in proc.stdout.splitlines() if line]

    def windows(self, session):
        proc = self.run("list-windows", "-t", f"={session}", "-F", "#{window_id}\t#{window_name}\t#{window_panes}")
        rows = []
        for line in proc.stdout.splitlines():
            wid, name, panes = line.split("\t")
            rows.append({"id": wid, "name": name, "panes": int(panes)})
        return rows

    def panes(self, target):
        proc = self.run("list-panes", "-t", target, "-F", "#{pane_id}")
        return [line for line in proc.stdout.splitlines() if line]

    def fmt(self, target, fmt):
        return self.run("display-message", "-p", "-t", target, fmt).stdout.rstrip("\n")

    def clients(self):
        proc = self.run("list-clients", "-F", "#{client_control_mode}\t#{client_pid}\t#{client_session}", check=False)
        if proc.returncode != 0:
            return []
        rows = []
        for line in proc.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                rows.append({"control": parts[0] == "1", "pid": parts[1], "session": parts[2]})
        return rows

    def control_clients(self):
        return [c for c in self.clients() if c["control"]]

    def kill(self):
        self.run("kill-server", check=False)


def tmux_version(binary):
    try:
        out = subprocess.run([binary, "-V"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, timeout=5).stdout.strip()
        return out
    except (OSError, subprocess.SubprocessError):
        return ""


def gui_install_tmux():
    """The tmux a Dock-launched app can find without the shell's PATH (R5): the first of the
    install prefixes the resolver checks."""
    for directory in ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"):
        candidate = os.path.join(directory, "tmux")
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def bind_stale_socket(path):
    """Creates a unix socket file with no listener behind it: what a dead tmux server leaves."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    sock.close()


# --------------------------------------------------------------------------------------------
# The tagged app
# --------------------------------------------------------------------------------------------


class App:
    """Locates, launches and stops the tagged dev build that check.sh's build-launch stage made."""

    def __init__(self, tag, repo, artifacts, tmux_bin):
        self.tag = tag
        self.slug = sanitize_path(tag)
        self.bundle_id = "com.cmuxterm.app.debug." + sanitize_bundle(tag)
        self.socket_path = f"/tmp/cmux-debug-{self.slug}.sock"
        self.repo = repo
        self.artifacts = artifacts
        self.tmux_bin = tmux_bin
        self.cli_wrapper = os.path.join(repo, "scripts", "cmux-debug-cli.sh")
        derived = os.environ.get("CMUX_DERIVED_DATA") or os.path.expanduser(
            f"~/Library/Developer/Xcode/DerivedData/cmux-{self.slug}")
        candidates = [
            os.path.join(derived, "Build/Products/Debug", f"cmux DEV {self.slug}.app"),
            os.path.join(derived, "Build/Products/Release", f"cmux DEV {self.slug}.app"),
        ]
        self.app_path = next((c for c in candidates if os.path.isdir(c)), candidates[0])
        self.executable = None
        info = os.path.join(self.app_path, "Contents", "Info.plist")
        if os.path.exists(info):
            with open(info, "rb") as handle:
                name = plistlib.load(handle).get("CFBundleExecutable")
            if name:
                self.executable = os.path.join(self.app_path, "Contents", "MacOS", name)
        self.cli_path = os.path.join(self.app_path, "Contents", "Resources", "bin", "cmux")
        self.cmux = Cmux(self.socket_path)
        self.launch_count = 0
        self.current_env_label = "as started by check.sh"

    def base_path(self):
        """PATH for the base launch: the tmux under test first, then what reload.sh gives the app."""
        first = os.path.dirname(self.tmux_bin)
        return f"{first}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    def pids(self):
        if not self.executable:
            return []
        out = subprocess.run(["ps", "-axo", "pid=,command="], stdout=subprocess.PIPE, text=True).stdout
        pids = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            pid, _, command = line.partition(" ")
            if command.strip() == self.executable or command.strip().startswith(self.executable + " "):
                pids.append(int(pid))
        return pids

    def pid(self):
        pids = self.pids()
        return pids[0] if pids else None

    def quit(self, sig=signal.SIGTERM, timeout=10.0):
        pids = self.pids()
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + timeout
        while self.pids() and time.monotonic() < deadline:
            time.sleep(0.1)
        for pid in self.pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wait_until(lambda: not self.pids(), timeout=10.0, what="the tagged app to exit")

    def set_default(self, key, value):
        if value is None:
            subprocess.run(["defaults", "delete", self.bundle_id, key],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(["defaults", "write", self.bundle_id, key, "-bool", "true" if value else "false"],
                           check=True)

    def launch(self, extra_env=None, path=None, label="base"):
        """Stops the running tagged app and starts it again with a controlled environment.

        The environment matches what reload.sh gives a tagged launch (an `env -i` base plus the
        tag's socket settings), plus `extra_env`. Launching the executable directly keeps the app
        a plain process the harness can find, signal and measure.
        """
        if not self.executable or not os.access(self.executable, os.X_OK):
            raise CheckFailed(f"tagged app executable not found under {self.app_path}")
        self.quit()
        home = os.path.expanduser("~")
        user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        env = {
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "SHELL": os.environ.get("SHELL", "/bin/zsh"),
            "PATH": path or self.base_path(),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "CMUX_TAG": self.slug,
            "CMUX_BUNDLE_ID": self.bundle_id,
            "CMUX_SOCKET_ENABLE": "1",
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_PATH": self.socket_path,
            "CMUX_DEBUG_LOG": f"/tmp/cmux-debug-{self.slug}.log",
            "CMUX_BUNDLED_CLI_PATH": self.cli_path,
            "CMUX_SHELL_INTEGRATION_DIR": os.path.join(self.app_path, "Contents/Resources/shell-integration"),
            "CMUXD_UNIX_PATH": os.path.join(home, "Library/Application Support/cmux", f"cmuxd-dev-{self.slug}.sock"),
            "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD": "1",
            "CMUX_DEV_BACKEND_MODE": os.environ.get("CMUX_DEV_BACKEND_MODE", "local"),
        }
        if extra_env:
            env.update(extra_env)
        self.launch_count += 1
        log_path = os.path.join(self.artifacts, f"app-launch-{self.launch_count:02d}-{label}.log")
        with open(log_path, "ab") as log:
            log.write(("env: " + json.dumps(sorted(k for k in env)) + "\n").encode())
            subprocess.Popen([self.executable], env=env, stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        wait_until(self.cmux.ping, timeout=90.0, interval=0.25, what=f"the tagged app ({label}) to answer on its socket")
        self.current_env_label = label

    def ensure_base(self):
        if self.current_env_label != "base" or not self.cmux.ping():
            self.launch(label="base")

    # The tagged CLI.

    def cli(self, args, env_extra=None, unset=(), cwd=None, path=None, timeout=60.0, stdin_data=None):
        """Runs the tagged CLI as a script would (stdin and stdout are not a terminal).

        Returns (exit status, stdout, stderr). `TMUX`, `TMUX_PANE` and `TMUX_TMPDIR` are removed
        unless `env_extra` sets them, so the caller states exactly which server the shell names.
        """
        env = clean_environment(env_extra, path=path)
        for key in unset:
            env.pop(key, None)
        env["CMUX_TAG"] = self.tag
        for key in AGENT_ENV_KEYS:
            env.pop(key, None)
        proc = subprocess.run(
            [self.cli_wrapper] + list(args), env=env, cwd=cwd, timeout=timeout,
            input=stdin_data, stdin=None if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def cli_tty(self, args, env_extra=None, cwd=None, timeout=60.0):
        """Runs the tagged CLI with stdin and stdout on a pty, as a person typing it would."""
        env = clean_environment(env_extra)
        env["CMUX_TAG"] = self.tag
        for key in AGENT_ENV_KEYS:
            env.pop(key, None)
        master, slave = pty.openpty()
        try:
            proc = subprocess.Popen([self.cli_wrapper] + list(args), env=env, cwd=cwd,
                                    stdin=slave, stdout=slave, stderr=slave, close_fds=True,
                                    start_new_session=True)
        finally:
            os.close(slave)
        output = b""
        deadline = time.monotonic() + timeout
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    proc.kill()
                    break
                ready, _, _ = select.select([master], [], [], min(remaining, 0.2))
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        break
                    output += chunk
                elif proc.poll() is not None:
                    break
            proc.wait(timeout=5)
        finally:
            os.close(master)
        return proc.returncode, output.decode("utf-8", "replace")


AGENT_ENV_KEYS = (
    "CMUX_AGENT_LAUNCH_KIND", "CODEX_CI", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_SANDBOX",
    "CODEX_MANAGED_BY_BUN", "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SESSION_ID", "OPENCODE", "OPENCODE_PORT", "OPENCODE_SESSION_ID", "AI_AGENT",
    "CMUX_FOCUS_NEW",
)


# --------------------------------------------------------------------------------------------
# The mirror, through the socket (DESIGN.md D8: transport "local" plus "socket_path")
# --------------------------------------------------------------------------------------------


def local_host(socket_path):
    return {"transport": "local", "socket_path": socket_path}


class Mirror:
    """Mirror operations for one host description (local socket, or an ssh destination)."""

    def __init__(self, cmux, host_params):
        self.cmux = cmux
        self.host = dict(host_params)

    def params(self, **extra):
        params = dict(self.host)
        params.update(extra)
        return params

    def attach(self, session=None, activate=False, new_window=False, timeout=90.0):
        params = self.params(activate=activate)
        if session:
            params["session"] = session
        method = "remote.tmux.window" if new_window else "remote.tmux.mirror"
        reply = self.cmux.call(method, params, timeout=timeout)
        if reply.get("ok") is not True:
            raise CheckFailed(f"{method} failed: {error_text(reply)}")
        result = reply.get("result") or {}
        if result.get("mirrored") is not True:
            raise CheckFailed(f"{method} did not mirror: {json.dumps(result)[:300]}")
        return result

    def sessions(self):
        return self.cmux.result("remote.tmux.sessions", self.params(), timeout=30.0).get("sessions") or []

    def grids(self, session):
        reply = self.cmux.call("remote.tmux.pane_grids", self.params(session=session), timeout=10.0)
        if reply.get("ok") is not True:
            return None
        result = reply.get("result") or {}
        return result if result.get("mirrored") is True else None

    def is_mirrored(self, session):
        return self.grids(session) is not None

    def shape(self, session):
        """Sorted pane counts of the mirrored windows of `session`, or None when not mirrored."""
        grids = self.grids(session)
        if grids is None:
            return None
        return sorted(len(window.get("panes") or []) for window in grids.get("windows") or [])

    def pane_surfaces(self, session):
        reply = self.cmux.call("remote.tmux.pane_surfaces", self.params(session=session), timeout=10.0)
        if reply.get("ok") is not True:
            return []
        return (reply.get("result") or {}).get("panes") or []

    def surface_for_pane(self, session, pane_id):
        for entry in self.pane_surfaces(session):
            if entry.get("pane_id") == pane_id:
                return entry.get("surface_id")
        return None

    def detach(self, session):
        self.cmux.call("remote.tmux.detach", self.params(session=session), timeout=15.0)

    def detach_all(self, sessions):
        for session in sessions:
            try:
                self.detach(session)
            except (OSError, ValueError, CheckFailed):
                pass


def probe_local_rpc(cmux, server):
    """Whether this build's socket accepts `transport: "local"` (D8). Returns (bool, why)."""
    reply = cmux.call("remote.tmux.sessions", local_host(server.socket_path), timeout=20.0)
    if reply.get("ok") is True:
        names = [s.get("name") for s in (reply.get("result") or {}).get("sessions") or []]
        if names:
            return True, f"remote.tmux.sessions listed {names}"
        return False, "remote.tmux.sessions accepted transport=local but listed no sessions"
    code = (reply.get("error") or {}).get("code")
    if code == "disabled":
        raise CheckFailed("the remote tmux beta is off in the tagged app; the harness could not enable it")
    return False, f"the socket refuses transport=local ({error_text(reply)})"


def probe_cli(app):
    """Whether this build's CLI has `cmux tmux-mirror` (D9). Returns (bool, why)."""
    rc, out, err = app.cli(["tmux-mirror", "--help"], timeout=30.0)
    text = (out + err).strip().splitlines()
    first = text[0] if text else ""
    if rc == 0 and "tmux-mirror" in (out + err):
        return True, "cmux tmux-mirror --help exits 0"
    return False, f"cmux tmux-mirror is not a command in this build (exit {rc}: {first[:160]})"


# --------------------------------------------------------------------------------------------
# Localization oracle (R14): the shipped string catalog
# --------------------------------------------------------------------------------------------


class Catalog:
    """Reads Resources/Localizable.xcstrings and answers whether a message the user saw is a
    catalog string translated into every language the catalog ships."""

    REFERENCE_KEY = "cli.sshTmux.list.empty"
    PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lu|u|f|s|%)")

    def __init__(self, repo):
        path = os.path.join(repo, "Resources", "Localizable.xcstrings")
        with open(path, "rb") as handle:
            data = json.load(handle)
        self.source_language = data.get("sourceLanguage", "en")
        self.entries = []
        reference = (data.get("strings") or {}).get(self.REFERENCE_KEY) or {}
        self.languages = set((reference.get("localizations") or {}).keys())
        for key, entry in (data.get("strings") or {}).items():
            localizations = entry.get("localizations") or {}
            english = None
            source = localizations.get(self.source_language) or {}
            unit = source.get("stringUnit") or {}
            if unit.get("value"):
                english = unit["value"]
            elif not localizations:
                english = key
            if english is None:
                continue
            translated = set()
            for language, payload in localizations.items():
                unit = (payload or {}).get("stringUnit") or {}
                if unit.get("value") and unit.get("state", "translated") in ("translated", "needs_review"):
                    translated.add(language)
                elif (payload or {}).get("variations"):
                    translated.add(language)
            self.entries.append((key, english, translated))

    def _pattern(self, english):
        parts = self.PLACEHOLDER.split(english)
        return re.compile(".+?".join(re.escape(p) for p in parts), re.DOTALL)

    def lookup(self, message):
        """Returns (key, missing languages) for the best catalog match of `message`, or None."""
        message = message.strip()
        best = None
        for key, english, translated in self.entries:
            if len(english) < 8:
                continue
            if english == message or self._pattern(english).search(message):
                if best is None or len(english) > len(best[1]):
                    best = (key, english, translated)
        if best is None:
            return None
        missing = sorted(self.languages - best[2])
        return best[0], missing


# --------------------------------------------------------------------------------------------
# Test registry and runner
# --------------------------------------------------------------------------------------------


class TestCase:
    def __init__(self, test_id, requirements, title, needs, fn):
        self.test_id = test_id
        self.requirements = requirements
        self.title = title
        self.needs = needs
        self.fn = fn


REGISTRY = []


def test(test_id, requirements, title, needs=()):
    def decorate(fn):
        REGISTRY.append(TestCase(test_id, requirements, title, tuple(needs), fn))
        return fn
    return decorate


class Context:
    """Per-test state: sub-checks, owned servers, cleanups, and a log file."""

    def __init__(self, harness, case):
        self.h = harness
        self.case = case
        self.checks = []
        self.cleanups = []
        self.servers = []
        self.dir = tempfile.mkdtemp(prefix=f"{case.test_id.lower()}.", dir=harness.state)
        self.log_lines = []
        self.notimpl = []

    # Logging and checks.

    def log(self, message):
        line = f"    {message}"
        self.log_lines.append(line)
        print(line, flush=True)

    def check(self, condition, label):
        self.checks.append((bool(condition), label))
        print(f"    {'ok  ' if condition else 'FAIL'} {label}", flush=True)
        return bool(condition)

    def require(self, condition, label):
        if not self.check(condition, label):
            raise CheckFailed(label)

    def not_implemented(self, why):
        raise NotImplementedYet(why)

    # Resources.

    def server(self, name, binary=None, shell="/bin/sh", env_extra=None, socket_path=None):
        path = socket_path or os.path.join(self.dir, f"{name}.sock")
        server = Tmux(path, binary or self.h.tmux_bin, shell=shell, env_extra=env_extra)
        self.servers.append(server)
        return server

    def on_cleanup(self, fn):
        self.cleanups.append(fn)

    def mirror(self, server_or_params):
        if isinstance(server_or_params, Tmux):
            return Mirror(self.h.cmux, local_host(server_or_params.socket_path))
        return Mirror(self.h.cmux, server_or_params)

    def relaunch(self, extra_env=None, path=None, label="custom"):
        self.h.app.launch(extra_env=extra_env, path=path, label=label)

    def close(self):
        for fn in reversed(self.cleanups):
            try:
                fn()
            except Exception as error:  # cleanup must never mask the result
                print(f"    cleanup error: {error}", flush=True)
        for server in self.servers:
            try:
                Mirror(self.h.cmux, local_host(server.socket_path)).detach_all(server.sessions())
            except Exception:
                pass
            server.kill()


class Harness:
    def __init__(self, name, argv_description):
        self.name = name
        self.argv_description = argv_description
        self.results = []
        self.features = {}
        self.feature_notes = {}

    def setup(self, args):
        self.repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        self.tag = os.environ.get("CMUX_TAG") or ""
        if not self.tag:
            print(f"{self.name}: CMUX_TAG is required (the tagged build to test)", file=sys.stderr)
            sys.exit(2)
        tmux_bin = os.environ.get("TMUX_BIN") or shutil.which("tmux") or ""
        self.tmux_bin = tmux_bin if tmux_bin and os.access(tmux_bin, os.X_OK) else ""
        self.artifacts = os.path.abspath(args.artifacts or tempfile.mkdtemp(prefix=f"{self.name}-artifacts."))
        os.makedirs(self.artifacts, exist_ok=True)
        # Short on purpose: unix socket paths are capped near 104 bytes.
        self.state = tempfile.mkdtemp(prefix="cmlx.", dir="/tmp")
        self.app = App(self.tag, self.repo, self.artifacts, self.tmux_bin or "/usr/bin/false")
        self.cmux = self.app.cmux
        print(f"=== {self.name}")
        print(f"    tag={self.tag} socket={self.app.socket_path}")
        print(f"    app={self.app.app_path}")
        print(f"    tmux={self.tmux_bin or '(none)'} {tmux_version(self.tmux_bin) if self.tmux_bin else ''}")
        print(f"    state={self.state} artifacts={self.artifacts}", flush=True)
        running = self.app.pid()
        answering = self.cmux.ping()
        print(f"    tagged app at start: {'pid ' + str(running) if running else 'not running'}, "
              f"socket {'answers' if answering else 'silent'}", flush=True)

    def prepare_app(self):
        """Turns the remote tmux beta on for the tagged bundle and starts the app with the base
        environment. Returns None, or the reason the app could not be prepared."""
        try:
            self.app.set_default("remoteTmux.beta.enabled", True)
            self.app.set_default("remoteTmux.multiplexer.beta.enabled", None)
            self.app.launch(label="base")
            return None
        except Exception as error:
            return f"could not launch the tagged app: {error}"

    def probe_features(self):
        probe_dir = tempfile.mkdtemp(prefix="probe.", dir=self.state)
        server = Tmux(os.path.join(probe_dir, "p.sock"), self.tmux_bin)
        try:
            server.new_session("probe")
            ok, why = probe_local_rpc(self.cmux, server)
            self.features["rpc"], self.feature_notes["rpc"] = ok, why
            Mirror(self.cmux, local_host(server.socket_path)).detach_all(["probe"])
        finally:
            server.kill()
        ok, why = probe_cli(self.app)
        self.features["cli"], self.feature_notes["cli"] = ok, why
        for key in ("rpc", "cli"):
            print(f"    feature {key}: {'present' if self.features[key] else 'absent'} ({self.feature_notes[key]})")

    def run(self, cases, global_failure=None):
        for case in cases:
            print(f"\n--- {case.test_id} [{', '.join(case.requirements)}] {case.title}", flush=True)
            start = time.monotonic()
            if global_failure:
                self.record(case, FAIL, global_failure, start)
                continue
            if not self.tmux_bin:
                self.record(case, SKIP, "tmux is not installed; live tests are skipped, never passed", start)
                continue
            missing = [n for n in case.needs if not self.features.get(n)]
            ctx = Context(self, case)
            status, detail = PASS, ""
            try:
                if missing:
                    raise NotImplementedYet("; ".join(self.feature_notes[n] for n in missing))
                case.fn(ctx)
                failed = [label for ok, label in ctx.checks if not ok]
                if failed:
                    status, detail = FAIL, "; ".join(failed)
                elif not ctx.checks:
                    status, detail = FAIL, "the test made no checks"
            except NotImplementedYet as error:
                status, detail = NOTIMPL, str(error)
            except Skipped as error:
                status, detail = SKIP, str(error)
            except CheckFailed as error:
                status, detail = FAIL, str(error)
            except Exception as error:
                status, detail = FAIL, f"harness error: {error!r}"
                traceback.print_exc()
            finally:
                ctx.close()
                try:
                    self.app.ensure_base()
                except Exception as error:
                    print(f"    could not restore the base app: {error}", flush=True)
            self.record(case, status, detail, start)
        try:
            self.app.ensure_base()
        except Exception:
            pass

    def record(self, case, status, detail, start):
        elapsed = time.monotonic() - start
        self.results.append({
            "test": case.test_id, "requirements": case.requirements, "title": case.title,
            "status": status, "detail": detail, "seconds": round(elapsed, 1),
        })
        print(f"=== {case.test_id}: {status}{' - ' + detail if detail else ''}", flush=True)

    def finish(self):
        counts = {}
        for row in self.results:
            counts[row["status"]] = counts.get(row["status"], 0) + 1
        with open(os.path.join(self.artifacts, "results.json"), "w") as handle:
            json.dump({"features": self.feature_notes, "results": self.results}, handle, indent=2)
        with open(os.path.join(self.artifacts, "results.tsv"), "w") as handle:
            handle.write("test\trequirements\tstatus\tseconds\tdetail\n")
            for row in self.results:
                handle.write(f"{row['test']}\t{','.join(row['requirements'])}\t{row['status']}\t{row['seconds']}\t{row['detail']}\n")
        print("\n=== summary")
        for row in self.results:
            print(f"  {row['status']:<16} {row['test']:<4} {','.join(row['requirements']):<12} {row['title']}")
        print("  " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
        failures = counts.get(FAIL, 0) + counts.get(NOTIMPL, 0)
        if failures == 0:
            shutil.rmtree(self.state, ignore_errors=True)
        else:
            print(f"  state kept for inspection: {self.state}")
        return min(failures, 125)
