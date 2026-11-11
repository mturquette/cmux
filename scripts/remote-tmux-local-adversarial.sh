#!/bin/bash
# ============================================================================
# Adversarial suite for the local tmux mirror (`cmux tmux-mirror`, issue
# #38854). DESIGN.md section 5, attacks A1 to A14. Each attack is meant to
# break the implementation; a check passes only when the behavior DESIGN.md
# expects is observed through a public surface (the CLI, the socket API, or
# tmux state on a private server this script started).
#
# Usage: CMUX_TAG=<tag> scripts/remote-tmux-local-adversarial.sh
#          [--only A1,A5,...] [--artifacts DIR] [--list]
# Exit status: the number of failed checks (0 = all green). A skipped check
# prints its reason and is never counted as a pass.
#
# Environment: TMUX_BIN (tmux for private servers, default 3.6a in the VM),
# TMUX_OLD_BIN (tmux 3.2a, for A4). Runs only in the test VM, through
# check.sh's "adversarial" stage, against a running tagged Debug app.
#
# The A12 parser fuzz is a Swift suite (cmuxTests/RemoteTmuxLocalParserFuzzTests)
# and runs in check.sh's unit and adversarial stages, not here. This script
# also carries P1, a probe of tmux itself that needs no cmux at all: it shows
# whether tmux writes a `%subscription-changed` value raw, so that a directory
# name containing a newline can inject control-mode lines (see A9).
#
# A15 to A21 are not in DESIGN.md. They came from an adversarial review of
# track A's diff (tl/a-transport), aimed at paths A1 to A14 do not reach:
#   A15 a frozen (SIGSTOPped) server: the CLI's probe and the app's attach
#       must both end within a bound
#   A16 the socket path is taken over by another user's server after the
#       attach, then the app reconnects: the boundary check ran only once
#   A17 no pty available (openpty fails): clear error, no leaked descriptor
#   A18 30 server-side detaches: the reconnect path allocates a pty each time
#   A19 the control client is stopped (SIGSTOP), then detached or continued
#   A20 a relative, long or deleted-cwd socket location from the CLI
#   A21 a wrapper tmux whose child holds stderr open after tmux exits
#
# MANUAL CASES (need a tagged build and a person at the VM's screen; results
# go to results/ as a run log):
#
#   A10b, kill -9 while attached (R18):
#     1. In the VM: ./scripts/reload.sh --tag adv-manual --launch
#     2. tmux -S /tmp/advm/s -f /dev/null new-session -d -s main   (mkdir -p /tmp/advm first)
#     3. CMUX_TAG=adv-manual scripts/cmux-debug-cli.sh tmux-mirror --socket-path /tmp/advm/s
#     4. tmux -S /tmp/advm/s list-clients -F '#{client_pid} #{client_control_mode}'
#        shows one client with control mode 1. Note its pid.
#     5. kill -9 $(pgrep -f 'cmux DEV adv-manual.app/Contents/MacOS/')
#     6. Wait 2 seconds, then repeat step 4: expect no control client, and
#        `ps -p <client pid>` shows nothing. `tmux -S /tmp/advm/s ls` still lists main.
#   A10c, relaunch after kill -9:
#     7. open -g "<DerivedData>/cmux-adv-manual/Build/Products/Debug/cmux DEV adv-manual.app"
#     8. Repeat step 3: expect one mirror workspace for main and exactly one
#        control client in step 4's listing; no stale mirror workspace from
#        before the crash (mirror workspaces are not restored, D11).
#   A7b, cmux and iTerm2's tmux integration on one server:
#     9. With the mirror from step 8 attached, attach iTerm2 with
#        `tmux -S /tmp/advm/s -CC attach`. Split a pane in iTerm2, then in cmux.
#        Expect both windows to show both splits, and typing to work in both.
#     10. tmux -S /tmp/advm/s kill-server; rm -rf /tmp/advm
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
source scripts/remote-tmux-local-adversarial-lib.sh

ALL_IDS="P1 A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A13 A14 A15 A16 A17 A18 A19 A20 A21"
ONLY=""
ARTIFACTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
    --artifacts) ARTIFACTS="$2"; shift 2 ;;
    --list) echo "$ALL_IDS"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ARTIFACTS" ] || ARTIFACTS="$ADV_TMP_ROOT/artifacts"
mkdir -p "$ARTIFACTS"
trap 'adv_cleanup; [ -n "${RELAUNCHED:-}" ] && relaunch_app >/dev/null 2>&1' EXIT

# A probe whose client exits early must not take the whole suite down with
# SIGPIPE on the next write to its input; the write fails and the check says so.
trap '' PIPE

FAKES="$ADV_TMP_ROOT/fakes"
mkdir -p "$FAKES"
REAL_TMUX="$TMUX_BIN"

selected() {
  [ -z "$ONLY" ] && return 0
  local id; for id in $ONLY; do [ "$id" = "$1" ] && return 0; done
  return 1
}

# Every live attack needs the feature. Without it each one fails with the
# same plain reason, so a build without the transport is red, not green.
require_feature() {
  if [ "$FEATURE" != 1 ]; then
    fail "this build has no 'cmux tmux-mirror' command; the attack cannot run"
    return 1
  fi
  if ! app_alive; then
    fail "the tagged app is not running (it may have crashed in an earlier attack)"
    return 1
  fi
  return 0
}

# Writes a fake tmux into $FAKES/<name>/tmux from the body on stdin.
make_fake() {
  mkdir -p "$FAKES/$1"
  { echo '#!/bin/sh'; cat; } > "$FAKES/$1/tmux"
  chmod 755 "$FAKES/$1/tmux"
  printf '%s\n' "$FAKES/$1"
}

# Common "after an attack" checks: the app is alive, answers its socket, and a
# fresh mirror of a fresh server still works.
assert_app_healthy() {
  app_alive || { fail "the app crashed"; return 1; }
  app_responds || { fail "the app stopped answering its socket"; return 1; }
  local sock; sock="$(new_server "health$RANDOM")"
  run_bounded 30 mirror_rpc "$sock"
  if [ "$RB_STATUS" -eq 0 ] && wait_until 10 has_control_client "$sock"; then
    pass "a new mirror still attaches afterwards"
    local ids; ids="$(workspace_ids_from "$RB_OUT")"
    # shellcheck disable=SC2086
    detach_mirror_workspaces "$sock" $ids
  else
    fail "a new mirror no longer attaches afterwards: $RB_OUT"
  fi
}

