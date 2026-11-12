"""Live requirements tests T1-T20 for `cmux tmux-mirror` (DESIGN.md section 4).

Run through scripts/remote-tmux-local-conformance.sh; see that file for usage. Each test is
written from the requirement it names and observes only public surfaces: the CLI's output and
exit status, socket replies, the mirrored workspaces, tabs and splits as the socket reports them,
and tmux state on servers this harness started.

Statuses: PASS; FAIL (a requirement does not hold); NOT-IMPLEMENTED (the feature the test needs
does not exist in this build, which is the expected state on main); SKIP (cannot run here, with
the reason). The exit status is the number of FAIL plus NOT-IMPLEMENTED results.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    REGISTRY, Catalog, CheckFailed, Harness, Mirror, NotImplementedYet, Skipped, Tmux, clean_environment,
    error_message, gui_install_tmux, bind_stale_socket, local_host, test, wait_until,
)

UID = os.getuid()
HOME = os.path.expanduser("~")
ONE_PIXEL_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"
)


# --------------------------------------------------------------------------------------------
# Shared steps
# --------------------------------------------------------------------------------------------


def build_shape(server, prefix):
    """Two sessions: `<prefix>-alpha` with one window, and `<prefix>-beta` with a 3-pane window
    and a second single-pane window. Returns {session: sorted pane counts per window}."""
    alpha = server.new_session(f"{prefix}-alpha")
    beta = server.new_session(f"{prefix}-beta")
    server.run("split-window", "-h", "-t", f"={beta}:0")
    server.run("split-window", "-v", "-t", f"={beta}:0")
    server.run("new-window", "-d", "-t", f"={beta}")
    return {alpha: [1], beta: [1, 3]}


def expect_shapes(ctx, mirror, expected, timeout=10.0):
    for session, shape in expected.items():
        try:
            got = wait_until(lambda s=session, e=shape: mirror.shape(s) == e and mirror.shape(s),
                             timeout=timeout, what=f"{session} to mirror as windows {shape}")
            ctx.check(got == shape, f"{session} mirrors as windows with {shape} panes")
        except CheckFailed as error:
            ctx.check(False, f"{session} mirrors as windows with {shape} panes ({mirror.shape(session)}): {error}")


def no_control_clients(server, timeout=5.0):
    try:
        wait_until(lambda: not server.control_clients(), timeout=timeout, what="no control client attached")
        return True
    except CheckFailed:
        return False


def first_pane(server, session):
    return server.panes(f"={session}:0")[0]


def surface_of(ctx, mirror, session, pane_id):
    return wait_until(lambda: mirror.surface_for_pane(session, pane_id), timeout=10.0,
                      what=f"a surface for pane {pane_id} of {session}")


def private_tmpdir(ctx, name):
    """A TMUX_TMPDIR of the test's own, and the default-server socket tmux derives from it."""
    path = os.path.join(ctx.dir, name)
    os.makedirs(path, exist_ok=True)
    return path, os.path.join(path, f"tmux-{UID}", "default")


