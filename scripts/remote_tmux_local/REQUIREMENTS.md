# Requirements-to-test map: `cmux tmux-mirror` (local tmux transport, #38854)

Requirements R1 to R21 are the design's v1.0 requirements. Every test observes public surfaces only: CLI output and exit status, control-socket replies, mirrored workspaces, tabs and splits as the socket reports them (`remote.tmux.pane_grids`, `remote.tmux.pane_surfaces`, `workspace.list`), and tmux state on servers the harness starts itself on private `-S` sockets.

Where the tests live:

- **Live:** `scripts/remote-tmux-local-conformance.sh` (check.sh stage `live`), implemented in `scripts/remote_tmux_local/conformance.py`.
- **Bench:** `scripts/remote-tmux-local-bench.sh` (check.sh stage `bench`), implemented in `scripts/remote_tmux_local/bench.py`.
- **Unit:** `cmuxTests/RemoteTmuxLocalSocketBoundaryTests.swift` (check.sh stage `unit`).

| Req | Test | Where | What it checks |
|---|---|---|---|
| R1 | T1 | live | 2 sessions mirror as 2 workspaces; a 3-pane window mirrors as 3 splits; windows mirror as tabs; workspace titles name the sessions. |
| R1 | T20 | live | With no server, the CLI starts one session in the caller's directory (symlinked path kept; `#` kept literally), or in `$HOME` with one notice line for a deleted, mode-000 or newline path; no new session when a server already runs. |
| R2 | T2 | live | The CLI mirrors exactly the server `tmux ls` would show: `TMUX_TMPDIR` default, `--socket-name`, `--socket-path`, and from inside a pane of each server, with no control client on the others. |
| R3 | T3 | live | Split, rename and new tab made in cmux appear in tmux; split, rename and new window made by another tmux client appear in cmux. |
| R4 | T4 | live | With ssh replaced by a trap binary, the mirror works, the trap never runs, and nothing new appears under `~/.cmux/ssh`. |
| R5 | T5 | live | An app launched with `PATH=/usr/bin:/bin` mirrors a server whose tmux lives only in an install prefix. |
| R5 | T20 | live | The session the CLI creates has the calling shell's PATH entry and a marker variable. |
| R6 | T6 | live | Socket missing, no server running, not a socket, another user's socket, and tmux 3.1 each give a distinct message with no "ssh" in it; the CLI error is about local tmux. "tmux not installed" is not reproducible live (the resolver searches fixed prefixes); adversarial test A3 covers it. |
| R7 | T7 | live | Closing the mirror workspace, and separately its dedicated window, leaves the session in `tmux ls` and no cmux control client attached. |
| R8 | T8 | live | Dropping image data on a mirror pane inserts a path to a local file that exists. |
| R9 | T9 | live | With the multiplexer beta off and on, a session created after the attach behaves the same for the local mirror as for ssh-tmux (run through `scripts/remote-tmux-e2e-ssh-shim.sh`), and matches the stated expectations. |
| R10 | T10 | live | `cmux local-tmux start`, `list --json` and the `cmux tmux attach` alias work; mirroring the profile's socket path shows its session. |
| R11 | T11 | live | ssh-tmux through the ssh shim still mirrors the T1 shape, and its ControlPath is `~/.cmux/ssh/tmux-<slug>-<fnv1a64(destination,port,identity)>.sock` as on main. The existing remote-tmux unit suites in check.sh's `unit` stage are the rest of this gate. |
| R12 | T12 | live | The same session mirrored locally and through `ssh localhost` at once; a split made in each mirror appears in the other. Skipped with a reason when loopback ssh is unavailable or a default server already exists. |
| R13 | T13 | live | Script run: no focus change. Interactive run (pty): focuses. `--no-focus` interactive: no change. `--focus` from a script: focuses. |
| R14 | T6 | live | Every failure message, the fallback notice (T20) and every `--help` line is a catalog string translated into every language the catalog ships (reference: the languages of `cli.sshTmux.list.empty`); the help names `cmux local-tmux`. |
| R15 | T14 | bench | 10 sessions x 5 windows: median of 5 runs from the mirror request until every session shows all windows, at most 1000 ms. |
| R16 | T15 | bench | 200 keystrokes, echo timestamped by a separate `tmux -C` client: mirror p95 minus plain-client p95 at most 5 ms. |
| R17 | T16 | live | 50 attach and detach cycles: descriptor and child counts back at the baseline; no control client left. (Track C's leak stage repeats this at scale.) |
| R18 | T17 | live | `kill -9` of the app: no control client 2 seconds later; every session still running. |
| R19 | T18 | live | `kill-server`: mirror workspaces end within 2 seconds, no child is spawned after that, a notification is posted, and re-running after a restart works. |
| R20 | T19 | live + unit | Relative path, control or hidden characters, regular file, directory, missing path, another user's socket, `host`, `port`, `identity_file`, `transport_port`, broker and helper parameters are each refused, after a positive control is accepted; no parameter can name a program the app runs. |
| R21 | T2 | live | The app relaunched with `TMUX`, `TMUX_PANE` and `TMUX_TMPDIR` naming decoy servers still mirrors only the server the CLI resolved. |

## Results

Each test reports PASS, FAIL, NOT-IMPLEMENTED or SKIP. NOT-IMPLEMENTED means the build lacks the feature the test needs: the socket refuses `transport: "local"`, or `cmux tmux-mirror` is not a command. It counts as a failure, so check.sh cannot pass on a build without the feature. On main at `0b458fe`, T11 (and the local-tmux half of T10, and the ssh half of T9) run for real, because they exercise existing behavior; every other test reports NOT-IMPLEMENTED.

## Names taken from DESIGN.md before the implementation published them

- CLI: `cmux tmux-mirror [--socket-name <n> | --socket-path <p>] [--new-window] [--name <title>] [--focus | --no-focus]` (D9).
- Socket: `transport: "local"` with `socket_path` on the existing `remote.tmux.*` methods (D8).
- The fallback notice contains the home directory's path (D7 step 3).