# ---- P1: tmux writes subscription values raw ----------------------------------
# No cmux involved. Attaches a control client with `tmux -C` (plain control
# mode, which works on a pipe; -CC needs a tty, and script(1) exited at once
# in the VM's job runner), subscribes to pane_current_path the way cmux does,
# cds the pane into a directory whose name holds a newline and a fake
# notification, and checks the raw stream. tmux writes subscription lines the
# same way in -C and -CC.
attack_P1() {
  local sock; sock="$(new_server p1)"
  local evil="$ADV_TMP_ROOT/p1/x"$'\n'"%cmux-adv-injected"
  mkdir -p "$evil" || { skip "the file system refused a directory name with a newline"; return; }
  local fifo="$ADV_TMP_ROOT/p1/in" raw="$ARTIFACTS/P1-raw-control-stream.bin" err="$ARTIFACTS/P1-client-stderr.txt"
  mkfifo "$fifo"
  ( "$TMUX_BIN" -S "$sock" -C attach -t main < "$fifo" > "$raw" 2> "$err"; echo "client exit $?" >> "$err" ) &
  local spid=$!
  exec 7> "$fifo"
  printf 'refresh-client -B "cwd:%%0:#{pane_current_path}"\n' >&7
  sleep 1
  t "$sock" send-keys -t main "cd '$ADV_TMP_ROOT/p1/x'\$'\\n''%cmux-adv-injected'" Enter
  sleep 3
  printf 'detach-client\n' >&7
  exec 7>&-
  wait_until 5 bash -c "! kill -0 $spid 2>/dev/null"; kill "$spid" 2>/dev/null
  t "$sock" display-message -p -t main '#{pane_current_path}' > "$ARTIFACTS/P1-pane-path.txt" 2>&1
  grep -a -n -A1 'subscription-changed' "$raw" > "$ARTIFACTS/P1-subscription-lines.txt" 2>/dev/null
  if [ ! -s "$raw" ]; then
    fail "the control client captured nothing; its stderr: $(tr '\n' ' ' < "$err")"
  elif tr -d '\r' < "$raw" | grep -aq '^%cmux-adv-injected$'; then
    info "FINDING: tmux $("$TMUX_BIN" -V) wrote a %subscription-changed value raw; the line '%cmux-adv-injected' arrived as its own control-mode line. A pane that cds into such a directory can inject %exit, %begin or %layout-change into any mirror (ssh, et or local). Raw stream: $raw"
    pass "probe completed (tmux behavior recorded)"
  else
    info "tmux escaped the newline in the subscription value; no line injection possible"
    pass "probe completed (tmux behavior recorded)"
  fi
}

# ---- A1: server killed mid-session; %exit while commands are in flight --------
attack_A1() {
  require_feature || return
  local sock; sock="$(new_server a1)"
  t "$sock" new-session -d -s second
  run_bounded 30 mirror_rpc "$sock"
  [ "$RB_STATUS" -eq 0 ] || { fail "mirror did not attach: $RB_OUT"; return; }
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "no control client appeared"; return; }
  # Load the stream with commands: churn layouts from tmux's side so the app
  # has rects and capture requests in flight when the server dies.
  local k; for k in 1 2 3 4 5 6; do t "$sock" split-window -t main >/dev/null 2>&1; t "$sock" select-layout -t main tiled >/dev/null 2>&1; done
  t "$sock" kill-server
  local start; start="$(date +%s)"
  local all_gone=1 w
  for w in $ids; do wait_until 3 workspace_gone "$w" || all_gone=0; done
  [ "$all_gone" = 1 ] && pass "mirror workspaces ended within about 2 s of the server dying ($(( $(date +%s) - start )) s)" \
    || fail "mirror workspaces still exist 3 s after kill-server (R19)"
  # No respawn loop: from 2 s to 8 s after the death, the app should have no
  # tmux or script child at any sample (the first 2 s are teardown).
  local pid max=0 n i=0
  pid="$(app_pid)"
  while [ "$i" -lt 40 ]; do
    if [ "$i" -ge 10 ]; then n="$(tmux_descendant_count "$pid")"; [ "$n" -gt "$max" ] && max="$n"; fi
    sleep 0.2; i=$((i + 1))
  done
  [ "$max" -eq 0 ] && pass "no tmux process was running 2 to 8 s after the server died" \
    || fail "the app kept $max tmux or script children alive after the server died (respawn loop?)"
  # Re-running after a restart works (R19).
  "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s main
  run_bounded 30 mirror_rpc "$sock"
  if [ "$RB_STATUS" -eq 0 ] && wait_until 10 has_control_client "$sock"; then
    pass "re-running after the server restarted attaches again"
    # shellcheck disable=SC2086
    detach_mirror_workspaces "$sock" $(workspace_ids_from "$RB_OUT")
  else
    fail "re-running after a restart failed: $RB_OUT"
  fi

  # %exit while commands are in flight: detach cmux's control client from
  # outside (tmux sends %exit to it) during heavy churn.
  run_bounded 30 mirror_rpc "$sock"
  ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "second attach did not happen"; return; }
  ( for k in $(seq 1 40); do t "$sock" new-window -t main >/dev/null 2>&1; t "$sock" kill-window -t main >/dev/null 2>&1; done ) &
  local churn=$!
  sleep 0.3
  local c; for c in $(t "$sock" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2}'); do
    t "$sock" detach-client -t "$c"
  done
  wait "$churn"
  app_responds && pass "the app answers after %exit arrived with commands in flight" \
    || fail "the app stopped answering after %exit with commands in flight"
  run_bounded 12 state_json "$sock" main
  [ "$RB_STATUS" -ne 124 ] && pass "remote.tmux.state answers (every pending command resolved)" \
    || fail "remote.tmux.state hung after %exit (a pending command never resolved?)"
  local spawns_before; spawns_before="$(tmux_descendant_count "$(app_pid)")"
  sleep 5
  local cc; cc="$(control_clients "$sock")"
  [ "$cc" -le 1 ] && pass "no reconnect storm after an outside detach ($cc control clients)" \
    || fail "$cc control clients after an outside detach (reconnect loop)"
  info "tmux or script children 5 s after the detach: $spawns_before then $(tmux_descendant_count "$(app_pid)")"
  # shellcheck disable=SC2086
  for w in $ids; do close_workspace "$w"; done
  assert_app_healthy
}

# ---- A2: socket deleted or made unreachable, before and during a mirror -------
attack_A2() {
  require_feature || return
  local sock dir out
  # Before attach: socket missing.
  sock="$(new_server a2a)"; dir="$(dirname "$sock")"
  t "$sock" kill-server
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  [ "$RB_STATUS" -ne 0 ] && [ "$RB_STATUS" -ne 124 ] && pass "missing socket: refused in ${RB_ELAPSED}s" \
    || fail "missing socket: status $RB_STATUS (124 means it hung): $out"
  mentions_ssh "$out" && fail "missing socket message talks about ssh: $out" || pass "missing socket message has no ssh wording"
  printf 'missing: %s\n' "$out" > "$ARTIFACTS/A2-messages.txt"

  # Before attach: socket chmod 000.
  sock="$(new_server a2b)"; dir="$(dirname "$sock")"
  chmod 000 "$sock"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  [ "$RB_STATUS" -ne 124 ] && pass "socket mode 000: no hang (status $RB_STATUS)" || fail "socket mode 000: hung"
  [ "$RB_STATUS" -ne 0 ] && pass "socket mode 000: refused" || fail "socket mode 000: reported success"
  mentions_ssh "$out" && fail "mode-000 message talks about ssh: $out" || true
  printf 'sock000: %s\n' "$out" >> "$ARTIFACTS/A2-messages.txt"
  chmod 700 "$sock"

  # Before attach: socket directory chmod 000.
  chmod 000 "$dir"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  chmod 700 "$dir"
  [ "$RB_STATUS" -ne 124 ] && [ "$RB_STATUS" -ne 0 ] && pass "socket directory mode 000: refused without a hang" \
    || fail "socket directory mode 000: status $RB_STATUS: $out"
  printf 'dir000: %s\n' "$out" >> "$ARTIFACTS/A2-messages.txt"

  # While mirrored: delete the socket. The attached client keeps its
  # connection; nothing may hang, and a re-run gets a clear message.
  sock="$(new_server a2c)"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  local spid; spid="$(t "$sock" display-message -p '#{pid}' 2>/dev/null)"
  rm -f "$sock"
  t "$sock" new-window >/dev/null 2>&1   # fails: no socket; the server is unaffected
  run_bounded 12 rpc remote.tmux.state "$(local_params "$sock" main)"
  [ "$RB_STATUS" -ne 124 ] && pass "state query answers after the socket was deleted" || fail "state query hung after the socket was deleted"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  [ "$RB_STATUS" -ne 124 ] && pass "re-run with a deleted socket does not hang" || fail "re-run with a deleted socket hung"
  # tmux recreates its socket on SIGUSR1; the mirror must then work again.
  if [ -n "$spid" ]; then
    kill -USR1 "$spid"; wait_until 5 test -S "$sock"
    run_bounded 12 rpc remote.tmux.state "$(local_params "$sock" main)"
    [ "$RB_STATUS" -eq 0 ] && pass "after tmux recreated its socket, the mirror still answers" || fail "state after socket recreation: $RB_OUT"
  else
    info "could not find the tmux server pid to recreate its socket"
  fi
  # While mirrored: chmod 000 the socket directory.
  chmod 000 "$(dirname "$sock")"
  run_bounded 12 rpc remote.tmux.state "$(local_params "$sock" main)"
  chmod 700 "$(dirname "$sock")"
  [ "$RB_STATUS" -ne 124 ] && pass "state query answers while the socket directory is unreadable" || fail "state query hung while the socket directory was unreadable"
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$sock" $ids
  assert_app_healthy
}