def cli_json(ctx, args, **kwargs):
    rc, out, err = ctx.h.app.cli(["--json"] + list(args), **kwargs)
    payload = None
    for line in reversed(out.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                payload = json.loads(line)
            except ValueError:
                pass
            break
    if payload is None and out.strip().startswith("{"):
        try:
            payload = json.loads(out)
        except ValueError:
            payload = None
    return rc, payload, out, err


def write_script(path, body):
    with open(path, "w") as handle:
        handle.write(body)
    os.chmod(path, 0o755)
    return path


def notimpl_if_clean(ctx, why):
    """Reports NOT-IMPLEMENTED for the remaining part, unless an earlier check already failed."""
    if all(ok for ok, _ in ctx.checks):
        raise NotImplementedYet(why)


def has_feature(ctx, name):
    return bool(ctx.h.features.get(name))


def localized_check(ctx, catalog, message, label):
    """R14: the message the user saw is a catalog string translated into every catalog language."""
    if catalog is None:
        ctx.check(False, f"{label}: the string catalog could not be read")
        return
    found = catalog.lookup(message)
    if found is None:
        ctx.check(False, f"{label}: message is not in the string catalog: {message[:120]!r}")
        return
    key, missing = found
    ctx.check(not missing, f"{label}: catalog key {key} is translated into every catalog language"
              + (f" (missing {', '.join(missing)})" if missing else ""))


def load_catalog(ctx):
    try:
        return Catalog(ctx.h.repo)
    except (OSError, ValueError) as error:
        ctx.log(f"string catalog unavailable: {error}")
        return None


# --------------------------------------------------------------------------------------------
# T1-T20
# --------------------------------------------------------------------------------------------


@test("T1", ["R1"], "Mirror shape: sessions are workspaces, windows are tabs, panes are splits", needs=["rpc"])
def t1_mirror_shape(ctx):
    server = ctx.server("s1")
    expected = build_shape(server, "t1")
    mirror = ctx.mirror(server)
    result = mirror.attach()
    workspace_ids = result.get("workspace_ids") or []
    ctx.check(len(workspace_ids) == 2, f"the mirror reports 2 workspaces (got {len(workspace_ids)})")
    expect_shapes(ctx, mirror, expected)
    rows = [r for r in ctx.h.cmux.workspaces() if r["id"] in set(workspace_ids)]
    ctx.check(len(rows) == len(workspace_ids), "every reported workspace exists in the app")
    titles = " | ".join(r["title"] for r in rows)
    for session in expected:
        ctx.check(any(session in r["title"] for r in rows), f"a workspace title names {session} (titles: {titles})")


@test("T2", ["R2", "R21"], "The mirror shows the caller's server, whatever the app's environment says", needs=["rpc", "cli"])
def t2_callers_server(ctx):
    tmpdir, default_sock = private_tmpdir(ctx, "tt")
    servers = {
        "default": (ctx.server("def", socket_path=default_sock), "t2-def"),
        "alt": (ctx.server("alt", socket_path=os.path.join(tmpdir, f"tmux-{UID}", "alt")), "t2-alt"),
        "path": (ctx.server("x", socket_path=os.path.join(ctx.dir, "x.sock")), "t2-x"),
    }
    for server, session in servers.values():
        server.new_session(session)

    def expect_only(label, target):
        tserver, tsession = servers[target]
        mirror = ctx.mirror(tserver)
        try:
            wait_until(lambda: mirror.is_mirrored(tsession), timeout=15.0, what=f"{tsession} mirrored")
            ctx.check(True, f"{label}: mirrors {tsession}")
        except CheckFailed as error:
            ctx.check(False, f"{label}: mirrors {tsession} ({error})")
        for name, (oserver, osession) in servers.items():
            if name == target:
                continue
            ctx.check(not oserver.control_clients(), f"{label}: no control client on the {name} server")
            ctx.check(not ctx.mirror(oserver).is_mirrored(osession), f"{label}: {osession} is not mirrored")
        mirror.detach(tsession)
        no_control_clients(tserver)

    base_env = {"TMUX_TMPDIR": tmpdir}
    cases = [
        ("outside tmux, TMUX_TMPDIR", [], "default"),
        ("--socket-name alt", ["--socket-name", "alt"], "alt"),
        ("--socket-path", ["--socket-path", servers["path"][0].socket_path], "path"),
    ]
    for label, flags, target in cases:
        rc, payload, out, err = cli_json(ctx, ["tmux-mirror", "--no-focus"] + flags, env_extra=base_env, cwd=ctx.dir)
        ctx.check(rc == 0, f"{label}: the CLI exits 0 ({rc}: {(out + err).strip()[:200]})")
        expect_only(label, target)

    # Inside a pane of each server, with a TMUX_TMPDIR that names a different server: the
    # pane's own server wins (D3 rule 3 over rule 4).
    for name, (server, session) in servers.items():
        rcfile = os.path.join(ctx.dir, f"pane-{name}.rc")
        outfile = os.path.join(ctx.dir, f"pane-{name}.out")
        command = (f"TMUX_TMPDIR='{tmpdir}' CMUX_TAG='{ctx.h.tag}' '{ctx.h.app.cli_wrapper}' tmux-mirror --no-focus"
                   f" > '{outfile}' 2>&1; echo $? > '{rcfile}'")
        if name == "default":
            # The default server is the TMUX_TMPDIR one, so point TMUX_TMPDIR elsewhere for it.
            command = command.replace(f"TMUX_TMPDIR='{tmpdir}'", f"TMUX_TMPDIR='{ctx.dir}'")
        server.run("new-window", "-d", "-t", f"={session}", command)
        try:
            wait_until(lambda: os.path.exists(rcfile) and open(rcfile).read().strip(), timeout=60.0,
                       what=f"the CLI in a pane of the {name} server to finish")
            rc = open(rcfile).read().strip()
            ctx.check(rc == "0", f"inside a {name} pane: the CLI exits 0 ({rc}: {open(outfile).read().strip()[:200]})")
        except CheckFailed as error:
            ctx.check(False, f"inside a {name} pane: {error}")
        expect_only(f"inside a {name} pane", name)

    # R21: the app's own TMUX, TMUX_PANE and TMUX_TMPDIR name decoy servers.
    decoy_tmpdir, decoy_default = private_tmpdir(ctx, "decoy")
    decoy_a = ctx.server("decoy-a", socket_path=os.path.join(ctx.dir, "decoy.sock"))
    decoy_b = ctx.server("decoy-b", socket_path=decoy_default)
    decoy_a.new_session("t2-decoy-a")
    decoy_b.new_session("t2-decoy-b")
    ctx.relaunch({"TMUX": f"{decoy_a.socket_path},4242,0", "TMUX_PANE": "%0", "TMUX_TMPDIR": decoy_tmpdir},
                 label="decoy-tmux-env")
    target_server, target_session = servers["path"]
    rc, payload, out, err = cli_json(ctx, ["tmux-mirror", "--no-focus", "--socket-path", target_server.socket_path],
                                     env_extra=base_env, cwd=ctx.dir)
    ctx.check(rc == 0, f"decoy app environment: the CLI exits 0 ({rc})")
    mirror = ctx.mirror(target_server)
    try:
        wait_until(lambda: mirror.is_mirrored(target_session), timeout=15.0, what="the resolved server mirrored")
        ctx.check(True, "decoy app environment: the resolved server is mirrored")
    except CheckFailed as error:
        ctx.check(False, f"decoy app environment: the resolved server is mirrored ({error})")
    shape = mirror.shape(target_session)
    ctx.check(shape is not None and len(shape) == len(target_server.windows(target_session)),
              f"decoy app environment: the mirrored tabs match the resolved server's windows ({shape})")
    for decoy, name in ((decoy_a, "TMUX"), (decoy_b, "TMUX_TMPDIR")):
        ctx.check(not decoy.control_clients(), f"decoy app environment: the {name} decoy has no control client")
    ctx.check(not ctx.mirror(decoy_a).is_mirrored("t2-decoy-a") and not ctx.mirror(decoy_b).is_mirrored("t2-decoy-b"),
              "decoy app environment: no decoy session is mirrored")


@test("T3", ["R3"], "Two-way sync between cmux and another tmux client", needs=["rpc"])
def t3_two_way_sync(ctx):
    server = ctx.server("s3")
    server.new_session("t3")
    mirror = ctx.mirror(server)
    result = mirror.attach()
    workspace_id = (result.get("workspace_ids") or [""])[0]
    expect_shapes(ctx, mirror, {"t3": [1]})
    pane = first_pane(server, "t3")
    surface = surface_of(ctx, mirror, "t3", pane)
    app = ctx.h.app
    # The mirror was attached without focus, so name its workspace: surface commands
    # otherwise look for the surface in the selected workspace (Q-A4).
    owner = ctx.h.cmux.workspace_of_surface(surface)
    ctx.check(owner is not None, f"the mirrored pane's surface belongs to a workspace ({owner})")
    workspace_id = owner or workspace_id

    # cmux -> tmux.
    rc, out, err = app.cli(["new-split", "right", "--workspace", workspace_id, "--surface", surface])
    ctx.check(rc == 0, f"cmux split exits 0 ({(out + err).strip()[:160]})")
    try:
        wait_until(lambda: server.windows("t3")[0]["panes"] == 2, what="tmux to show the split")
        ctx.check(True, "a split made in cmux appears in tmux")
    except CheckFailed as error:
        ctx.check(False, f"a split made in cmux appears in tmux ({error})")
    rc, out, err = app.cli(["rename-tab", "--workspace", workspace_id, "--surface", surface, "t3-from-cmux"])
    ctx.check(rc == 0, f"cmux rename exits 0 ({(out + err).strip()[:160]})")
    try:
        wait_until(lambda: any(w["name"] == "t3-from-cmux" for w in server.windows("t3")), what="tmux to show the rename")
        ctx.check(True, "a rename made in cmux appears in tmux")
    except CheckFailed as error:
        ctx.check(False, f"a rename made in cmux appears in tmux ({error})")
    rc, out, err = app.cli(["new-surface", "--workspace", workspace_id])
    ctx.check(rc == 0, f"cmux new tab exits 0 ({(out + err).strip()[:160]})")
    try:
        wait_until(lambda: len(server.windows("t3")) == 2, what="tmux to show the new window")
        ctx.check(True, "a new tab made in cmux appears in tmux as a window")
    except CheckFailed as error:
        ctx.check(False, f"a new tab made in cmux appears in tmux as a window ({error})")

    # tmux (another client) -> cmux.
    windows = server.windows("t3")
    server.run("split-window", "-v", "-t", windows[-1]["id"])
    server.run("rename-window", "-t", windows[-1]["id"], "t3-from-tmux")
    server.run("new-window", "-d", "-t", "=t3")
    expected = sorted([w["panes"] for w in server.windows("t3")])
    try:
        wait_until(lambda: mirror.shape("t3") == expected, what=f"cmux to show windows {expected}")
        ctx.check(True, f"splits and windows made in tmux appear in cmux ({expected})")
    except CheckFailed as error:
        ctx.check(False, f"splits and windows made in tmux appear in cmux ({mirror.shape('t3')} vs {expected})")

    def titles():
        listing = ctx.h.cmux.result("surface.list", {"workspace_id": workspace_id})
        return json.dumps(listing)
    try:
        wait_until(lambda: "t3-from-tmux" in titles(), what="the tab title to follow the tmux rename")
        ctx.check(True, "a rename made in tmux appears in cmux")
    except CheckFailed as error:
        ctx.check(False, f"a rename made in tmux appears in cmux ({error})")


@test("T4", ["R4"], "No SSH is involved", needs=["rpc"])
def t4_no_ssh(ctx):
    marker = os.path.join(ctx.dir, "ssh-was-run")
    trap = write_script(os.path.join(ctx.dir, "trap-ssh"),
                        f"#!/bin/sh\necho \"$@\" >> '{marker}'\necho 'trap ssh: must not run' >&2\nexit 255\n")
    ssh_dir = os.path.join(HOME, ".cmux", "ssh")
    before = sorted(os.listdir(ssh_dir)) if os.path.isdir(ssh_dir) else None
    ctx.relaunch({"CMUX_REMOTE_TMUX_SSH_FOR_TESTING": trap}, label="trap-ssh")
    server = ctx.server("s4")
    expected = build_shape(server, "t4")
    mirror = ctx.mirror(server)
    mirror.attach()
    expect_shapes(ctx, mirror, expected)
    if has_feature(ctx, "cli"):
        mirror.detach_all(list(expected))
        no_control_clients(server)
        rc, out, err = ctx.h.app.cli(["tmux-mirror", "--no-focus", "--socket-path", server.socket_path])
        ctx.check(rc == 0, f"the CLI mirror exits 0 with ssh replaced by a trap ({rc})")
        ctx.check("ssh" not in (out + err).lower(), "the CLI output never mentions ssh")
        expect_shapes(ctx, mirror, expected)
    ctx.check(not os.path.exists(marker), "the ssh executable was never run")
    after = sorted(os.listdir(ssh_dir)) if os.path.isdir(ssh_dir) else None
    ctx.check(before == after, f"nothing new under ~/.cmux/ssh ({before} -> {after})")


@test("T5", ["R5"], "A Dock-launched app finds tmux in the usual install prefixes", needs=["rpc"])
def t5_gui_path(ctx):
    gui_tmux = gui_install_tmux()
    if not gui_tmux:
        raise Skipped("no tmux in /opt/homebrew/bin, /usr/local/bin or /opt/local/bin")
    ctx.log(f"tmux in an install prefix: {gui_tmux}")
    ctx.relaunch(path="/usr/bin:/bin", label="gui-path")
    server = ctx.server("s5", binary=gui_tmux)
    server.new_session("t5")
    server.run("split-window", "-h", "-t", "=t5:0")
    mirror = ctx.mirror(server)
    mirror.attach()
    expect_shapes(ctx, mirror, {"t5": [2]})


@test("T6", ["R6", "R14"], "Each failure has its own localized message about local tmux", needs=["rpc", "cli"])
def t6_error_matrix(ctx):
    catalog = load_catalog(ctx)
    messages = {}

    def refused(label, socket_path):
        reply = ctx.h.cmux.call("remote.tmux.mirror", dict(local_host(socket_path), activate=False), timeout=60.0)
        message = error_message(reply) if reply.get("ok") is not True else ""
        ctx.check(reply.get("ok") is not True, f"{label}: the mirror is refused")
        ctx.check(bool(message.strip()), f"{label}: the refusal carries a message ({message[:120]!r})")
        ctx.check("ssh" not in message.lower(), f"{label}: the message does not mention ssh")
        if message:
            localized_check(ctx, catalog, message, label)
            messages[label] = message

    refused("socket missing", os.path.join(ctx.dir, "absent.sock"))
    stale = os.path.join(ctx.dir, "stale.sock")
    bind_stale_socket(stale)
    refused("no server running", stale)
    regular = os.path.join(ctx.dir, "regular.sock")
    open(regular, "w").close()
    refused("socket not owned by the user (faked with a regular file)", regular)
    foreign = "/var/run/mDNSResponder"
    try:
        info = os.stat(foreign)
        if stat.S_ISSOCK(info.st_mode) and info.st_uid != UID:
            refused("socket owned by another user", foreign)
        else:
            ctx.log(f"{foreign} is not another user's socket here; that case is skipped")
    except OSError:
        ctx.log(f"{foreign} does not exist; the other-user socket case is skipped")

    # tmux older than 3.2: a fake tmux first on the app's PATH reports 3.1.
    fakebin = os.path.join(ctx.dir, "old-tmux-bin")
    os.makedirs(fakebin)
    write_script(os.path.join(fakebin, "tmux"), f"""#!/bin/sh
for a in "$@"; do
  case "$a" in
    -V) echo "tmux 3.1"; exit 0 ;;
    *'#{{version}}'*) case " $* " in *" refresh-client "*) echo "unknown option -- B" >&2; exit 1 ;; *) echo "3.1"; exit 0 ;; esac ;;
  esac
done
exec '{ctx.h.tmux_bin}' "$@"
""")
    ctx.relaunch(path=f"{fakebin}:/usr/bin:/bin:/usr/sbin:/sbin", label="old-tmux")
    server = ctx.server("s6")
    server.new_session("t6")
    refused("tmux older than 3.2", server.socket_path)
    ctx.h.app.launch(label="base")
    ctx.log("tmux not installed: not reproducible live, because the resolver also searches the fixed "
            "install prefixes; adversarial test A3 covers it with fake binaries")

    labels = list(messages)
    distinct = len(set(messages.values())) == len(messages)
    ctx.check(distinct, "every failure has its own message: " + json.dumps(messages)[:400])

    # The CLI path: a socket path that names a regular file.
    rc, out, err = ctx.h.app.cli(["tmux-mirror", "--no-focus", "--socket-path", regular])
    text = (out + err).strip()
    ctx.check(rc != 0, f"the CLI exits non-zero for a socket path that is not a socket ({rc})")
    ctx.check(bool(text) and "ssh" not in text.lower(), f"the CLI error is about local tmux ({text[:160]!r})")
    if text:
        localized_check(ctx, catalog, text.splitlines()[-1], "CLI error")
    rc, out, err = ctx.h.app.cli(["tmux-mirror", "--help"])
    help_lines = [line.strip() for line in out.splitlines() if len(line.strip()) > 20]
    ctx.check(bool(help_lines), "cmux tmux-mirror --help prints help text")
    untranslated = []
    for line in help_lines:
        found = catalog.lookup(line) if catalog else None
        if found is None or found[1]:
            untranslated.append(line[:60])
    ctx.check(not untranslated, f"every help line is a fully translated catalog string (not: {untranslated[:5]})")
    ctx.check("local-tmux" in out, "the help names cmux local-tmux (D9)")
    _ = labels


@test("T7", ["R7"], "Closing a mirror workspace or window keeps the tmux session", needs=["rpc"])
def t7_close_keeps_session(ctx):
    server = ctx.server("s7")
    server.new_session("t7")
    mirror = ctx.mirror(server)
    result = mirror.attach()
    expect_shapes(ctx, mirror, {"t7": [1]})
    for workspace_id in result.get("workspace_ids") or []:
        ctx.h.cmux.result("workspace.close", {"workspace_id": workspace_id})
    ctx.check(no_control_clients(server), "after closing the workspace, no cmux control client is attached")
    ctx.check("t7" in server.sessions(), "after closing the workspace, tmux ls still lists the session")

    result = mirror.attach(new_window=True)
    window_id = result.get("window_id")
    expect_shapes(ctx, mirror, {"t7": [1]})
    ctx.require(bool(window_id), "the dedicated-window mirror reports its window")
    ctx.h.cmux.result("window.close", {"window_id": window_id})
    ctx.check(no_control_clients(server), "after closing the window, no cmux control client is attached")
    ctx.check("t7" in server.sessions(), "after closing the window, tmux ls still lists the session")


@test("T8", ["R8"], "Pasting an image inserts its local file path", needs=["rpc"])
def t8_paste(ctx):
    server = ctx.server("s8")
    server.new_session("t8")
    mirror = ctx.mirror(server)
    mirror.attach()
    expect_shapes(ctx, mirror, {"t8": [1]})
    pane = first_pane(server, "t8")
    surface = surface_of(ctx, mirror, "t8", pane)
    image = os.path.join(ctx.dir, "paste me.png")
    with open(image, "wb") as handle:
        handle.write(ONE_PIXEL_PNG)
    path_pattern = re.compile(r"(/(?:[^\s'\"\\]|\\.)+\.(?:png|jpe?g|tiff?|heic|gif))", re.IGNORECASE)

    def inserted_paths():
        text = server.run("capture-pane", "-p", "-J", "-t", pane).stdout
        return [m.replace("\\", "") for m in path_pattern.findall(text)]

    # The drop RPC takes no workspace parameter and looks the surface up only in the active
    # window's selected workspace (resolveTerminalPanel, Q-A11), and the mirror was attached
    # without focus. Select the mirror's workspace for the drop, as a user dropping onto that
    # pane would have it on screen, then put the previous selection back.
    previous = ctx.h.cmux.current_workspace()
    owner = ctx.h.cmux.workspace_of_surface(surface)
    ctx.check(owner is not None, f"the mirrored pane's surface belongs to a workspace ({owner})")
    if owner:
        ctx.h.cmux.result("workspace.select", {"workspace_id": owner})
        if previous and previous != owner:
            ctx.on_cleanup(lambda: ctx.h.cmux.call("workspace.select", {"workspace_id": previous}))
    reply = ctx.h.cmux.call("debug.terminal.simulate_file_drop",
                            {"surface_id": surface, "paths": [image], "route": "terminal", "payload": "image"})
    ctx.check(reply.get("ok") is True, f"the image drop is accepted ({reply.get('error')})")
    try:
        paths = wait_until(lambda: [p for p in inserted_paths() if os.path.isfile(p)], timeout=10.0,
                           what="a local image path in the pane")
        ctx.check(True, f"the pane received a local image path ({paths[0]})")
    except CheckFailed as error:
        ctx.check(False, f"the pane received a local image path ({inserted_paths()}): {error}")


@test("T9", ["R9"], "Sessions created after the attach behave as they do for ssh-tmux", needs=[])
def t9_later_sessions(ctx):
    shim = os.path.join(ctx.h.repo, "scripts", "remote-tmux-e2e-ssh-shim.sh")
    app = ctx.h.app
    ctx.on_cleanup(lambda: app.set_default("remoteTmux.multiplexer.beta.enabled", None))

    def seen(mirror, session):
        if mirror.is_mirrored(session):
            return True
        return any(session in row["title"] for row in ctx.h.cmux.workspaces())

    def scenario(kind):
        observed = {}
        for mode in ("off", "on"):
            app.set_default("remoteTmux.multiplexer.beta.enabled", mode == "on")
            if kind == "ssh":
                tmpdir, sock = private_tmpdir(ctx, f"ssh-{mode}")
                server = ctx.server(f"ssh-{mode}", socket_path=sock)
                ctx.relaunch({"CMUX_REMOTE_TMUX_SSH_FOR_TESTING": shim, "TMUX_TMPDIR": tmpdir}, label=f"t9-ssh-{mode}")
                mirror = ctx.mirror({"host": "t9-shim-host"})
                command = ["ssh-tmux", "t9-shim-host", "--no-focus"]
            else:
                server = ctx.server(f"local-{mode}")
                ctx.relaunch(label=f"t9-local-{mode}")
                mirror = ctx.mirror(server)
                command = ["tmux-mirror", "--no-focus", "--socket-path", server.socket_path]
            server.new_session("t9-a")
            base = ctx.h.cmux.new_plain_workspace()
            rc, _, out, err = cli_json(ctx, command, cwd=ctx.dir)
            if rc != 0:
                raise CheckFailed(f"{kind} {mode}: the command failed ({rc}: {(out + err).strip()[:200]})")
            wait_until(lambda: seen(mirror, "t9-a"), timeout=15.0, what=f"{kind} {mode}: t9-a mirrored")
            ctx.h.cmux.result("workspace.select", {"workspace_id": base})
            if mode == "off":
                server.new_session("t9-b")
                time.sleep(3.0)  # absence can only be shown by waiting; 3 s is the observation window
                before_rerun = seen(mirror, "t9-b")
                ids_before = ctx.h.cmux.workspace_ids()
                rc, _, out, err = cli_json(ctx, command, cwd=ctx.dir)
                try:
                    wait_until(lambda: seen(mirror, "t9-b"), timeout=15.0, what="t9-b after re-running")
                    after_rerun = True
                except CheckFailed:
                    after_rerun = False
                added = len(ctx.h.cmux.workspace_ids() - ids_before)
                observed["off"] = {"before_rerun": before_rerun, "after_rerun": after_rerun, "added": added}
            else:
                server.new_session("t9-c")
                try:
                    wait_until(lambda: seen(mirror, "t9-c"), timeout=8.0, what="t9-c to appear")
                    appeared = True
                except CheckFailed:
                    appeared = False
                observed["on"] = {"appeared": appeared, "focus_unchanged": ctx.h.cmux.current_workspace() == base}
            mirror.detach_all(server.sessions())
            server.kill()
        ctx.log(f"{kind}: {json.dumps(observed)}")
        return observed

    ssh_observed = scenario("ssh")
    if not has_feature(ctx, "cli"):
        notimpl_if_clean(ctx, f"ssh-tmux reference behavior recorded ({json.dumps(ssh_observed)}); "
                              f"{ctx.h.feature_notes['cli']}")
    local_observed = scenario("local")
    ctx.check(local_observed == ssh_observed,
              f"the local mirror behaves as ssh-tmux does (local {local_observed}, ssh {ssh_observed})")
    ctx.check(local_observed.get("off") == {"before_rerun": False, "after_rerun": True, "added": 1},
              f"beta off: the new session appears only after re-running, as exactly one workspace ({local_observed.get('off')})")
    ctx.check(local_observed.get("on") == {"appeared": True, "focus_unchanged": True},
              f"beta on: the new session appears without taking focus ({local_observed.get('on')})")


@test("T10", ["R10"], "local-tmux and `cmux tmux attach` keep working, and its server can be mirrored", needs=[])
def t10_local_tmux(ctx):
    app = ctx.h.app
    name = f"t10-{os.getpid()}"
    ctx.on_cleanup(lambda: app.cli(["local-tmux", "close", "--name", name]))
    rc, out, err = app.cli(["local-tmux", "start", "--name", name, "--detached"], cwd=ctx.dir)
    ctx.require(rc == 0, f"cmux local-tmux start exits 0 ({rc}: {(out + err).strip()[:200]})")
    rc, out, err = app.cli(["local-tmux", "list", "--json"])
    ctx.require(rc == 0, f"cmux local-tmux list --json exits 0 ({rc})")
    listing = json.loads(out)
    socket_path = listing.get("socket_path")
    row = next((r for r in listing.get("sessions") or [] if name in json.dumps(r)), None)
    ctx.require(bool(socket_path) and row is not None, f"local-tmux lists {name} and its socket path")
    session_name = row.get("session_name") or name
    rc, out, err = app.cli(["tmux", "attach", "--name", name, "--no-focus"])
    ctx.check(rc == 0, f"cmux tmux attach (the alias) exits 0 ({rc}: {(out + err).strip()[:200]})")
    if not has_feature(ctx, "cli"):
        notimpl_if_clean(ctx, f"local-tmux and its alias work; mirroring its socket needs cmux tmux-mirror "
                              f"({ctx.h.feature_notes['cli']})")
    mirror = ctx.mirror(local_host(socket_path))
    ctx.on_cleanup(lambda: mirror.detach(session_name))
    rc, out, err = app.cli(["tmux-mirror", "--no-focus", "--socket-path", socket_path])
    ctx.check(rc == 0, f"mirroring the local-tmux socket exits 0 ({rc}: {(out + err).strip()[:200]})")
    try:
        wait_until(lambda: mirror.is_mirrored(session_name), timeout=15.0, what="the local-tmux session mirrored")
        ctx.check(True, "the local-tmux profile's session is mirrored through its socket path")
    except CheckFailed as error:
        ctx.check(False, f"the local-tmux profile's session is mirrored through its socket path ({error})")


def fnv1a64_hex(text):
    value = 0xcbf29ce484222325
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


@test("T11", ["R11"], "ssh mirrors behave as before (through the ssh shim)", needs=[])
def t11_ssh_unchanged(ctx):
    host = "t11-shim-host"
    shim = os.path.join(ctx.h.repo, "scripts", "remote-tmux-e2e-ssh-shim.sh")
    argv_log = os.path.join(ctx.dir, "ssh-argv.log")
    logging_shim = write_script(os.path.join(ctx.dir, "logging-ssh"),
                                f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{argv_log}'\nexec '{shim}' \"$@\"\n")
    tmpdir, sock = private_tmpdir(ctx, "ssh")
    server = ctx.server("s11", socket_path=sock)
    expected = build_shape(server, "t11")
    ctx.relaunch({"CMUX_REMOTE_TMUX_SSH_FOR_TESTING": logging_shim, "TMUX_TMPDIR": tmpdir}, label="t11-ssh-shim")
    mirror = ctx.mirror({"host": host})
    ctx.on_cleanup(lambda: mirror.detach_all(list(expected)))
    rc, payload, out, err = cli_json(ctx, ["ssh-tmux", host, "--no-focus"], cwd=ctx.dir)
    ctx.check(rc == 0, f"cmux ssh-tmux exits 0 ({rc}: {(out + err).strip()[:200]})")
    ctx.check(payload is not None and len(payload.get("workspace_ids") or []) == 2,
              f"ssh-tmux reports 2 workspaces ({payload})")
    expect_shapes(ctx, mirror, expected)
    expected_tail = f"-{fnv1a64_hex(host + chr(0x1f) + chr(0x1f))}.sock"
    paths = []
    if os.path.exists(argv_log):
        paths = re.findall(r"ControlPath=(\S+)", open(argv_log).read())
    ctx.check(bool(paths), "ssh was invoked with a ControlPath")
    prefix = os.path.join(HOME, ".cmux", "ssh", "tmux-")
    ctx.check(all(p.startswith(prefix) and p.endswith(expected_tail) for p in paths),
              f"the ControlMaster socket path is unchanged ({sorted(set(paths))[:2]}, expected {prefix}...{expected_tail})")

    # Evidence for Q-A4 (log only, not part of R11): how renaming an ssh mirror tab by its
    # surface id behaves on this build, without and then with the owning workspace named.
    session = "t11-alpha"
    pane = first_pane(server, session)
    surface = mirror.surface_for_pane(session, pane)
    owner = ctx.h.cmux.workspace_of_surface(surface) if surface else None
    for label, args in (("--surface only", ["rename-tab", "--surface", str(surface), "t11-ren-a"]),
                        ("--workspace and --surface", ["rename-tab", "--workspace", str(owner),
                                                       "--surface", str(surface), "t11-ren-b"])):
        rc, out, err = ctx.h.app.cli(args)
        time.sleep(1.0)  # observation window for tmux to show a rename, log-only probe
        names = [w["name"] for w in server.windows(session)]
        ctx.log(f"Q-A4 probe, ssh mirror rename with {label}: exit {rc}, "
                f"output {(out + err).strip()[:160]!r}, tmux window names now {names}")


@test("T12", ["R12"], "The same session mirrored locally and over ssh at once", needs=["rpc"])
def t12_local_and_ssh(ctx):
    probe = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if probe.returncode != 0:
        raise Skipped("no key-based loopback ssh here (`ssh localhost` fails); T12 is manual on this machine")
    gui_tmux = gui_install_tmux()
    if not gui_tmux:
        raise Skipped("the ssh side needs tmux in an install prefix the remote resolver searches")
    default_sock = f"/tmp/tmux-{UID}/default"
    server = Tmux(default_sock, gui_tmux)
    if server.alive():
        raise Skipped(f"a tmux server this harness did not start already runs at {default_sock}")
    ctx.servers.append(server)
    server.new_session("t12")
    local = ctx.mirror(server)
    remote = ctx.mirror({"host": "localhost"})
    ctx.on_cleanup(lambda: remote.detach("t12"))
    local.attach(session="t12")
    rc, out, err = ctx.h.app.cli(["ssh-tmux", "localhost", "--no-focus"], cwd=ctx.dir, timeout=120.0)
    ctx.require(rc == 0, f"cmux ssh-tmux localhost exits 0 ({rc}: {(out + err).strip()[:200]})")
    expect_shapes(ctx, local, {"t12": [1]})
    expect_shapes(ctx, remote, {"t12": [1]})
    pane = first_pane(server, "t12")
    local_surface = surface_of(ctx, local, "t12", pane)
    rc, _, _ = ctx.h.app.cli(["new-split", "right", "--workspace", ctx.h.cmux.workspace_of_surface(local_surface) or "",
                              "--surface", local_surface])
    ctx.check(rc == 0, "a split in the local mirror is accepted")
    expect_shapes(ctx, remote, {"t12": [2]})
    remote_surface = surface_of(ctx, remote, "t12", pane)
    rc, _, _ = ctx.h.app.cli(["new-split", "down", "--workspace", ctx.h.cmux.workspace_of_surface(remote_surface) or "",
                              "--surface", remote_surface])
    ctx.check(rc == 0, "a split in the ssh mirror is accepted")
    expect_shapes(ctx, local, {"t12": [3]})


@test("T13", ["R13"], "Focus policy: interactive runs focus, scripts do not, flags override", needs=["rpc", "cli"])
def t13_focus(ctx):
    server = ctx.server("s13")
    server.new_session("t13")
    mirror = ctx.mirror(server)
    app = ctx.h.app
    base = ctx.h.cmux.new_plain_workspace()
    command = ["tmux-mirror", "--socket-path", server.socket_path]
    cases = [
        ("run by a script, no flag", False, [], False),
        ("run interactively, no flag", True, [], True),
        ("run interactively, --no-focus", True, ["--no-focus"], False),
        ("run by a script, --focus", False, ["--focus"], True),
    ]
    for label, interactive, flags, should_focus in cases:
        ctx.h.cmux.result("workspace.select", {"workspace_id": base})
        if interactive:
            rc, out = app.cli_tty(command + flags, cwd=ctx.dir)
        else:
            rc, out, err = app.cli(command + flags, cwd=ctx.dir)
            out += err
        ctx.check(rc == 0, f"{label}: exits 0 ({rc}: {out.strip()[:160]})")
        try:
            wait_until(lambda: mirror.is_mirrored("t13"), timeout=15.0, what="t13 mirrored")
        except CheckFailed as error:
            ctx.check(False, f"{label}: {error}")
        current = ctx.h.cmux.current_workspace()
        focused = current != base
        ctx.check(focused == should_focus, f"{label}: {'focuses the mirror' if should_focus else 'leaves focus where it was'}")
        mirror.detach("t13")
        no_control_clients(server)


@test("T14", ["R15"], "Attach latency (benchmark)", needs=[])
def t14_attach_latency(ctx):
    raise Skipped("measured by scripts/remote-tmux-local-bench.sh in check.sh's bench stage")


@test("T15", ["R16"], "Input latency (benchmark)", needs=[])
def t15_input_latency(ctx):
    raise Skipped("measured by scripts/remote-tmux-local-bench.sh in check.sh's bench stage")


def lsof_listing(pid):
    return subprocess.run(["lsof", "-n", "-P", "-p", str(pid)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True).stdout


def count_fds(pid):
    return max(0, len(lsof_listing(pid).splitlines()) - 1)


def descriptor_kinds(listing):
    """Counts lsof rows by (TYPE, NAME), with the NAME's per-process noise (pipe and socket
    addresses, which change on every open) folded, so two listings can be compared."""
    # Columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME, but PIPE and KQUEUE rows
    # leave DEVICE, SIZE/OFF and NODE empty, so they have fewer fields (round 3 skipped them,
    # which is why it said "grown: none"). Key on TYPE, the fifth field every row has, and
    # the last field: the NAME, or a pipe's address. lsof escapes spaces in the command
    # name (\x20), so the columns do not shift.
    counts = {}
    for line in listing.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        kind = parts[4]
        name = re.sub(r"0x[0-9a-f]+", "0x…", parts[-1]) if len(parts) > 5 else ""
        counts[(kind, name)] = counts.get((kind, name), 0) + 1
    return counts


def descriptor_difference(before, after):
    """Rows whose count changed between the listings, as 'TYPE NAME (+n)' or '(-n)', growth first."""
    a, b = descriptor_kinds(before), descriptor_kinds(after)
    changed = [(k, b.get(k, 0) - a.get(k, 0)) for k in set(a) | set(b) if b.get(k, 0) != a.get(k, 0)]
    changed.sort(key=lambda item: -item[1])
    return [f"{kind} {name} ({n:+d})" for (kind, name), n in changed]


def child_pids(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], stdout=subprocess.PIPE, text=True).stdout
    return {int(p) for p in out.split()}


@test("T16", ["R17"], "No descriptor, process or client leak after repeated attach and detach", needs=["rpc"])
def t16_leaks(ctx):
    cycles = ctx.h.leak_cycles
    server = ctx.server("s16")
    server.new_session("t16")
    mirror = ctx.mirror(server)
    pid = ctx.h.app.pid()
    ctx.require(pid is not None, "the tagged app's pid is known")

    def cycle():
        mirror.attach()
        wait_until(lambda: mirror.is_mirrored("t16"), timeout=15.0, what="t16 mirrored")
        mirror.detach("t16")
        if not no_control_clients(server, timeout=10.0):
            raise CheckFailed("the control client stayed attached after detach")

    cycle()  # warm-up: first use may open long-lived resources
    base_listing = lsof_listing(pid)
    base_fds, base_children = max(0, len(base_listing.splitlines()) - 1), len(child_pids(pid))
    ctx.log(f"baseline: {base_fds} descriptors, {base_children} children")
    for _ in range(cycles):
        cycle()

    def settled():
        return count_fds(pid) <= base_fds and len(child_pids(pid)) <= base_children
    try:
        wait_until(settled, timeout=15.0, interval=0.5, what="counts back at the baseline")
    except CheckFailed:
        pass
    end_listing = lsof_listing(pid)
    fds, children = max(0, len(end_listing.splitlines()) - 1), len(child_pids(pid))
    for name, listing in (("t16-lsof-baseline.txt", base_listing), ("t16-lsof-after.txt", end_listing)):
        with open(os.path.join(ctx.h.artifacts, name), "w") as handle:
            handle.write(listing)
    changed = descriptor_difference(base_listing, end_listing)
    if changed:
        ctx.log("descriptor kinds whose count changed over the cycles: " + "; ".join(changed[:40]))
    ctx.check(fds <= base_fds, f"after {cycles} cycles, descriptors are back at the baseline ({fds} vs {base_fds}; "
              f"changed: {'; '.join(changed[:8]) or 'none'}; full listings in t16-lsof-*.txt)")
    ctx.check(children <= base_children, f"after {cycles} cycles, child processes are back at the baseline ({children} vs {base_children})")
    ctx.check(not server.control_clients(), "no cmux control client is left attached")


@test("T17", ["R18"], "A crashed cmux leaves no control client behind", needs=["rpc"])
def t17_crash(ctx):
    server = ctx.server("s17")
    server.new_session("t17a")
    server.new_session("t17b")
    mirror = ctx.mirror(server)
    mirror.attach()
    expect_shapes(ctx, mirror, {"t17a": [1], "t17b": [1]})
    ctx.require(bool(server.control_clients()), "the mirror holds control clients before the crash")
    pid = ctx.h.app.pid()
    ctx.require(pid is not None, "the tagged app's pid is known")
    # Diagnostics for Q-A12 (they do not change the check): the clients' and the app's
    # process group and session before the kill, and, for any client still attached after
    # it, its process state and open descriptors, then how long it took to go away.
    capture = os.path.join(ctx.h.artifacts, "t17-capture.txt")

    def ps_rows(pids):
        if not pids:
            return "(none)\n"
        return subprocess.run(["ps", "-o", "pid,ppid,pgid,sess,stat,command", "-p", ",".join(pids)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout

    before = [c["pid"] for c in server.control_clients()]
    with open(capture, "w") as out:
        out.write(f"app pid {pid}; before the kill:\n" + ps_rows([str(pid)] + before))
    os.kill(pid, signal.SIGKILL)
    killed_at = time.monotonic()
    time.sleep(max(0.0, 2.0 - (time.monotonic() - killed_at)))
    left = server.control_clients()
    if left:
        pids = [c["pid"] for c in left]
        with open(capture, "a") as out:
            out.write("\n2 s after kill -9, still attached:\n" + ps_rows(pids))
            for client in pids:
                listing = subprocess.run(["lsof", "-n", "-P", "-p", client], stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, text=True).stdout
                out.write(f"\nlsof -p {client}:\n{listing}")
            # Who else holds the clients' ttys open: the pty master's holder is the question.
            for client in pids:
                tty = subprocess.run(["ps", "-o", "tty=", "-p", client], stdout=subprocess.PIPE, text=True).stdout.strip()
                if tty and tty not in ("??", "-"):
                    holders = subprocess.run(["lsof", "-n", "-P", f"/dev/{tty}"], stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT, text=True).stdout
                    out.write(f"\nholders of /dev/{tty} (client {client}):\n{holders}")
        try:
            wait_until(lambda: not server.control_clients(), timeout=15.0, interval=0.1, what="the clients to detach")
            gone = time.monotonic() - killed_at
        except CheckFailed:
            gone = None
        ctx.log(f"leftover clients went away {f'{gone:.1f} s' if gone else 'not within 17 s'} after the kill; "
                f"ps and lsof in t17-capture.txt")
    ctx.check(not left, f"2 seconds after kill -9, no control client from cmux remains ({left})")
    ctx.check(sorted(server.sessions()) == ["t17a", "t17b"], "every session is still running")
    ctx.h.app.current_env_label = "killed"


@test("T18", ["R19"], "When the server dies, the mirror ends promptly and does not retry in a loop", needs=["rpc"])
def t18_server_dies(ctx):
    server = ctx.server("s18")
    server.new_session("t18a")
    server.new_session("t18b")
    mirror = ctx.mirror(server)
    result = mirror.attach()
    workspace_ids = set(result.get("workspace_ids") or [])
    expect_shapes(ctx, mirror, {"t18a": [1], "t18b": [1]})
    pid = ctx.h.app.pid()
    notes_before_keys = {str(n.get("id") or json.dumps(n, sort_keys=True))
                         for n in ctx.h.cmux.result("notification.list").get("notifications") or []}
    children_before = child_pids(pid) if pid else set()
    server.kill()
    killed_at = time.monotonic()
    try:
        wait_until(lambda: not (workspace_ids & ctx.h.cmux.workspace_ids()), timeout=6.0, interval=0.05,
                   what="the mirror workspaces to end")
        elapsed = time.monotonic() - killed_at
        ctx.check(elapsed <= 2.0, f"the mirror workspaces end within 2 seconds ({elapsed:.2f}s)")
    except CheckFailed as error:
        ctx.check(False, f"the mirror workspaces end within 2 seconds ({error})")
    seen = {}
    sample_end = time.monotonic() + 4.0
    while time.monotonic() < sample_end:
        for child in child_pids(pid) - children_before if pid else set():
            seen.setdefault(child, time.monotonic() - killed_at)
        time.sleep(0.1)
    late = [p for p, t in seen.items() if t > 2.0]
    ctx.check(not late, f"no new child process is spawned after the first 2 seconds (spawn times {sorted(seen.values())})")
    # Q-B3: the message is a cmux notification. Compare by id, not by count, and require that a
    # new one is about this mirror (names a mirrored session, or tmux), so an unrelated
    # notification cannot pass the check. Round 2's count-only check passed and round 3's
    # failed, and the count alone cannot say why.
    def note_key(note):
        return str(note.get("id") or json.dumps(note, sort_keys=True))
    notes_after = ctx.h.cmux.result("notification.list").get("notifications") or []
    new_notes = [n for n in notes_after if note_key(n) not in notes_before_keys]
    ctx.log(f"notifications posted after kill-server: {json.dumps(new_notes)[:600]}")
    about_mirror = [n for n in new_notes
                    if any(s in json.dumps(n).lower() for s in ("t18a", "t18b", "tmux"))]
    ctx.check(bool(about_mirror), f"a message tells the user the mirror ended "
              f"({len(new_notes)} new notification(s), {len(about_mirror)} about this mirror)")
    server.new_session("t18c")
    mirror.attach()
    expect_shapes(ctx, mirror, {"t18c": [1]})


@test("T19", ["R20"], "The socket only accepts an absolute socket path the user owns", needs=["rpc"])
def t19_socket_boundary(ctx):
    server = ctx.server("s19")
    server.new_session("t19")
    good = local_host(server.socket_path)
    reply = ctx.h.cmux.call("remote.tmux.sessions", good)
    ctx.require(reply.get("ok") is True, "positive control: a valid local socket is accepted")

    def weird_server(name):
        other = ctx.server(name, socket_path=os.path.join(ctx.dir, name + ".sock"))
        other.new_session("w")
        return other.socket_path

    regular = os.path.join(ctx.dir, "regular")
    open(regular, "w").close()
    cases = [
        ("relative path", {"transport": "local", "socket_path": "s19.sock"}),
        ("control character", local_host(weird_server("ctl\x07char"))),
        ("hidden character", local_host(weird_server("zero​width"))),
        ("regular file", local_host(regular)),
        ("directory", local_host(ctx.dir)),
        ("host plus local", dict(good, host="localhost")),
        ("port", dict(good, port=22)),
        ("identity file", dict(good, identity_file=os.path.join(HOME, ".ssh", "id_ed25519"))),
        ("transport port", dict(good, transport_port=2022)),
        ("broker", dict(good, transport_broker="any-broker")),
        ("helper path", dict(good, transport_helper_path="/bin/sh")),
    ]
    foreign = "/var/run/mDNSResponder"
    try:
        info = os.stat(foreign)
        if stat.S_ISSOCK(info.st_mode) and info.st_uid != UID:
            cases.append(("another user's socket", local_host(foreign)))
    except OSError:
        ctx.log("no other-user socket available; that case is covered by the unit suite only")
    for label, params in cases:
        reply = ctx.h.cmux.call("remote.tmux.sessions", params)
        ctx.check(reply.get("ok") is not True and bool(error_message(reply)),
                  f"{label}: refused with a message ({error_message(reply)[:100]!r})")

    marker = os.path.join(ctx.dir, "evil-ran")
    evil = write_script(os.path.join(ctx.dir, "evil"), f"#!/bin/sh\ntouch '{marker}'\n")
    for key in ("tmux_path", "tmux", "executable", "command", "ssh_path", "shell"):
        ctx.h.cmux.call("remote.tmux.sessions", dict(good, **{key: evil}))
    ctx.check(not os.path.exists(marker), "no socket parameter makes the app run a program it names")


@test("T20", ["R1", "R5"], "With no server, the CLI starts one in the caller's directory and environment", needs=["cli"])
def t20_start_directory(ctx):
    app = ctx.h.app
    catalog = load_catalog(ctx)
    marker_dir = os.path.join(ctx.dir, "marker-bin")
    os.makedirs(marker_dir)
    marker_value = f"t20-{os.getpid()}"
    real_home = HOME

    def run_case(index, label, directory, prep="", expect_dir=None, expect_home=False, preexisting=False, env_check=False):
        tmpdir, sock = private_tmpdir(ctx, f"p{index}")
        server = Tmux(sock, ctx.h.tmux_bin)
        ctx.servers.append(server)
        if preexisting:
            server.new_session("pre")
        env = {
            "TMUX_TMPDIR": tmpdir,
            "PATH": f"{marker_dir}:{os.path.dirname(ctx.h.tmux_bin)}:/usr/bin:/bin:/usr/sbin:/sbin",
            "T20_MARKER": marker_value,
            "SHELL": "/bin/sh",
            "T20_DIR": directory,
            "T20_PREP": prep,
            "T20_CLI": app.cli_wrapper,
            "CMUX_TAG": ctx.h.tag,
        }
        script = 'cd -- "$T20_DIR" || exit 97; eval "$T20_PREP"; exec "$T20_CLI" tmux-mirror --no-focus'
        proc = subprocess.run(["/bin/sh", "-c", script], env=clean_environment(env),
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=60)
        output = (proc.stdout + proc.stderr).strip()
        ctx.check(proc.returncode == 0, f"{label}: the CLI exits 0 ({proc.returncode}: {output[:200]!r})")
        sessions = server.sessions()
        if preexisting:
            ctx.check(sessions == ["pre"], f"{label}: no new session is created ({sessions})")
            target = "pre"
        else:
            ctx.check(len(sessions) == 1, f"{label}: the CLI started a server with one session ({sessions})")
            target = sessions[0] if sessions else None
        if target:
            mirror = ctx.mirror(server)
            try:
                wait_until(lambda: mirror.is_mirrored(target), timeout=15.0, what=f"{target} mirrored")
                ctx.check(True, f"{label}: the session is mirrored")
            except CheckFailed as error:
                ctx.check(False, f"{label}: the session is mirrored ({error})")
            # Raw tmux formats, logged for diagnosis only (Q-A4): on macOS pane_current_path
            # is the physical path, and session_path read empty in integration round 1.
            for fmt in ("#{session_path}", "#{pane_start_path}", "#{pane_current_path}"):
                raw = server.run("display-message", "-p", "-t", f"={target}:0.0", fmt, check=False)
                ctx.log(f"{label}: tmux {fmt} -> exit {raw.returncode}, stdout {raw.stdout!r}, stderr {raw.stderr.strip()!r}")
            # The oracle is the first pane's own shell: its $PWD is what `pwd` shows the user,
            # and it keeps a symlinked path as typed. NUL-separated, because case 5 has quotes
            # and case 6's fallback must not be confused by the newline in the original path.
            out_file = os.path.join(ctx.dir, f"pane-{index}.txt")
            server.run("send-keys", "-t", f"={target}:0.0",
                       f"printf '%s\\0%s\\0%s\\0' \"$PWD\" \"$PATH\" \"$T20_MARKER\" > '{out_file}'", "Enter")
            try:
                wait_until(lambda: os.path.exists(out_file) and open(out_file, "rb").read().count(b"\0") >= 3,
                           timeout=10.0, what="the first pane's shell to report its directory and environment")
                pane_pwd, pane_path, pane_marker = open(out_file, "rb").read().decode("utf-8", "replace").split("\0")[:3]
            except CheckFailed as error:
                ctx.check(False, f"{label}: {error}")
                pane_pwd = pane_path = pane_marker = None
            if not preexisting and pane_pwd is not None:
                want = real_home if expect_home else expect_dir
                ctx.check(pane_pwd == want, f"{label}: the first pane opens in {want!r} (its shell's $PWD is {pane_pwd!r})")
                notice = [line for line in output.splitlines() if real_home in line]
                if expect_home:
                    ctx.check(len(notice) == 1, f"{label}: one line says the home directory was used ({output[:200]!r})")
                    if notice:
                        localized_check(ctx, catalog, notice[0], f"{label} notice")
            if env_check and pane_path is not None:
                ctx.check(marker_dir in pane_path.split(":"), f"{label}: the pane's PATH is the calling shell's ({pane_path[:120]})")
                ctx.check(pane_marker == marker_value, f"{label}: the pane inherits the calling shell's environment")
            mirror.detach_all(server.sessions())
        server.kill()

    normal = os.path.join(ctx.dir, "normal")
    os.makedirs(normal)
    run_case(1, "normal directory", normal, expect_dir=normal, env_check=True)

    real = os.path.join(ctx.dir, "real")
    link = os.path.join(ctx.dir, "link")
    os.makedirs(real)
    os.symlink(real, link)
    run_case(2, "symlinked directory", link, expect_dir=link)

    deleted = os.path.join(ctx.dir, "deleted")
    os.makedirs(deleted)
    run_case(3, "deleted directory", deleted, prep='rmdir -- "$PWD"', expect_home=True)

    locked = os.path.join(ctx.dir, "locked")
    os.makedirs(locked)
    ctx.on_cleanup(lambda: os.chmod(locked, 0o755))
    run_case(4, "mode 000 directory", locked, prep='chmod 000 -- "$PWD"', expect_home=True)

    odd = os.path.join(ctx.dir, "sp ace 'q\" \U0001F600 #{session_name}")
    os.makedirs(odd)
    run_case(5, "spaces, quotes, emoji and a literal #{...}", odd, expect_dir=odd)

    newline = os.path.join(ctx.dir, "nl\nx")
    os.makedirs(newline)
    run_case(6, "a newline in the path", newline, expect_home=True)

    run_case(7, "a server is already running", normal, preexisting=True)


# --------------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Live requirements tests T1-T20 for cmux tmux-mirror.")
    parser.add_argument("--artifacts", help="directory for logs and results (default: a temporary one)")
    parser.add_argument("--only", help="comma-separated test ids, e.g. T1,T3")
    parser.add_argument("--list", action="store_true", help="list the tests and exit")
    parser.add_argument("--leak-cycles", type=int, default=50, help="attach and detach cycles for T16 (R17 says 50)")
    args = parser.parse_args()
    cases = list(REGISTRY)
    if args.list:
        for case in cases:
            print(f"{case.test_id}\t{','.join(case.requirements)}\t{case.title}")
        return 0
    if args.only:
        wanted = {t.strip().upper() for t in args.only.split(",") if t.strip()}
        cases = [c for c in cases if c.test_id in wanted]
    harness = Harness("remote-tmux-local-conformance", "T1-T20")
    harness.setup(args)
    harness.leak_cycles = args.leak_cycles
    failure = None
    if harness.tmux_bin:
        failure = harness.prepare_app()
        if failure is None:
            try:
                harness.probe_features()
            except Exception as error:
                failure = f"feature probe failed: {error}"
    harness.run(cases, global_failure=failure)
    return harness.finish()


if __name__ == "__main__":
    sys.exit(main())
