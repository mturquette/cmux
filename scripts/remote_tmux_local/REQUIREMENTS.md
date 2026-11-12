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
| R15 (v1.1) | T14 | bench | Opening a local mirror is no slower than ssh-tmux on the same server. See "How T14 decides 'no slower'" below. |
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

## How T14 decides "no slower" (R15 v1.1, owner decision 2026-11-11)

T14 builds one tmux server with 10 sessions of 5 windows. It times each attach from the mirror request until every session shows all 5 windows, then detaches and waits until no control client is left.

- **Same conditions for both.** One app process, launched with the ssh shim (`scripts/remote-tmux-e2e-ssh-shim.sh`), mirrors the same server both ways: through ssh-tmux, and locally through the server's socket path. ssh-tmux through the shim pays no network or login cost, so the comparison measures the transports, not the network.
- **Warm-up, then pairs.** One uncounted warm-up attach of each transport, then 7 pairs (`--pairs`). Each pair times one local and one ssh-tmux attach back to back, and the pairs alternate which goes first.
- **The rule.** For each pair, T14 takes the ratio of the local time to the ssh-tmux time. It passes when the median of the 7 ratios is at most 1.10 (`--attach-tolerance-pct 10`): in the typical pair, local is at most 10% slower.
- **Why this comparison.** Attach times drift a lot in the VM: one run of ssh-tmux alone fell steadily from 4.8 s to 2.5 s over 7 attaches. Comparing the medians of two separate series would let that drift decide the result. Comparing the two runs inside each pair cancels it, because they run seconds apart. The median ignores up to 3 outlier pairs, and the 10% margin absorbs the noise that is left without hiding a consistent slowdown.
- **Reported every run:** every time, both medians, every pair's ratio, the median ratio and its limit, in how many pairs local was no slower, the warm-up times, and the former 1000 ms limit for comparison. The app's debug log for each transport's warm-up attach is saved as `t14-local-debug.log` and `t14-ssh-debug.log`.

Measurements so far: round 3 (run `20261111-135311-integration-44135652`, an earlier sequential method) gave medians of 3147 ms for local and 3978 ms for ssh-tmux. On main, ssh-tmux alone gave a median of 3437 ms (run `20261111-144032-b-harness-844a49e7`).