# ---- A3: no tmux, garbage tmux, hanging tmux, wrong PATH ----------------------
attack_A3() {
  require_feature || return
  local sock; sock="$(new_server a3)"
  local garbage hang missing old
  garbage="$(make_fake garbage <<'EOF'
head -c 4096 /dev/urandom
printf '\n%%begin 1 2 3\nnot tmux at all\n'
exit 0
EOF
)"
  hang="$(make_fake hang <<EOF
echo \$\$ >> "$FAKES/hang.pids"
exec sleep 100000
EOF
)"
  missing="$FAKES/missing"; mkdir -p "$missing"
  local msgs="$ARTIFACTS/A3-messages.txt"; : > "$msgs"

  # Each case runs the CLI with the fake first on PATH. The CLI probes the
  # server itself before asking the app (D7), so these messages come from it.
  run_bounded 30 env PATH="$garbage:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
  local garbage_out="$RB_OUT" garbage_status="$RB_STATUS"
  printf 'garbage(%s): %s\n' "$garbage_status" "$garbage_out" >> "$msgs"
  [ "$garbage_status" -ne 0 ] && [ "$garbage_status" -ne 124 ] && pass "garbage tmux: refused" || fail "garbage tmux: status $garbage_status"
  mentions_ssh "$garbage_out" && fail "garbage tmux message talks about ssh" || true

  : > "$FAKES/hang.pids"
  run_bounded 90 env PATH="$hang:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
  local hang_out="$RB_OUT" hang_status="$RB_STATUS"
  printf 'hang(%s after %ss): %s\n' "$hang_status" "$RB_ELAPSED" "$hang_out" >> "$msgs"
  [ "$hang_status" -ne 124 ] && pass "hanging tmux: bounded, ended after ${RB_ELAPSED}s" \
    || fail "hanging tmux: the CLI was still waiting after 90 s"
  local p left=0
  for p in $(cat "$FAKES/hang.pids"); do kill -0 "$p" 2>/dev/null && left=$((left + 1)); kill -KILL "$p" 2>/dev/null; done
  [ "$left" -eq 0 ] && pass "hanging tmux: its process was killed" || fail "hanging tmux: $left hung processes left running"

  # No tmux anywhere: only meaningful when the resolver's fallback
  # directories hold no tmux either, which the VM's Homebrew tmux prevents.
  local fallback=""
  for p in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /usr/bin /bin; do
    [ -x "$p/tmux" ] && fallback="$p/tmux"
  done
  if [ -n "$fallback" ]; then
    skip "no-tmux case: the resolver's fallback finds $fallback, so 'not installed' cannot be produced here (covered by T6's fake in unit tests)"
  else
    run_bounded 30 env PATH="$missing:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
    printf 'missing(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$msgs"
    [ "$RB_STATUS" -ne 0 ] && pass "no tmux: refused" || fail "no tmux: reported success"
    [ "$RB_OUT" != "$garbage_out" ] && pass "no-tmux and garbage messages differ" || fail "no-tmux and garbage share one message"
  fi
  [ "$garbage_out" != "$hang_out" ] && pass "garbage and hang messages differ" || fail "garbage and hang share one message"

  # Wrong PATH: tmux only outside PATH, in a Homebrew-like prefix. The
  # resolver must still find it (R5); this succeeds when Homebrew tmux exists.
  run_bounded 30 env PATH="/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
  printf 'minimal-path(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$msgs"
  if [ -n "$fallback" ]; then
    [ "$RB_STATUS" -eq 0 ] && pass "PATH=/usr/bin:/bin still finds tmux at $fallback" || fail "PATH=/usr/bin:/bin: $RB_OUT"
  fi
  t "$sock" kill-server 2>/dev/null
  assert_app_healthy
}

# ---- A4: tmux 3.2a (oldest supported) and a fake 3.1 --------------------------
attack_A4() {
  require_feature || return
  if [ -x "$TMUX_OLD_BIN" ]; then
    local sock; sock="$(new_server a4old "$TMUX_OLD_BIN")"
    run_bounded 30 env PATH="$(dirname "$TMUX_OLD_BIN"):/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
    # A 3.6a client cannot talk to a 3.2a server, so the tmux-side checks use
    # the old binary for this server.
    if [ "$RB_STATUS" -eq 0 ] && TMUX_BIN="$TMUX_OLD_BIN" wait_until 10 has_control_client "$sock"; then
      pass "$("$TMUX_OLD_BIN" -V) server mirrors"
      "$TMUX_OLD_BIN" -S "$sock" new-window -t main
      wait_until 5 window_count_is "$sock" 2 \
        && pass "a window added on the 3.2a server reaches the mirror" \
        || fail "a window added on the 3.2a server did not reach the mirror"
    else
      fail "$("$TMUX_OLD_BIN" -V) (the supported minimum) did not mirror: $RB_OUT"
    fi
    "$TMUX_OLD_BIN" -S "$sock" kill-server 2>/dev/null
  else
    skip "TMUX_OLD_BIN ($TMUX_OLD_BIN) is not installed"
  fi
  # A fake that reports 3.1 for -V and for the server's #{version}.
  local fake31; fake31="$(make_fake v31 <<EOF
for a in "\$@"; do
  case "\$a" in
    -V) echo "tmux 3.1"; exit 0 ;;
    *'#{version}'*) case " \$* " in *" refresh-client "*) echo "unknown flag -B" >&2; exit 1 ;; esac; echo "3.1"; exit 0 ;;
  esac
done
exec "$REAL_TMUX" "\$@"
EOF
)"
  local sock31; sock31="$(new_server a4fake)"
  run_bounded 30 env PATH="$fake31:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock31" --no-focus
  printf 'fake31(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A4-messages.txt"
  # The CLI may delegate the version gate to the app, which resolves tmux
  # from its own PATH. Relaunch the app with the fake first if the CLI did not
  # refuse, so the app-side gate is exercised too.
  if [ "$RB_STATUS" -eq 0 ]; then
    info "the CLI did not gate the version itself; checking the app's gate with the fake on the app's PATH"
    t "$sock31" kill-server; sock31="$(new_server a4fake2)"
    RELAUNCHED=1
    relaunch_app "PATH=$fake31:/usr/bin:/bin" || { fail "could not relaunch the app with the fake PATH"; return; }
    run_bounded 30 mirror_rpc "$sock31"
    printf 'fake31-app(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
    relaunch_app; RELAUNCHED=""
  fi
  case "$RB_OUT" in
    *3.1*) pass "tmux 3.1 is refused and the message names the detected version" ;;
    *) fail "tmux 3.1 was not refused with its version: $RB_OUT" ;;
  esac
  mentions_ssh "$RB_OUT" && fail "the version message talks about ssh" || true
  no_control_clients "$sock31" && pass "no control client attached to the 3.1 server" || fail "a control client attached to a 3.1 server"
}

# ---- A5: 50 MB burst, binary output, flow control ------------------------------
attack_A5() {
  require_feature || return
  local sock; sock="$(new_server a5)"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  local pid; pid="$(app_pid)"
  local rss0 peak
  rss0="$(rss_kb "$pid")"
  peak="$rss0"
  t "$sock" send-keys -t main "head -c 52428800 /dev/urandom; printf '\\nA5-BINARY-DONE\\n'" Enter
  local i=0 r
  while [ "$i" -lt 600 ]; do
    r="$(rss_kb "$pid")"; [ -n "$r" ] && [ "$r" -gt "$peak" ] && peak="$r"
    t "$sock" capture-pane -p -t main | grep -q A5-BINARY-DONE && break
    sleep 0.2; i=$((i + 1))
  done
  app_alive || { fail "the app crashed during a 50 MB binary burst"; return; }
  local growth_mb=$(( (peak - rss0) / 1024 ))
  [ "$growth_mb" -le "${A5_RSS_LIMIT_MB:-1024}" ] && pass "memory grew by $growth_mb MB at peak during the burst" \
    || fail "memory grew by $growth_mb MB during the burst (limit ${A5_RSS_LIMIT_MB:-1024})"
  t "$sock" send-keys -t main "clear; printf 'A5-AFTER-%s\\n' ok" Enter
  local before; before="$(state_field "$sock" total_output_bytes)"
  t "$sock" send-keys -t main "echo still-in-sync" Enter
  wait_until 20 output_changed "$sock" total_output_bytes "$before"
  mirror_attached "$sock" && pass "the mirror is still attached after the burst" || fail "the mirror ended after the burst"
  t "$sock" new-window -t main
  wait_until 10 window_count_is "$sock" 2 && pass "the stream is still in sync (a new window arrived)" \
    || fail "the stream lost sync after the burst (new window not seen)"

  # Flow control: set pause-after on cmux's own client from outside. tmux then
  # sends %extended-output and %pause; a mirror that ignores them freezes.
  local c; c="$(t "$sock" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2; exit}')"
  if t "$sock" refresh-client -t "$c" -f pause-after=1 2>"$ARTIFACTS/A5-pause.err"; then
    t "$sock" send-keys -t main "yes A5-FLOW | head -c 20000000; echo A5-FLOW-END" Enter
    sleep 5
    before="$(state_field "$sock" pane_output_bytes)"
    t "$sock" send-keys -t main "echo A5-FLOW-MARK" Enter
    sleep 3
    local after; after="$(state_field "$sock" pane_output_bytes)"
    [ "$before" != "$after" ] && pass "output still reaches the mirror with pause-after set" \
      || fail "with pause-after set on cmux's client, pane output stopped reaching the mirror (no %pause/%continue handling)"
    t "$sock" refresh-client -t "$c" -f '!pause-after' >/dev/null 2>&1
  else
    skip "this tmux refused refresh-client -t <client> -f pause-after: $(cat "$ARTIFACTS/A5-pause.err")"
  fi
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$sock" $ids
  assert_app_healthy
}

# ---- A6: 200 rapid and racing attach and detach cycles ------------------------
attack_A6() {
  require_feature || return
  bash scripts/remote-tmux-local-leak-check.sh --cycles 200 --race 200 --artifacts "$ARTIFACTS/A6" > "$ARTIFACTS/A6.log" 2>&1
  local status=$?
  sed 's/^/    | /' "$ARTIFACTS/A6.log" | tail -15
  [ "$status" -eq 0 ] && pass "200 sequential and 200 racing cycles left no leak" \
    || fail "$status leak checks failed after 200 plus 200 cycles (see A6.log)"
}

# ---- A7: two mirror calls for one server at once ------------------------------
attack_A7() {
  require_feature || return
  local sock; sock="$(new_server a7)"
  local o1="$ADV_TMP_ROOT/a7.1" o2="$ADV_TMP_ROOT/a7.2"
  ( mirror_rpc "$sock" > "$o1" 2>&1 ) & local p1=$!
  ( mirror_rpc "$sock" > "$o2" 2>&1 ) & local p2=$!
  wait "$p1"; local s1=$?; wait "$p2"; local s2=$?
  [ "$s1" -eq 0 ] && [ "$s2" -eq 0 ] && pass "both racing calls returned success" \
    || fail "racing calls: statuses $s1 and $s2: $(cat "$o1") / $(cat "$o2")"
  sleep 2
  local n; n="$(control_clients_on "$sock" main)"
  [ "$n" -eq 1 ] && pass "exactly one control client for the server key" || fail "$n control clients for one session (expected 1)"
  # A second, foreign control client (a stand-in for iTerm2's -CC) on the
  # same session: both must stay usable.
  local fifo="$ADV_TMP_ROOT/a7.fifo"; mkfifo "$fifo"
  ( "$TMUX_BIN" -S "$sock" -C attach -t main < "$fifo" > /dev/null 2>&1 ) &
  local fpid=$!
  exec 8> "$fifo"
  printf 'split-window -t main\n' >&8
  sleep 1
  t "$sock" new-window -t main
  wait_until 10 window_count_is "$sock" 2 && pass "the mirror stays live with a foreign control client attached" \
    || fail "the mirror stopped following tmux with a foreign control client attached"
  printf 'detach-client\n' >&8; exec 8>&-
  wait_until 5 bash -c "! kill -0 $fpid 2>/dev/null"; kill "$fpid" 2>/dev/null
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$sock" $(workspace_ids_from "$(cat "$o1")") $(workspace_ids_from "$(cat "$o2")")
}

# ---- A8: rename or kill the mirrored session from outside ---------------------
attack_A8() {
  require_feature || return
  local sock; sock="$(new_server a8)"
  t "$sock" new-session -d -s other
  t "$sock" set-option -g detach-on-destroy off
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  local before_other; before_other="$(control_clients_on "$sock" other)"
  t "$sock" rename-session -t main renamed-α
  wait_until 5 tree_contains "renamed-α" \
    && pass "the workspace title follows an outside rename" || fail "the workspace title did not follow the rename"
  t "$sock" kill-session -t renamed-α
  sleep 2
  local after_other; after_other="$(control_clients_on "$sock" other)"
  [ "$after_other" -le "$before_other" ] && pass "with detach-on-destroy off, no cmux client was moved onto 'other' ($before_other -> $after_other)" \
    || fail "with detach-on-destroy off, a cmux client was moved silently onto 'other' ($before_other -> $after_other)"
  local w gone=0 left=0
  for w in $ids; do workspace_exists "$w" && left=$((left + 1)) || gone=$((gone + 1)); done
  info "workspaces after the kill: $gone gone, $left remaining (the one for 'other' should remain)"
  [ "$gone" -ge 1 ] && pass "the killed session's workspace ended" || fail "no workspace ended after its session was killed"
  # shellcheck disable=SC2086
  for w in $ids; do close_workspace "$w"; done
}

# ---- A9: Unicode and escape torture --------------------------------------------
attack_A9() {
  require_feature || return
  local sock; sock="$(new_server a9)"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  local names=(
    "emoji 🧪🦀👩‍👩‍👧"
    "combining e"$'\xcc\x81'"e"$'\xcc\x81'
    "rtl שלום مرحبا"
    "esc "$'\x1b'"[31mred"$'\x1b'"[0m"
    "pct %exit %begin 1 2 3 %%"
    "osc "$'\x1b'"]0;title"$'\x07'
    "nl a"$'\n'"%exit"
  )
  local n wc=1
  for n in "${names[@]}"; do
    t "$sock" rename-window -t main "$n" 2>/dev/null
    t "$sock" new-window -t main -n "$n" 2>/dev/null && wc=$((wc + 1))
  done
  sleep 2
  mirror_attached "$sock" && pass "the mirror survived hostile window names" || fail "the mirror ended after hostile window names"
  wait_until 10 window_count_is "$sock" "$wc" && pass "window count still matches tmux ($wc)" \
    || fail "window count $(mirror_window_count "$sock") does not match tmux ($wc): parser lost sync"
  t "$sock" rename-window -t main "rt-🧪-שלום"
  wait_until 5 tree_contains "rt-🧪-שלום" \
    && pass "a Unicode window name round-trips to the tab title" || fail "a Unicode window name did not round-trip"

  # Every C0 control and broken UTF-8 in pane output.
  t "$sock" send-keys -t main "printf '\\000\\001\\002\\003\\004\\005\\006\\007\\010\\011\\013\\014\\016\\017\\020\\021\\022\\023\\024\\025\\026\\027\\030\\031\\032\\033\\034\\035\\036\\037\\177 \\303 \\200\\201 \\355\\240\\200 \\360\\237 \\377\\376 %%end 1 1 0\\n%%exit\\n'" Enter
  sleep 2
  t "$sock" new-window -t main; wc=$((wc + 1))
  wait_until 10 window_count_is "$sock" "$wc" && pass "the stream is in sync after C0 and broken UTF-8 output" \
    || fail "the stream lost sync after C0 and broken UTF-8 output"

  # Control-line injection through a pane's working directory (see P1). A
  # program in a pane that cds into a directory with a newline in its name
  # must not end the mirror or wedge the command stream.
  local d1="$ADV_TMP_ROOT/a9/x"$'\n'"%exit" d2="$ADV_TMP_ROOT/a9/y"$'\n'"%begin 1 999999 0"
  if mkdir -p "$d1" "$d2" 2>/dev/null; then
    t "$sock" send-keys -t main "cd '$ADV_TMP_ROOT/a9/x'\$'\\n''%exit'" Enter
    sleep 2
    mirror_attached "$sock" && pass "a cwd containing '\\n%exit' did not end the mirror" \
      || fail "a cwd containing '\\n%exit' ended the mirror: subscription values are injected as control lines"
    t "$sock" send-keys -t main "cd '$ADV_TMP_ROOT/a9/y'\$'\\n''%begin 1 999999 0'" Enter
    sleep 1
    t "$sock" new-window -t main; wc=$((wc + 1))
    wait_until 10 window_count_is "$sock" "$wc" && pass "a cwd containing '\\n%begin' did not wedge the stream" \
      || fail "a cwd containing '\\n%begin ...' wedged the command stream (new window never arrived)"
  else
    skip "could not create directories with newlines in their names"
  fi
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$sock" $ids
  assert_app_healthy
}

# ---- A10: normal quit while attached (kill -9 and relaunch are manual) ---------
attack_A10() {
  require_feature || return
  local sock; sock="$(new_server a10)"
  run_bounded 30 mirror_rpc "$sock"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  RELAUNCHED=1
  local pid; pid="$(app_pid)"
  osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || kill -TERM "$pid"
  wait_until 20 bash -c "! kill -0 $pid 2>/dev/null"
  wait_until 2 no_control_clients "$sock" && pass "no control client 2 s after a normal quit" \
    || fail "$(control_clients "$sock") control clients remain after a normal quit (R18)"
  server_alive "$sock" && pass "the session survived the quit" || fail "the session died with the app"
  relaunch_app || { fail "the app did not come back after relaunch"; return; }
  RELAUNCHED=""
  run_bounded 30 mirror_rpc "$sock"
  [ "$RB_STATUS" -eq 0 ] && wait_until 10 has_control_client "$sock" && pass "relaunch and re-run attaches again" \
    || fail "re-run after relaunch failed: $RB_OUT"
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$sock" $(workspace_ids_from "$RB_OUT")
  info "kill -9 and relaunch are manual: see the MANUAL CASES block at the top of this script"
}

# ---- A11: TMUX, TMUX_PANE and TMUX_TMPDIR confusion ----------------------------
attack_A11() {
  require_feature || return
  # The decoy is a real server at the default path under a decoy TMUX_TMPDIR,
  # so following TMUX_TMPDIR (or the decoy TMUX) would reach a live server.
  local real decoy decoydir uid
  uid="$(id -u)"
  real="$(new_server a11real)"
  decoydir="$ADV_TMP_ROOT/a11tmp"; mkdir -p "$decoydir/tmux-$uid"; chmod 700 "$decoydir/tmux-$uid"
  decoy="$decoydir/tmux-$uid/default"
  "$TMUX_BIN" -S "$decoy" -f /dev/null new-session -d -s decoy || { fail "could not start the decoy server"; return; }
  track_server "$decoy"
  # 1. The app itself carries a decoy environment.
  RELAUNCHED=1
  relaunch_app "TMUX=$decoy,1,0" "TMUX_PANE=%0" "TMUX_TMPDIR=$decoydir" || { fail "could not relaunch with decoy env"; return; }
  run_bounded 30 mirror_cli "$real"
  wait_until 10 has_control_client "$real" && pass "app with a decoy environment mirrored the resolved server" \
    || fail "nothing attached to the resolved server with a decoy app environment: $RB_OUT"
  no_control_clients "$decoy" && pass "the decoy server got no client" || fail "the decoy server got a control client (R21)"
  # The app's one-shots must use the same server: a window added through the
  # mirror's server shows up in the mirror, and nothing changes on the decoy.
  t "$real" new-window -t main
  wait_until 10 window_count_is "$real" 2 && pass "one-shots and the stream agree on the resolved server" \
    || fail "the mirror did not see a window added on the resolved server"
  [ "$(t "$decoy" list-windows -a 2>/dev/null | grep -c .)" -eq 1 ] && pass "the decoy server was not modified" \
    || fail "the decoy server's windows changed"
  rpc remote.tmux.detach "$(local_params "$real" main)" >/dev/null 2>&1
  wait_until 10 no_control_clients "$real"
  relaunch_app; RELAUNCHED=""
  # 2. CLI run "inside" a nested tmux (TMUX set) while TMUX_TMPDIR points at
  # the decoy: D3 puts $TMUX before TMUX_TMPDIR.
  run_bounded 30 env TMUX="$real,4242,0" TMUX_PANE=%0 TMUX_TMPDIR="$decoydir" \
    "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --no-focus
  wait_until 10 has_control_client "$real" && pass "inside nested tmux, the CLI chose \$TMUX's server" \
    || fail "inside nested tmux, the CLI did not mirror \$TMUX's server: $RB_OUT"
  no_control_clients "$decoy" && pass "the TMUX_TMPDIR decoy got no client" || fail "the CLI followed TMUX_TMPDIR over \$TMUX"
  rpc remote.tmux.detach "$(local_params "$real" main)" >/dev/null 2>&1
  # 3. Outside tmux, TMUX_TMPDIR decides.
  wait_until 10 no_control_clients "$real"
  local fake_tmpdir="$decoydir"
  run_bounded 30 env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$fake_tmpdir" \
    "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --no-focus
  wait_until 10 has_control_client "$decoy" && pass "outside tmux, TMUX_TMPDIR chose its default server" \
    || fail "outside tmux, TMUX_TMPDIR's default server was not mirrored: $RB_OUT"
  no_control_clients "$real" && pass "and nothing attached to the other server" || fail "the other server got a client"
}

# ---- A13: races in the CLI's create-if-no-server flow --------------------------
attack_A13() {
  require_feature || return
  local gate="$ADV_TMP_ROOT/a13gate"; mkdir -p "$gate"
  # The fake runs the real tmux, then, after a "no server" list-sessions,
  # announces it and waits for the scenario to release it.
  local pause; pause="$(make_fake pause <<EOF
"$REAL_TMUX" "\$@"; rc=\$?
case " \$* " in
  *" list-sessions "*|*" ls "*)
    if [ \$rc -ne 0 ]; then
      touch "$gate/paused"
      i=0; while [ ! -e "$gate/go" ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
    fi ;;
esac
exit \$rc
EOF
)"
  local dir="$ADV_TMP_ROOT/a13"; mkdir -p "$dir"; chmod 700 "$dir"
  local sock="$dir/s" start="$ADV_TMP_ROOT/a13start"; mkdir -p "$start"
  track_server "$sock"
  # Race 1: another shell starts the server between the check and new-session.
  rm -f "$gate/paused" "$gate/go"
  ( cd "$start" && PATH="$pause:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus > "$ADV_TMP_ROOT/a13.out" 2>&1; echo $? > "$ADV_TMP_ROOT/a13.rc" ) &
  local cpid=$!
  if wait_until 20 test -e "$gate/paused"; then
    "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s from-other-shell
    touch "$gate/go"
    wait "$cpid"
    local rc; rc="$(cat "$ADV_TMP_ROOT/a13.rc")"
    [ "$rc" = 0 ] && pass "server started mid-flow: the CLI succeeded" || fail "server started mid-flow: status $rc: $(cat "$ADV_TMP_ROOT/a13.out")"
    local ns; ns="$(t "$sock" list-sessions 2>/dev/null | grep -c .)"
    [ "$ns" -eq 2 ] && pass "both sessions exist" || fail "$ns sessions (expected 2)"
    sleep 2
    [ "$(control_clients "$sock")" -ge 1 ] && pass "the mirror attached" || fail "the mirror did not attach"
    info "control clients per session: $(t "$sock" list-clients -F '#{client_control_mode} #{session_name}' | tr '\n' ';')"
  else
    fail "the CLI never ran list-sessions through PATH's tmux (did it probe some other way?)"
    touch "$gate/go"; wait "$cpid"
  fi
  t "$sock" kill-server 2>/dev/null
  wait_until 5 bash -c "! '$TMUX_BIN' -S '$sock' ls"
  # Race 2: the start directory disappears between the check and new-session.
  rm -f "$gate/paused" "$gate/go"; mkdir -p "$start"
  ( cd "$start" && PATH="$pause:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus > "$ADV_TMP_ROOT/a13b.out" 2>&1; echo $? > "$ADV_TMP_ROOT/a13b.rc" ) &
  cpid=$!
  if wait_until 20 test -e "$gate/paused"; then
    rm -rf "$start"
    touch "$gate/go"
    wait "$cpid"
    local rc2 out2; rc2="$(cat "$ADV_TMP_ROOT/a13b.rc")"; out2="$(cat "$ADV_TMP_ROOT/a13b.out")"
    if [ "$rc2" = 0 ]; then
      local p; p="$(t "$sock" display-message -p -t "$(t "$sock" list-sessions -F '#{session_name}' | head -1)" '#{pane_current_path}' 2>/dev/null)"
      [ "$p" = "$HOME" ] && pass "start dir removed mid-flow: the session opened in \$HOME" || fail "start dir removed mid-flow: pane path is '$p'"
      [ -n "$out2" ] && pass "and the CLI printed a notice: $(printf '%s' "$out2" | head -1)" || fail "no notice about the fallback directory"
    else
      [ -n "$out2" ] && ! mentions_ssh "$out2" && pass "start dir removed mid-flow: refused with a clear message: $(printf '%s' "$out2" | head -1)" \
        || fail "start dir removed mid-flow: status $rc2 with message '$out2'"
    fi
  else
    fail "the CLI never paused for race 2"; touch "$gate/go"; wait "$cpid"
  fi
}

# ---- A14: socket_path symlinked to another user's socket, or swapped ----------
attack_A14() {
  require_feature || return
  local other_dir="/tmp/cmuxadv-other.$$" other_sock own lnk
  if sudo -n true 2>/dev/null; then
    sudo -n mkdir -p "$other_dir" && sudo -n chown nobody "$other_dir" && sudo -n chmod 755 "$other_dir"
    sudo -n -u nobody "$TMUX_BIN" -S "$other_dir/s" -f /dev/null new-session -d -s theirs 2>/dev/null
    sudo -n chmod 777 "$other_dir/s" 2>/dev/null   # connectable, so only the owner check can refuse it
    other_sock="$other_dir/s"
  fi
  if [ -z "${other_sock:-}" ] || [ ! -S "$other_sock" ]; then
    skip "cannot create another user's socket (no passwordless sudo); T19 covers the faked regular-file case"
    return
  fi
  own="$(new_server a14)"
  lnk="$ADV_TMP_ROOT/a14/link"
  ln -s "$other_sock" "$lnk"
  run_bounded 20 rpc remote.tmux.mirror "$(local_params "$lnk")"
  rpc_refused && pass "a symlink to another user's socket is refused" || fail "a symlink to another user's socket was accepted: $RB_OUT"
  [ "$(sudo -n -u nobody "$TMUX_BIN" -S "$other_sock" list-clients 2>/dev/null | grep -c .)" -eq 0 ] \
    && pass "no client reached the other user's server" || fail "a client attached to another user's server"
  run_bounded 20 rpc remote.tmux.mirror "$(local_params "$other_sock")"
  rpc_refused && pass "another user's socket by its real path is refused" || fail "another user's socket was accepted: $RB_OUT"
  # Swap race: flip a path between our socket and theirs while attaching.
  local swap="$ADV_TMP_ROOT/a14/swap"
  ( i=0; while [ $i -lt 400 ]; do ln -sfh "$own" "$swap"; ln -sfh "$other_sock" "$swap"; i=$((i+1)); done ) &
  local spid=$!
  local k; for k in 1 2 3 4 5 6 7 8 9 10; do
    run_bounded 20 rpc remote.tmux.mirror "$(local_params "$swap")"
    for w in $(workspace_ids_from "$RB_OUT"); do close_workspace "$w"; done
  done
  wait "$spid"
  [ "$(sudo -n -u nobody "$TMUX_BIN" -S "$other_sock" list-clients 2>/dev/null | grep -c .)" -eq 0 ] \
    && pass "the swap race never reached the other user's server" || fail "the swap race attached to another user's server"
  sudo -n -u nobody "$TMUX_BIN" -S "$other_sock" kill-server 2>/dev/null
  sudo -n rm -rf "$other_dir"
}

# ---- helpers for A15 to A21 ----------------------------------------------------
cli_path() { printf '%s\n' "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh"; }
server_pid() { t "$1" display-message -p '#{pid}' 2>/dev/null; }
control_client_pid() {
  t "$1" list-clients -F '#{client_control_mode} #{client_pid}' 2>/dev/null | awk '$1 == 1 { print $2; exit }'
}
# The run ended by itself (not killed by the bound) and without a signal.
ended_cleanly() { [ "$RB_STATUS" -ne 124 ] && [ "$RB_STATUS" -lt 128 ]; }
# Predicates for wait_until, which re-runs them on every poll.
no_tmux_children() { [ "$(tmux_descendant_count "$(app_pid)")" -eq 0 ]; }
fds_at_most() { [ "$(fd_count "$1")" -le "$2" ]; }

# ---- A15: a frozen server ----------------------------------------------------------
# The server's socket accepts connections (the kernel queues them) but nothing
# answers. The CLI's own probe (`list-sessions`, run before any RPC) and the
# app's attach must both end within a bound and leave no tmux process behind.
attack_A15() {
  require_feature || return
  local sock pid
  sock="$(new_server a15)"
  pid="$(server_pid "$sock")"
  [ -n "$pid" ] || { fail "could not read the server's pid"; return; }
  kill -STOP "$pid"
  run_bounded 90 mirror_cli "$sock"
  printf 'cli(%s after %ss): %s\n' "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" > "$ARTIFACTS/A15.txt"
  [ "$RB_STATUS" -ne 124 ] && pass "the CLI gave up on a frozen server after ${RB_ELAPSED}s" \
    || fail "the CLI was still waiting on a frozen server after 90 s (its tmux probe has no time limit)"
  [ "$RB_STATUS" -ne 0 ] || fail "the CLI reported success against a frozen server"
  run_bounded 90 mirror_rpc "$sock"
  printf 'rpc(%s after %ss): %s\n' "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" >> "$ARTIFACTS/A15.txt"
  [ "$RB_STATUS" -ne 124 ] && pass "the app's attach to a frozen server ended after ${RB_ELAPSED}s" \
    || fail "the app's attach to a frozen server was still waiting after 90 s"
  wait_until 15 no_tmux_children \
    && pass "no tmux process is left waiting on the frozen server" \
    || fail "$(tmux_descendant_count "$(app_pid)") tmux processes still wait on the frozen server"
  kill -CONT "$pid"
  t "$sock" kill-server 2>/dev/null
  assert_app_healthy
}

# ---- A16: the socket path changes hands after the attach --------------------------
# The boundary checks ownership when the RPC arrives. Here the mirrored
# server's socket is moved aside (the server keeps running on its open
# listening socket), another user's server is started at the same path, and
# cmux's client is detached from outside, so the app reconnects to that path.
attack_A16() {
  require_feature || return
  if ! sudo -n true 2>/dev/null; then
    skip "needs passwordless sudo to start another user's server"; return
  fi
  local dir="$ADV_TMP_ROOT/a16"
  mkdir -p "$dir"; chmod 777 "$dir"   # writable by the other user, and not sticky
  local sock="$dir/s"
  "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s main || { fail "could not start the server"; return; }
  track_server "$sock"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  mv "$sock" "$dir/s.moved"
  track_server "$dir/s.moved"
  sudo -n -u nobody "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s theirs 2>/dev/null
  sudo -n chmod 777 "$sock" 2>/dev/null
  if [ ! -S "$sock" ]; then skip "could not start the other user's server"; return; fi
  local c; c="$(t "$dir/s.moved" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2; exit}')"
  t "$dir/s.moved" detach-client -t "$c"
  sleep 8
  [ "$(sudo -n -u nobody "$TMUX_BIN" -S "$sock" list-clients 2>/dev/null | grep -c .)" -eq 0 ] \
    && pass "the reconnect never reached the other user's server" \
    || fail "after the socket changed hands, the app's reconnect attached to another user's server"
  local n; n="$(tmux_descendant_count "$(app_pid)")"
  wait_until 10 no_tmux_children \
    && pass "no reconnect loop against the foreign socket" \
    || fail "the app keeps $n tmux processes going against the foreign socket (reconnect loop?)"
  info "events: $(state_json "$sock" main | head -c 400)"
  sudo -n -u nobody "$TMUX_BIN" -S "$sock" kill-server 2>/dev/null
  local w; for w in $ids; do close_workspace "$w"; done
  assert_app_healthy
}

# ---- A17: no pty left ----------------------------------------------------------------
# A helper holds every free pty, so openpty fails inside the app. The attach
# must fail with a clear message, the app must not crash, and once the ptys
# are released its descriptor count must be where it was and a mirror must work.
attack_A17() {
  require_feature || return
  command -v python3 >/dev/null || { skip "python3 is not available to hold ptys"; return; }
  local sock pid base ready="$ADV_TMP_ROOT/a17.ready" release="$ADV_TMP_ROOT/a17.release"
  sock="$(new_server a17)"
  pid="$(app_pid)"
  base="$(fd_count "$pid")"
  rm -f "$ready" "$release"
  python3 -I -c '
import os, resource, sys, time
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
target = hard if hard != resource.RLIM_INFINITY else 65536
try:
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(target, 65536), hard))
except Exception:
    pass
held = []
reason = "no error"
while True:
    try:
        held.append(os.openpty())
    except OSError as error:
        reason = str(error)
        break
open(sys.argv[1], "w").write("%d ptys held; next openpty: %s\n" % (len(held), reason))
deadline = time.time() + 90
while not os.path.exists(sys.argv[2]) and time.time() < deadline:
    time.sleep(0.1)
' "$ready" "$release" &
  local hpid=$!
  if ! wait_until 30 test -s "$ready"; then
    kill "$hpid" 2>/dev/null; fail "the pty holder never reported"; return
  fi
  info "pty holder: $(cat "$ready")"
  run_bounded 40 mirror_rpc "$sock"
  printf 'rpc(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A17.txt"
  touch "$release"; wait "$hpid"
  app_alive && pass "the app survived having no pty" || { fail "the app crashed when no pty was available"; return; }
  [ "$RB_STATUS" -ne 124 ] && rpc_refused && pass "the attach failed with a message: $(printf '%s' "$RB_OUT" | head -c 200)" \
    || fail "with no pty the attach did not fail cleanly (status $RB_STATUS): $RB_OUT"
  wait_until 10 fds_at_most "$pid" "$base" \
    && pass "descriptors back at the baseline after the failed attach ($(fd_count "$pid") <= $base)" \
    || fail "descriptors grew from $base to $(fd_count "$pid") after the failed attach"
  local w; for w in $(workspace_ids_from "$RB_OUT"); do close_workspace "$w"; done
  t "$sock" kill-server 2>/dev/null
  assert_app_healthy
}

# ---- A18: 30 detaches from the server side ------------------------------------------
# The leak check closes workspaces; this ends the stream from tmux's side
# (`detach-client`), which takes the reconnect path and a fresh pty each time.
attack_A18() {
  require_feature || return
  local sock pid base i c ids=""
  sock="$(new_server a18)"
  pid="$(app_pid)"
  run_bounded 30 mirror_rpc "$sock"; ids="$ids $(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  c="$(t "$sock" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2; exit}')"
  t "$sock" detach-client -t "$c"; wait_until 10 no_control_clients "$sock"; sleep 2
  base="$(fd_count "$pid")"
  lsof -p "$pid" > "$ARTIFACTS/A18-lsof-baseline.txt" 2>/dev/null
  for i in $(seq 1 30); do
    if ! has_control_client "$sock"; then
      wait_until 5 has_control_client "$sock" || { run_bounded 30 mirror_rpc "$sock"; ids="$ids $(workspace_ids_from "$RB_OUT")"; }
    fi
    wait_until 10 has_control_client "$sock" || continue
    c="$(t "$sock" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2; exit}')"
    t "$sock" detach-client -t "$c" 2>/dev/null
    wait_until 10 no_control_clients "$sock"
  done
  sleep 3
  lsof -p "$pid" > "$ARTIFACTS/A18-lsof-after.txt" 2>/dev/null
  local after; after="$(fd_count "$pid")"
  [ "$after" -le "$base" ] && pass "descriptors back at baseline after 30 server-side detaches ($after <= $base)" \
    || fail "descriptors grew from $base to $after over 30 server-side detaches (see A18-lsof-*.txt)"
  [ "$(zombie_children "$pid")" -eq 0 ] && pass "no zombie children" || fail "$(zombie_children "$pid") zombie children"
  local w; for w in $ids; do close_workspace "$w"; done
  t "$sock" kill-server 2>/dev/null
}

# ---- A19: the control client is stopped --------------------------------------------
# A stopped client reads nothing, so the pty fills and the app's stdin writer
# waits in poll. Continuing it must resume the mirror; detaching it while
# stopped must still end it (SIGTERM stays pending on a stopped process).
attack_A19() {
  require_feature || return
  local sock cpid i
  sock="$(new_server a19)"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach"; return; }
  cpid="$(control_client_pid "$sock")"
  [ -n "$cpid" ] || { fail "could not find cmux's control client"; return; }
  kill -STOP "$cpid"
  # Make the app write: every new window makes it send several commands.
  for i in $(seq 1 40); do t "$sock" new-window -t main >/dev/null 2>&1; done
  sleep 2
  app_responds && pass "the app answers while its control client is stopped" \
    || fail "the app stopped answering while its control client was stopped"
  kill -CONT "$cpid"
  wait_until 20 window_count_is "$sock" 41 && pass "after SIGCONT the mirror caught up (41 windows)" \
    || fail "after SIGCONT the mirror shows $(mirror_window_count "$sock") windows, not 41"
  cpid="$(control_client_pid "$sock")"
  kill -STOP "$cpid"
  local w; for w in $ids; do close_workspace "$w"; done
  wait_until 15 bash -c "! kill -0 $cpid 2>/dev/null" && pass "a stopped client is still ended by the detach" \
    || { fail "the stopped client $cpid is still alive 15 s after the detach"; kill -CONT "$cpid" 2>/dev/null; }
  wait_until 5 no_control_clients "$sock" && pass "no control client left" || fail "a control client is left attached"
  t "$sock" kill-server 2>/dev/null
  assert_app_healthy
}

# ---- A20: odd socket locations from the CLI ------------------------------------------
# A relative --socket-path from a deleted working directory, a relative
# TMUX_TMPDIR, and a TMUX_TMPDIR too long for a Unix socket path. Each must
# end with a clear message and a normal exit; none may mirror some other server.
attack_A20() {
  require_feature || return
  local gone="$ADV_TMP_ROOT/a20gone" out
  mkdir -p "$gone"
  run_bounded 30 bash -c "cd '$gone' && rmdir '$gone' && exec '$(cli_path)' tmux-mirror --socket-path rel/s --no-focus"
  out="$RB_OUT"; printf 'deleted-cwd(%s): %s\n' "$RB_STATUS" "$out" > "$ARTIFACTS/A20.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && pass "relative socket path from a deleted directory: refused ($(printf '%s' "$out" | head -1))" \
    || fail "relative socket path from a deleted directory: status $RB_STATUS: $out"
  local rel="$ADV_TMP_ROOT/a20rel"; mkdir -p "$rel"
  run_bounded 30 bash -c "cd '$rel' && TMUX_TMPDIR=relative-tmp exec '$(cli_path)' tmux-mirror --no-focus"
  out="$RB_OUT"; printf 'relative-tmpdir(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A20.txt"
  ended_cleanly && pass "relative TMUX_TMPDIR: ended normally (status $RB_STATUS)" || fail "relative TMUX_TMPDIR: status $RB_STATUS"
  if [ "$RB_STATUS" -eq 0 ]; then
    info "relative TMUX_TMPDIR was accepted; the server it made is under $rel/relative-tmp"
    "$TMUX_BIN" -S "$rel/relative-tmp/tmux-$(id -u)/default" kill-server 2>/dev/null
  fi
  local long="$ADV_TMP_ROOT/$(printf 'L%.0s' $(seq 1 120))"
  mkdir -p "$long"
  run_bounded 30 env TMUX_TMPDIR="$long" "$(cli_path)" tmux-mirror --no-focus
  out="$RB_OUT"; printf 'long-tmpdir(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A20.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && ! mentions_ssh "$out" && pass "over-long socket path: refused ($(printf '%s' "$out" | head -1))" \
    || fail "over-long socket path: status $RB_STATUS: $out"
}

# ---- A21: a tmux wrapper whose child keeps stderr open ------------------------------
# Some tmux wrappers start a helper in the background. The helper inherits
# stderr, so a reader that waits for stderr to close keeps waiting after tmux
# itself has exited.
attack_A21() {
  require_feature || return
  local sock; sock="$(new_server a21)"
  local wrapper; wrapper="$(make_fake stderrheld <<EOF
sleep 300 &
echo \$! >> "$FAKES/stderrheld.pids"
exec "$REAL_TMUX" "\$@"
EOF
)"
  : > "$FAKES/stderrheld.pids"
  run_bounded 60 env PATH="$wrapper:/usr/bin:/bin" "$(cli_path)" tmux-mirror --socket-path "$sock" --no-focus
  printf 'wrapper(%s after %ss): %s\n' "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" > "$ARTIFACTS/A21.txt"
  [ "$RB_STATUS" -ne 124 ] && pass "the CLI returned after ${RB_ELAPSED}s although a child held tmux's stderr" \
    || fail "the CLI waited 60 s for stderr to close after tmux had exited (it reads stderr to end-of-file)"
  local p; for p in $(cat "$FAKES/stderrheld.pids"); do kill "$p" 2>/dev/null; done
  t "$sock" kill-server 2>/dev/null
}

# ---- run -------------------------------------------------------------------------
log "tmux: $("$TMUX_BIN" -V 2>/dev/null); old tmux: $([ -x "$TMUX_OLD_BIN" ] && "$TMUX_OLD_BIN" -V)"
enable_betas
FEATURE=0
if app_responds; then
  feature_present && FEATURE=1
else
  log "the tagged app ($TAG) is not answering on $APP_SOCKET"
fi
log "cmux tmux-mirror present: $([ "$FEATURE" = 1 ] && echo yes || echo no)"
for id in $ALL_IDS; do
  selected "$id" || continue
  CURRENT_ID="$id"
  log "== $id"
  "attack_$id"
done
summary | tee "$ARTIFACTS/summary.txt"
exit "$FAILURES"
