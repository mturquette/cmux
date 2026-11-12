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
# A22 to A25 come from the independent review (review/review-63d4da35c1f.md):
#   A22 (S6) --socket-path in a directory other users can write to, and a
#       socket swapped in by another user between the check and the connect
#   A23 (B1) an image pasted into a local mirror pane never invokes ssh or scp
#   A24 (S1) with the beta off, or `attach <missing session>`, no tmux server
#       or session is left behind
#   A25 (S3) a session created from cmux's UI does not start in the app's
#       working directory
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

ALL_IDS="P1 P2 A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A13 A14 A15 A16 A17 A18 A19 A20 A21 A22 A23 A24 A25"
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

# Writes a fake tmux into $FAKES/<name>/tmux from the body on stdin, and
# leaves its directory in $FAKE_DIR. Call it directly, never inside $(...):
# bash 3.2 mis-parses a here-document inside a command substitution when the
# body holds `case` patterns, because a pattern's `)` closes the substitution.
make_fake() {
  mkdir -p "$FAKES/$1"
  { echo '#!/bin/sh'; cat; } > "$FAKES/$1/tmux"
  chmod 755 "$FAKES/$1/tmux"
  FAKE_DIR="$FAKES/$1"
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

# ---- P2: a tmux client against a server of another version (Q-C9) ------------
# No cmux involved. For each pairing of server and client binary, runs the
# one-shot commands and the control-mode commands that cmux's mirror sends
# (their shapes are taken from Sources/RemoteTmuxControlConnection*.swift),
# one at a time, and records for each whether tmux answered with %end, with
# %error, or not at all. Also finds the server's own binary from its pid.
# Everything goes to $ARTIFACTS/P2-*.txt; P2-summary.txt is the table.
P2_CONTROL_COMMANDS=(
  "display-message -p '#{version}'"
  "list-sessions -F '#{session_id} #{session_name} #{session_windows} #{session_attached} #{session_created}'"
  "list-windows -F '#{window_id} #{window_index} #{window_name} #{window_layout} #{window_visible_layout} #{window_flags} #{window_active} #{window_linked}'"
  "list-panes -s -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active} #{pane_current_command}'"
  "refresh-client -C 160x48"
  "refresh-client -C '@0:160x48'"
  "refresh-client -B \"cmux_cwd_0:%0:#{pane_current_path}\""
  "refresh-client -B 'cmux_sessions::#{S:#{session_id}=#{session_name}:#{W:#{window_id}.}|,}'"
  "refresh-client -B \"cmux_title_0:%0:#{pane_title}\""
  "refresh-client -A '%0:pause'"
  "refresh-client -A '%0:continue'"
  "capture-pane -p -e -t %0 -S -5"
  "display-message -p -t %0 -F '#{cursor_x},#{cursor_y},#{scroll_region_upper},#{scroll_region_lower},#{origin_flag},#{mouse_sgr_flag},#{alternate_on}'"
  "display-message -p -t %0 -F '#{T:pane-border-format}'"
  "set-option -w -t @0 @cmux_view 1"
  "new-window -d"
  "send-keys -t %0 -l x"
)

# p2_control <client-binary> <socket> <label>: attaches a control client and
# sends each command alone, waiting up to 3 s for its reply.
p2_control() {
  local bin="$1" sock="$2" label="$3"
  local fifo="$ADV_TMP_ROOT/p2-$label.in" out="$ARTIFACTS/P2-$label-control.txt" err="$ARTIFACTS/P2-$label-control.err"
  mkfifo "$fifo"
  ( "$bin" -S "$sock" -C attach -t main < "$fifo" > "$out" 2> "$err"; echo "client exit $?" >> "$err" ) &
  local cpid=$!
  exec 6> "$fifo"
  sleep 1
  local i=0 cmd before ends
  : > "$ARTIFACTS/P2-$label-results.txt"
  for cmd in "${P2_CONTROL_COMMANDS[@]}"; do
    i=$((i + 1))
    before="$(grep -acE '^%(end|error) ' "$out" 2>/dev/null)"; before="${before:-0}"
    if ! kill -0 "$cpid" 2>/dev/null; then
      printf '%s\t%s\n' "client gone" "$cmd" >> "$ARTIFACTS/P2-$label-results.txt"; continue
    fi
    printf '%s\n' "$cmd" >&6
    local w=0
    while [ "$w" -lt 30 ]; do
      ends="$(grep -acE '^%(end|error) ' "$out" 2>/dev/null)"; ends="${ends:-0}"
      [ "$ends" -gt "$before" ] && break
      sleep 0.1; w=$((w + 1))
    done
    if [ "$ends" -gt "$before" ]; then
      tail -r "$out" 2>/dev/null | grep -am1 -E '^%(end|error) ' | awk -v c="$cmd" '{ printf "%s\t%s\n", ($1 == "%end" ? "ok" : "ERROR"), c }' >> "$ARTIFACTS/P2-$label-results.txt"
    else
      printf '%s\t%s\n' "NO REPLY in 3 s" "$cmd" >> "$ARTIFACTS/P2-$label-results.txt"
    fi
  done
  printf 'detach-client\n' >&6
  exec 6>&-
  wait_until 5 bash -c "! kill -0 $cpid 2>/dev/null"; kill "$cpid" 2>/dev/null
}

# p2_oneshots <client-binary> <socket> <label>
p2_oneshots() {
  # Two statements: bash 3.2 expands every word of one `local` before it
  # assigns any, so `$label` would still be unset here under `set -u`.
  local bin="$1" sock="$2" label="$3"
  local f="$ARTIFACTS/P2-$label-oneshots.txt"
  : > "$f"
  local args
  for args in "-V" "list-sessions" "display-message -p #{version}" "list-windows -a" "new-window -d" "has-session -t main"; do
    # shellcheck disable=SC2086
    run_bounded 10 "$bin" -S "$sock" $args
    printf 'status %s\t%s\t%s\n' "$RB_STATUS" "$args" "$(printf '%s' "$RB_OUT" | tr '\n' ' ' | head -c 160)" >> "$f"
  done
}

attack_P2() {
  [ -x "$TMUX_OLD_BIN" ] || { skip "TMUX_OLD_BIN ($TMUX_OLD_BIN) is not installed"; return; }
  local old_sock new_sock summary="$ARTIFACTS/P2-summary.txt"
  old_sock="$(new_server p2old "$TMUX_OLD_BIN")" || { fail "could not start a 3.2a server"; return; }
  new_sock="$(new_server p2new "$TMUX_BIN")" || { fail "could not start a 3.6a server"; return; }
  {
    echo "server old: $("$TMUX_OLD_BIN" -V)   client new: $("$TMUX_BIN" -V)"
    echo "PROTOCOL_VERSION in source (tmux.h at 3.2a, tmux-protocol.h at 3.6a): 8 and 8"
  } > "$summary"
  p2_oneshots "$TMUX_BIN" "$old_sock" old-server-new-client
  p2_oneshots "$TMUX_OLD_BIN" "$old_sock" old-server-old-client
  p2_control "$TMUX_BIN" "$old_sock" old-server-new-client
  p2_control "$TMUX_OLD_BIN" "$old_sock" old-server-old-client
  p2_control "$TMUX_BIN" "$new_sock" new-server-new-client
  # The server's own binary, found from outside the way the app could.
  local spid comm cmdline txt
  spid="$("$TMUX_OLD_BIN" -S "$old_sock" display-message -p '#{pid}' 2>/dev/null)"
  comm="$(ps -o comm= -p "$spid" 2>/dev/null)"
  cmdline="$(ps -o command= -p "$spid" 2>/dev/null)"
  txt="$(lsof -a -p "$spid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  {
    echo
    echo "server pid: $spid"
    echo "ps -o comm=: $comm"
    echo "ps -o command=: $cmdline"
    echo "lsof txt (executable): $txt"
    [ -n "$comm" ] && [ -x "$comm" ] && echo "comm -V: $("$comm" -V 2>&1)"
    [ -n "$txt" ] && [ -x "$txt" ] && echo "lsof txt -V: $("$txt" -V 2>&1)"
    local label
    for label in old-server-new-client old-server-old-client new-server-new-client; do
      echo
      echo "== control mode, $label (stderr: $(tr '\n' ' ' < "$ARTIFACTS/P2-$label-control.err"))"
      cat "$ARTIFACTS/P2-$label-results.txt"
    done
    for label in old-server-new-client old-server-old-client; do
      echo
      echo "== one-shots, $label"
      cat "$ARTIFACTS/P2-$label-oneshots.txt"
    done
  } >> "$summary"
  # A server whose binary was deleted after it started, as `brew upgrade`
  # does to the old version: what the pid lookups return, and whether the
  # path still runs.
  local copy="$ADV_TMP_ROOT/p2copy/bin/tmux" dsock dpid dcomm dtxt
  mkdir -p "$(dirname "$copy")" && cp "$TMUX_OLD_BIN" "$copy"
  dsock="$(new_server p2deleted "$copy")"
  dpid="$("$TMUX_OLD_BIN" -S "$dsock" display-message -p '#{pid}' 2>/dev/null)"
  rm -f "$copy"
  dcomm="$(ps -o comm= -p "$dpid" 2>/dev/null)"
  dtxt="$(lsof -a -p "$dpid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  {
    echo
    echo "== server started from a binary that was then deleted"
    echo "pid: $dpid"
    echo "ps -o comm=: $dcomm"
    echo "lsof txt: $dtxt"
    echo "that path exists: $([ -e "$dtxt" ] && echo yes || echo no)"
    echo "server still answers a 3.2a one-shot: $("$TMUX_OLD_BIN" -S "$dsock" display-message -p '#{version}' 2>&1)"
  } >> "$summary"
  "$TMUX_OLD_BIN" -S "$dsock" kill-server 2>/dev/null
  sed 's/^/    | /' "$summary"
  pass "probe completed (behavior recorded in P2-summary.txt)"
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
  # No respawn loop: from 2 s to 8 s after the death, no process of the app
  # may name this server's socket at any sample (the first 2 s are
  # teardown). Mirrors of other servers do not count.
  local max=0 n i=0
  while [ "$i" -lt 40 ]; do
    if [ "$i" -ge 10 ]; then n="$(app_procs_for_socket "$sock" | grep -c .)"; [ "$n" -gt "$max" ] && max="$n"; fi
    sleep 0.2; i=$((i + 1))
  done
  [ "$max" -eq 0 ] && pass "no process for this server was running 2 to 8 s after it died" \
    || fail "the app kept up to $max processes for the dead server alive (respawn loop?)"
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
  # Before attach: socket missing. R1 and D7 make "no server at a path tmux
  # can create" a reason to start one, not an error, so the three missing
  # cases expect three different outcomes.
  # (a) CLI, creatable path: a server is started there and mirrored (R1).
  sock="$(new_server a2a)"; dir="$(dirname "$sock")"
  t "$sock" kill-server
  wait_until 5 bash -c "! '$TMUX_BIN' -S '$sock' ls"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  printf 'missing-creatable(%s): %s\n' "$RB_STATUS" "$out" > "$ARTIFACTS/A2-messages.txt"
  [ "$RB_STATUS" -eq 0 ] && server_alive "$sock" && wait_until 10 has_control_client "$sock" \
    && pass "missing socket at a creatable path: the CLI started a server and mirrored it (R1)" \
    || fail "missing socket at a creatable path: status $RB_STATUS, server $(server_alive "$sock" && echo up || echo down): $out"
  t "$sock" kill-server 2>/dev/null
  # (b) CLI, socket inside a directory that does not exist: nothing can be
  # created, so the CLI must refuse with a message about local tmux (R6).
  sock="$ADV_TMP_ROOT/a2-no-such-dir/s"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  printf 'missing-dir(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A2-messages.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && [ -n "$out" ] && pass "socket in a missing directory: refused in ${RB_ELAPSED}s" \
    || fail "socket in a missing directory: status $RB_STATUS (124 means it hung): $out"
  mentions_ssh "$out" && fail "missing-directory message talks about ssh: $out" || pass "missing-directory message has no ssh wording"
  [ ! -e "$ADV_TMP_ROOT/a2-no-such-dir" ] && pass "nothing was created at the missing directory" \
    || fail "the CLI created $ADV_TMP_ROOT/a2-no-such-dir"
  # (c) Socket API, missing socket: the app never creates a server (D8), so
  # this is R6's "socket missing" refusal.
  sock="$ADV_TMP_ROOT/a2a/gone"
  run_bounded 20 rpc remote.tmux.mirror "$(local_params "$sock")"
  printf 'missing-rpc(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$ARTIFACTS/A2-messages.txt"
  [ "$RB_STATUS" -ne 124 ] && rpc_refused && ! mentions_ssh "$RB_OUT" \
    && pass "socket API with a missing socket: refused with a local message" \
    || fail "socket API with a missing socket: status $RB_STATUS: $RB_OUT"

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
  make_fake garbage <<'EOF'
head -c 4096 /dev/urandom
printf '\n%%begin 1 2 3\nnot tmux at all\n'
exit 0
EOF
  garbage="$FAKE_DIR"
  make_fake hang <<EOF
echo \$\$ >> "$FAKES/hang.pids"
exec sleep 100000
EOF
  hang="$FAKE_DIR"
  missing="$FAKES/missing"; mkdir -p "$missing"
  local msgs="$ARTIFACTS/A3-messages.txt"; : > "$msgs"

  # Garbage on the CLI's PATH only. The fake exits 0, so the CLI's own probe
  # (D7) sees a running server, which is true, and hands over to the app,
  # which runs its own tmux. Mirroring is then correct; what must hold is a
  # bounded run and no ssh wording.
  run_bounded 30 env PATH="$garbage:/usr/bin:/bin" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" tmux-mirror --socket-path "$sock" --no-focus
  printf 'garbage-cli-only(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$msgs"
  ended_cleanly && ! mentions_ssh "$RB_OUT" \
    && pass "garbage tmux on the CLI's PATH only: ended normally (status $RB_STATUS)" \
    || fail "garbage tmux on the CLI's PATH only: status $RB_STATUS: $RB_OUT"
  rpc remote.tmux.detach "$(local_params "$sock" main)" >/dev/null 2>&1
  wait_until 10 no_control_clients "$sock"

  # Garbage as the tmux the app runs. Since D4a the app runs a running
  # server's own binary, so the garbage can only be reached two ways (Q-A14):
  # (a) the server's binary was deleted and the garbage is the app's fallback;
  # (b) the server's binary path now holds the garbage itself (replaced in
  # place). Each must be refused, in bounded time, without ssh wording, and
  # nothing may attach.
  local gsock garbage_out="" garbage_status=0 how
  for how in deleted replaced; do
    gsock="$(copied_server "a3$how" "$REAL_TMUX")" || { fail "garbage ($how): could not start a server from a copy"; continue; }
    if [ "$how" = deleted ]; then
      copied_server_delete "a3$how"
      RELAUNCHED=1
      relaunch_app "PATH=$garbage:/usr/bin:/bin" || { fail "could not relaunch the app with the garbage tmux first on PATH"; return; }
    else
      copied_server_replace "a3$how" "$garbage/tmux"
    fi
    run_bounded 40 mirror_rpc "$gsock"
    printf 'garbage-app-%s(%s after %ss): %s\n' "$how" "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" >> "$msgs"
    [ "$how" = deleted ] && { garbage_out="$RB_OUT"; garbage_status="$RB_STATUS"; }
    [ "$RB_STATUS" -ne 124 ] && rpc_refused && pass "garbage tmux in the app ($how binary): refused after ${RB_ELAPSED}s" \
      || fail "garbage tmux in the app ($how binary): not refused cleanly (status $RB_STATUS): $RB_OUT"
    mentions_ssh "$RB_OUT" && fail "garbage tmux message ($how binary) talks about ssh: $RB_OUT" || true
    no_control_clients "$gsock" && pass "garbage tmux in the app ($how binary): nothing attached" \
      || fail "garbage tmux in the app ($how binary): a client attached"
    t "$gsock" kill-server 2>/dev/null
    if [ "$how" = deleted ]; then
      relaunch_app || { fail "could not relaunch the app normally"; return; }
      RELAUNCHED=""
    fi
  done

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

# copied_server <name> <tmux-binary>: starts a server from a private copy of
# the binary at $ADV_TMP_ROOT/<name>-bin/tmux and prints its socket. Since D4a
# the app runs the server's own binary while it exists, so a test that needs
# the app's fallback tmux deletes this copy (copied_server_delete), and a test
# of a binary replaced in place swaps it (copied_server_replace).
copied_server() {
  local name="$1" src="$2" bindir="$ADV_TMP_ROOT/$1-bin" dir="$ADV_TMP_ROOT/$1"
  mkdir -p "$bindir" "$dir"; chmod 700 "$dir"
  cp "$src" "$bindir/tmux" || return 1
  "$bindir/tmux" -S "$dir/s" -f /dev/null new-session -d -s main -x 160 -y 48 || return 1
  track_server "$dir/s" "$src"
  printf '%s\n' "$dir/s"
}
copied_server_delete() { rm -f "$ADV_TMP_ROOT/$1-bin/tmux"; }
# A new file at the same path, as install(1) and `make install` do it. Writing
# over a running executable in place could get the server killed by macOS.
copied_server_replace() { rm -f "$ADV_TMP_ROOT/$1-bin/tmux" && cp "$2" "$ADV_TMP_ROOT/$1-bin/tmux"; }

# ---- A4: tmux 3.2a (oldest supported) and a fake 3.1 --------------------------
attack_A4() {
  require_feature || return
  if [ -x "$TMUX_OLD_BIN" ]; then
    local old_dir; old_dir="$(dirname "$TMUX_OLD_BIN")"
    # (a) A Mac whose tmux is 3.2a: server, CLI and app all use 3.2a. R6
    # refuses only tmux older than 3.2, so this must mirror. A tmux client
    # and server must share a protocol version, so the app is relaunched with
    # 3.2a first on its PATH, and the tmux-side checks use 3.2a too.
    local sock; sock="$(new_server a4old "$TMUX_OLD_BIN")"
    RELAUNCHED=1
    relaunch_app "PATH=$old_dir:/usr/bin:/bin" || { fail "could not relaunch the app with tmux 3.2a first on PATH"; return; }
    run_bounded 30 env PATH="$old_dir:/usr/bin:/bin" "$(cli_path)" tmux-mirror --socket-path "$sock" --no-focus
    printf 'v32a-coherent(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A4-messages.txt"
    if [ "$RB_STATUS" -eq 0 ] && TMUX_BIN="$TMUX_OLD_BIN" wait_until 10 has_control_client "$sock"; then
      pass "$("$TMUX_OLD_BIN" -V) everywhere: the server mirrors"
      "$TMUX_OLD_BIN" -S "$sock" new-window -t main
      wait_until 5 window_count_is "$sock" 2 \
        && pass "a window added on the 3.2a server reaches the mirror" \
        || fail "a window added on the 3.2a server did not reach the mirror"
    else
      fail "$("$TMUX_OLD_BIN" -V) everywhere (the supported minimum) did not mirror: $RB_OUT"
    fi
    "$TMUX_OLD_BIN" -S "$sock" kill-server 2>/dev/null
    relaunch_app || { fail "could not relaunch the app normally"; return; }
    RELAUNCHED=""
    # (b) A 3.2a server while the app's own tmux is 3.6a. A 3.6a control
    # client hangs silently against a 3.2a server (Q-C9, probe P2), so the
    # owner's decision (Q-C9 option 1, Q-A13) is that the app runs the
    # server's own binary, falls back to its own tmux only when the releases
    # match exactly, and otherwise refuses naming both releases.
    local new_rel old_rel
    new_rel="$("$TMUX_BIN" -V | awk '{print $2}')"; old_rel="$("$TMUX_OLD_BIN" -V | awk '{print $2}')"
    # (b1) The server's binary still exists: the app runs it, and mirrors.
    sock="$(new_server a4mixed "$TMUX_OLD_BIN")"
    run_bounded 30 mirror_rpc "$sock"
    printf 'b1 server binary present(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
    if [ "$RB_STATUS" -eq 0 ] && TMUX_BIN="$TMUX_OLD_BIN" wait_until 10 has_control_client "$sock"; then
      pass "b1: a $old_rel server with $new_rel as the app's tmux mirrors through the server's own binary"
      "$TMUX_OLD_BIN" -S "$sock" new-window -t main
      wait_until 5 window_count_is "$sock" 2 && pass "b1: a window added on the server reaches the mirror" \
        || fail "b1: a window added on the server did not reach the mirror"
      rpc remote.tmux.detach "$(local_params "$sock" main)" >/dev/null 2>&1
    else
      fail "b1: a $old_rel server whose binary exists did not mirror (status $RB_STATUS): $RB_OUT"
    fi
    "$TMUX_OLD_BIN" -S "$sock" kill-server 2>/dev/null
    # (b2) The server's binary was deleted (as `brew upgrade` does), and the
    # app's fallback is $new_rel: refused, naming both releases, in bounded time.
    sock="$(copied_server a4deleted "$TMUX_OLD_BIN")" || { fail "b2: could not start a server from a copy"; return; }
    copied_server_delete a4deleted
    run_bounded 30 mirror_rpc "$sock"
    printf 'b2 binary deleted, fallback %s(%s after %ss): %s\n' "$new_rel" "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
    if [ "$RB_STATUS" -ne 124 ] && rpc_refused; then
      printf '%s' "$RB_OUT" | grep -qF "$old_rel" && printf '%s' "$RB_OUT" | grep -qF "$new_rel" \
        && pass "b2: refused after ${RB_ELAPSED}s, naming both $old_rel and $new_rel" \
        || fail "b2: refused, but the message does not name both $old_rel and $new_rel: $RB_OUT"
    else
      fail "b2: a deleted $old_rel binary with a $new_rel fallback was not refused cleanly (status $RB_STATUS): $RB_OUT"
    fi
    TMUX_BIN="$TMUX_OLD_BIN" no_control_clients "$sock" && pass "b2: nothing attached" || fail "b2: a control client attached"
    # (b3) The same server, with the app relaunched so its fallback is 3.2a:
    # the releases match exactly, so it mirrors.
    RELAUNCHED=1
    relaunch_app "PATH=$old_dir:/usr/bin:/bin" || { fail "b3: could not relaunch the app with $old_rel first on PATH"; return; }
    run_bounded 30 mirror_rpc "$sock"
    printf 'b3 binary deleted, fallback %s(%s): %s\n' "$old_rel" "$RB_STATUS" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
    [ "$RB_STATUS" -eq 0 ] && TMUX_BIN="$TMUX_OLD_BIN" wait_until 10 has_control_client "$sock" \
      && pass "b3: with a matching $old_rel fallback, the server with a deleted binary mirrors" \
      || fail "b3: with a matching $old_rel fallback, the mirror did not attach: $RB_OUT"
    rpc remote.tmux.detach "$(local_params "$sock" main)" >/dev/null 2>&1
    "$TMUX_OLD_BIN" -S "$sock" kill-server 2>/dev/null
    relaunch_app || { fail "could not relaunch the app normally"; return; }
    RELAUNCHED=""
    # (b4, not in Q-A13) The server's binary path still exists but now holds
    # another release, as after `make install` of a new tmux over the old one
    # while a server runs. Trusting the path would start a $new_rel client
    # against a $old_rel server, which hangs silently. Expected: no hang, a
    # refusal, and a message naming both releases.
    sock="$(copied_server a4replaced "$TMUX_OLD_BIN")" || { fail "b4: could not start a server from a copy"; return; }
    copied_server_replace a4replaced "$TMUX_BIN"
    run_bounded 30 mirror_rpc "$sock"
    printf 'b4 binary replaced by %s(%s after %ss): %s\n' "$new_rel" "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
    if [ "$RB_STATUS" -ne 124 ] && rpc_refused; then
      pass "b4: a binary replaced in place by $new_rel is refused after ${RB_ELAPSED}s"
      printf '%s' "$RB_OUT" | grep -qF "$old_rel" && printf '%s' "$RB_OUT" | grep -qF "$new_rel" \
        && pass "b4: and the message names both $old_rel and $new_rel" \
        || fail "b4: the refusal does not name both releases (the app trusted the path without checking its release?): $RB_OUT"
    else
      fail "b4: a binary replaced in place by $new_rel was not refused cleanly (status $RB_STATUS after ${RB_ELAPSED}s): $RB_OUT"
    fi
    TMUX_BIN="$TMUX_OLD_BIN" no_control_clients "$sock" && pass "b4: nothing attached" || fail "b4: a control client attached"
    "$TMUX_OLD_BIN" -S "$sock" kill-server 2>/dev/null
  else
    skip "TMUX_OLD_BIN ($TMUX_OLD_BIN) is not installed"
  fi
  # A fake that reports 3.1 for -V and for the server's #{version}, and
  # rejects `refresh-client -B` the way tmux before 3.2 does. (The earlier
  # failure was bash 3.2 mis-parsing this here-document inside $(...); see
  # make_fake.)
  local fake31
  make_fake v31 <<EOF
all=" \$* "
case "\$all" in
  *" -V "*)
    echo "tmux 3.1"; exit 0 ;;
esac
case "\$all" in
  *" refresh-client "*)
    echo "unknown flag -B" >&2; exit 1 ;;
esac
case "\$all" in
  *"#{version}"*)
    echo "3.1"; exit 0 ;;
esac
exec "$REAL_TMUX" "\$@"
EOF
  fake31="$FAKE_DIR"
  # The server is started from a copy that is then deleted, so the app has
  # to use its fallback tmux, which is the fake (Q-A14). The app probes the
  # server's #{version} and the fallback's -V through the fake; both say 3.1,
  # they match, and the version gate must then refuse 3.1 as too old.
  local sock31; sock31="$(copied_server a4fake "$REAL_TMUX")" || { fail "could not start the 3.1 case's server"; return; }
  copied_server_delete a4fake
  RELAUNCHED=1
  relaunch_app "PATH=$fake31:/usr/bin:/bin" || { fail "could not relaunch the app with the fake PATH"; return; }
  run_bounded 30 mirror_rpc "$sock31"
  printf 'fake31-app(%s after %ss): %s\n' "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" >> "$ARTIFACTS/A4-messages.txt"
  relaunch_app; RELAUNCHED=""
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
  # DESIGN A7: one mirror per server key. R9: the local mirror behaves as
  # ssh-tmux does, and ssh-tmux refuses a concurrent second attach for the
  # same host through its single-flight check. So one call must succeed, and
  # the other either succeeds too or gets that explicit refusal.
  local okc=0 refusedc=0 o
  for o in "$o1" "$o2"; do
    if grep -q '"mirrored" *: *true\|mirrored.*true' "$o"; then okc=$((okc + 1))
    elif grep -qi 'already attaching' "$o"; then refusedc=$((refusedc + 1)); fi
  done
  [ "$okc" -ge 1 ] && [ $((okc + refusedc)) -eq 2 ] \
    && pass "racing calls: $okc mirrored, $refusedc refused as already attaching" \
    || fail "racing calls: statuses $s1 and $s2, not one success plus success or single-flight refusal: $(cat "$o1") / $(cat "$o2")"
  sleep 2
  local n; n="$(control_clients_on "$sock" main)"
  [ "$n" -eq 1 ] && pass "exactly one control client for the server key" || fail "$n control clients for one session (expected 1)"
  # A later call for the same server must not add a second client either.
  run_bounded 30 mirror_rpc "$sock"
  printf 'third(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A7-third.txt"
  sleep 2
  n="$(control_clients_on "$sock" main)"
  [ "$n" -eq 1 ] && pass "a later call kept one control client (status $RB_STATUS)" \
    || fail "a later call left $n control clients for one session"
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
  detach_mirror_workspaces "$sock" $(workspace_ids_from "$(cat "$o1")") $(workspace_ids_from "$(cat "$o2")") \
    $(workspace_ids_from "$(sed 's/^third([0-9]*): //' "$ARTIFACTS/A7-third.txt")")
  t "$sock" kill-server 2>/dev/null
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
  # announces it and waits for the scenario to release it. It logs every
  # argv it gets, so a run that never pauses shows what the CLI ran. The wait
  # is capped at 8 s, under the CLI's 10 s deadline for its tmux probe.
  local argv_log="$ADV_TMP_ROOT/a13-argv.log"; : > "$argv_log"
  local pause
  make_fake pause <<EOF
printf '%s | PATH=%s\n' "\$*" "\$PATH" >> "$argv_log"
"$REAL_TMUX" "\$@"; rc=\$?
case " \$* " in
  *" list-sessions "*|*" ls "*)
    if [ \$rc -ne 0 ]; then
      touch "$gate/paused"
      i=0; while [ ! -e "$gate/go" ] && [ \$i -lt 80 ]; do sleep 0.1; i=\$((i+1)); done
    fi ;;
esac
exit \$rc
EOF
  pause="$FAKE_DIR"
  local dir="$ADV_TMP_ROOT/a13"; mkdir -p "$dir"; chmod 700 "$dir"
  local sock="$dir/s" start="$ADV_TMP_ROOT/a13start"; mkdir -p "$start"
  track_server "$sock"
  # What the CLI's child will see: the resolver runs `/bin/sh` and starts with
  # `command -v tmux`, using the environment the CLI passes on.
  {
    echo "fake: $pause/tmux"; ls -l "$pause/tmux"; echo "--- fake body:"; cat "$pause/tmux"; echo "---"
    echo "as /bin/sh sees it with the CLI's PATH:"
    env PATH="$pause:/usr/bin:/bin" /bin/sh -c 'echo "PATH=$PATH"; echo "command -v tmux: $(command -v tmux)"'
  } > "$ARTIFACTS/A13-resolver-view.txt" 2>&1
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
    touch "$gate/go"; wait "$cpid"
    fail "the CLI never paused in a failing list-sessions; status $(cat "$ADV_TMP_ROOT/a13.rc" 2>/dev/null), output: $(head -c 300 "$ADV_TMP_ROOT/a13.out"); fake saw: $(tr '\n' ';' < "$argv_log" | head -c 600); resolver view: $(grep -E '^(PATH=|command -v)' "$ARTIFACTS/A13-resolver-view.txt" | tr '\n' ';')"
  fi
  cp "$argv_log" "$ARTIFACTS/A13-argv-race1.log" 2>/dev/null; : > "$argv_log"
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
    touch "$gate/go"; wait "$cpid"
    fail "the CLI never paused for race 2; status $(cat "$ADV_TMP_ROOT/a13b.rc" 2>/dev/null), output: $(head -c 300 "$ADV_TMP_ROOT/a13b.out"); fake saw: $(tr '\n' ';' < "$argv_log" | head -c 600)"
  fi
  cp "$argv_log" "$ARTIFACTS/A13-argv-race2.log" 2>/dev/null
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
# The app's descendants whose command line names one socket, as
# `pid ppid stat etime command` lines. Mirrors of other servers left by
# earlier attacks do not count.
app_procs_for_socket() {
  local p
  for p in $(descendants "$(app_pid)"); do
    ps -o pid=,ppid=,stat=,etime=,command= -p "$p" 2>/dev/null | grep -F -- "$1"
  done
}
no_app_procs_for_socket() { [ -z "$(app_procs_for_socket "$1")" ]; }

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
  if wait_until 15 no_app_procs_for_socket "$sock"; then
    pass "no process of the app is left waiting on the frozen server"
  else
    app_procs_for_socket "$sock" > "$ARTIFACTS/A15-left.txt"
    fail "$(grep -c . < "$ARTIFACTS/A15-left.txt") processes of the app still name the frozen server's socket: $(tr '\n' ';' < "$ARTIFACTS/A15-left.txt")"
  fi
  kill -CONT "$pid"
  t "$sock" kill-server 2>/dev/null
  assert_app_healthy
}

# ---- A16: the socket path changes hands after the attach --------------------------
# The boundary checks the socket when the RPC arrives, and again before each
# spawn. Each case attaches through a path the boundary accepts (since the
# review's S6 fix, a socket in a directory other users can write to is
# refused up front; A22 covers that). Then our socket is moved aside (our
# server keeps running on its open listening socket), another user's server
# appears at the same path, and cmux's client is detached from outside, so
# the app's reconnect spawns tmux against that path again.
#   (a) a private (0700) directory, made writable by others after the attach
#   (b) directly in root-owned, sticky /private/tmp: another user cannot
#       rename our socket, but can create a new one at the name once ours
#       is gone
a16_case() {
  local label="$1" sock="$2" after_attach="$3"
  "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s main || { fail "$label: could not start the server"; return; }
  track_server "$sock"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "$label: mirror did not attach: $RB_OUT"; return; }
  [ -n "$after_attach" ] && eval "$after_attach"
  local moved="$sock.moved"
  mv "$sock" "$moved"
  track_server "$moved"
  sudo -n -u nobody "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s theirs 2>/dev/null
  sudo -n chmod 777 "$sock" 2>/dev/null
  if [ ! -S "$sock" ]; then skip "$label: could not start the other user's server at $sock"; return; fi
  local c; c="$(t "$moved" list-clients -F '#{client_control_mode}:#{client_name}' | awk -F: '$1==1{print $2; exit}')"
  t "$moved" detach-client -t "$c"
  sleep 8
  [ "$(sudo -n -u nobody "$TMUX_BIN" -S "$sock" list-clients 2>/dev/null | grep -c .)" -eq 0 ] \
    && pass "$label: the reconnect never reached the other user's server" \
    || fail "$label: after the socket changed hands, the app's reconnect attached to another user's server"
  if wait_until 10 no_app_procs_for_socket "$sock"; then
    pass "$label: no reconnect loop against the foreign socket"
  else
    fail "$label: the app keeps processes going against the foreign socket (reconnect loop?): $(app_procs_for_socket "$sock" | tr '\n' ';')"
  fi
  printf '%s: %s\n' "$label" "$(state_json "$sock" main | head -c 600)" >> "$ARTIFACTS/A16-state.txt"
  sudo -n -u nobody "$TMUX_BIN" -S "$sock" kill-server 2>/dev/null
  sudo -n rm -f "$sock" 2>/dev/null
  local w; for w in $ids; do close_workspace "$w"; done
  t "$moved" kill-server 2>/dev/null
}

attack_A16() {
  require_feature || return
  if ! sudo -n true 2>/dev/null; then
    skip "needs passwordless sudo to start another user's server"; return
  fi
  local dir="$ADV_TMP_ROOT/a16"
  mkdir -p "$dir"; chmod 700 "$dir"
  # The other user also needs to reach the directory: ADV_TMP_ROOT is 0700 by mktemp.
  chmod 711 "$ADV_TMP_ROOT"
  a16_case "private directory made shared" "$dir/s" "chmod 777 '$dir'"
  chmod 700 "$dir"; chmod 700 "$ADV_TMP_ROOT"
  a16_case "sticky /private/tmp" "/private/tmp/cmuxadv-a16.$$.s" ""
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
  local wrapper
  make_fake stderrheld <<EOF
sleep 300 &
echo \$! >> "$FAKES/stderrheld.pids"
exec "$REAL_TMUX" "\$@"
EOF
  wrapper="$FAKE_DIR"
  : > "$FAKES/stderrheld.pids"
  run_bounded 60 env PATH="$wrapper:/usr/bin:/bin" "$(cli_path)" tmux-mirror --socket-path "$sock" --no-focus
  printf 'wrapper(%s after %ss): %s\n' "$RB_STATUS" "$RB_ELAPSED" "$RB_OUT" > "$ARTIFACTS/A21.txt"
  [ "$RB_STATUS" -ne 124 ] && pass "the CLI returned after ${RB_ELAPSED}s although a child held tmux's stderr" \
    || fail "the CLI waited 60 s for stderr to close after tmux had exited (it reads stderr to end-of-file)"
  local p; for p in $(cat "$FAKES/stderrheld.pids"); do kill "$p" 2>/dev/null; done
  t "$sock" kill-server 2>/dev/null
}

# ---- A22 (review S6): a socket in a directory other users can write to --------
# R20: the app connects only to a socket owned by the user. In a directory
# others can write to (mode 0777, no sticky bit) another user can rename their
# own socket into place after the ownership check, so the path must be refused
# outright. A socket directly in a root-owned sticky directory (/private/tmp)
# is safe, because the sticky bit stops other users renaming it.
attack_A22() {
  require_feature || return
  local dir="$ADV_TMP_ROOT/a22shared" sock out
  mkdir -p "$dir"; chmod 0777 "$dir"
  sock="$dir/s"
  "$TMUX_BIN" -S "$sock" -f /dev/null new-session -d -s main || { fail "could not start the server"; return; }
  track_server "$sock"
  run_bounded 20 rpc remote.tmux.mirror "$(local_params "$sock")"
  printf 'rpc(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A22.txt"
  [ "$RB_STATUS" -ne 124 ] && rpc_refused && ! mentions_ssh "$RB_OUT" \
    && pass "socket API: a socket in a directory others can write to is refused" \
    || fail "socket API: a socket in a mode-0777 directory was not refused: $RB_OUT"
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  printf 'cli(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A22.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] \
    && pass "CLI: a socket in a directory others can write to is refused ($(printf '%s' "$out" | head -1))" \
    || fail "CLI: a socket in a mode-0777 directory was not refused (status $RB_STATUS): $out"
  sleep 1
  no_control_clients "$sock" && pass "nothing attached to the socket in the shared directory" \
    || { fail "a control client attached through the shared directory"; rpc remote.tmux.detach "$(local_params "$sock" main)" >/dev/null 2>&1; }

  # Control: directly in root-owned, sticky /private/tmp, the same server mirrors.
  local safe="/private/tmp/cmuxadv-a22.$$.s"
  "$TMUX_BIN" -S "$safe" -f /dev/null new-session -d -s main && track_server "$safe"
  run_bounded 20 mirror_rpc "$safe"
  if [ "$RB_STATUS" -eq 0 ] && wait_until 10 has_control_client "$safe"; then
    pass "control: a socket directly in sticky, root-owned /private/tmp still mirrors"
    # shellcheck disable=SC2086
    detach_mirror_workspaces "$safe" $(workspace_ids_from "$RB_OUT")
  else
    fail "control: a socket directly in /private/tmp did not mirror (the check is too broad?): $RB_OUT"
  fi
  t "$safe" kill-server 2>/dev/null; rm -f "$safe"

  # The race itself, with a real second user when sudo allows: they keep
  # renaming a link to their socket over ours while we try to attach.
  if sudo -n true 2>/dev/null; then
    sudo -n -u nobody "$TMUX_BIN" -S "$dir/theirs" -f /dev/null new-session -d -s theirs 2>/dev/null
    sudo -n chmod 777 "$dir/theirs" 2>/dev/null
    if [ -S "$dir/theirs" ]; then
      ln -f "$sock" "$dir/ours"
      track_server "$dir/ours"
      ( i=0; while [ $i -lt 300 ]; do ln -f "$dir/ours" "$dir/.o"; mv -f "$dir/.o" "$sock"; i=$((i + 1)); done ) &
      local mine=$!
      sudo -n -u nobody /bin/sh -c "i=0; while [ \$i -lt 300 ]; do ln -f '$dir/theirs' '$dir/.t' && mv -f '$dir/.t' '$sock'; i=\$((i + 1)); done" 2>/dev/null &
      local theirs=$!
      local k w; for k in 1 2 3 4 5 6 7 8 9 10; do
        run_bounded 20 rpc remote.tmux.mirror "$(local_params "$sock")"
        for w in $(workspace_ids_from "$RB_OUT"); do close_workspace "$w"; done
      done
      wait "$mine" "$theirs" 2>/dev/null
      [ "$(sudo -n -u nobody "$TMUX_BIN" -S "$dir/theirs" list-clients 2>/dev/null | grep -c .)" -eq 0 ] \
        && pass "the swap race never attached to the other user's server" \
        || fail "the swap race attached cmux to the other user's server"
      sudo -n -u nobody "$TMUX_BIN" -S "$dir/theirs" kill-server 2>/dev/null
    else
      skip "could not start the other user's server for the swap race"
    fi
  else
    skip "swap race: needs passwordless sudo to act as a second user"
  fi
  chmod 0700 "$dir"
}

# ---- A23 (review B1): pasting an image into a local mirror never uses ssh -------
# R4 and R8: no ssh is involved, and a pasted image becomes a local path. The
# app is relaunched with ssh, scp and sftp traps first on its PATH and as the
# DEBUG ssh override; each trap only records that it ran.
attack_A23() {
  require_feature || return
  local trap="$ADV_TMP_ROOT/a23trap" calls="$ARTIFACTS/A23-ssh-calls.log" b
  mkdir -p "$trap"; : > "$calls"
  for b in ssh scp sftp; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$b" "$calls" > "$trap/$b"
    chmod 755 "$trap/$b"
  done
  local sock; sock="$(new_server a23)"
  RELAUNCHED=1
  relaunch_app "PATH=$trap:$(dirname "$TMUX_BIN"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    "CMUX_REMOTE_TMUX_SSH_FOR_TESTING=$trap/ssh" || { fail "could not relaunch the app with the ssh traps"; return; }
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach: $RB_OUT"; relaunch_app; RELAUNCHED=""; return; }
  local surface
  surface="$(rpc remote.tmux.pane_surfaces "$(local_params "$sock" main)" 2>/dev/null | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
d = d.get("result", d)
panes = d.get("panes") or []
print(panes[0].get("surface_id", "") if panes else "")
')"
  if [ -z "$surface" ]; then
    fail "no surface found for the mirrored pane"
  else
    # The drop RPC resolves surfaces only in the selected workspace of the
    # active window (Q-A11), and the mirror was attached without focus. As in
    # track B's T8 (c7a67052986): select the mirror's workspace with
    # workspace.select, and put the previous selection back afterwards.
    local first previous
    first="$(printf '%s\n' $ids | head -1)"
    previous="$(rpc workspace.current '{}' 2>/dev/null | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
d = d.get("result", d)
print(d.get("workspace_id") or "")
')"
    run_bounded 10 rpc workspace.select "{\"workspace_id\":\"$first\"}"
    printf 'previous=%s select(%s): %s\n' "$previous" "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A23.txt"
    local image="$ADV_TMP_ROOT/a23 paste me.png"
    python3 -I -c 'import base64, sys; open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))' "$image"
    local params
    params="$(python3 -I -c 'import json, sys; print(json.dumps({"surface_id": sys.argv[1], "paths": [sys.argv[2]], "route": "terminal", "payload": "image"}))' "$surface" "$image")"
    run_bounded 20 rpc debug.terminal.simulate_file_drop "$params"
    printf 'drop(%s): %s\n' "$RB_STATUS" "$RB_OUT" >> "$ARTIFACTS/A23.txt"
    printf '%s' "$RB_OUT" | grep -qi 'not.found' \
      && fail "the drop RPC still could not find the mirror pane's surface after selecting its workspace: $RB_OUT"
    # R8 asks for a local file path. The app may insert a local copy of the
    # image (for example under $TMPDIR as clipboard-*.png) rather than the
    # dropped path, so, as T8 does, accept any image path in the pane that
    # names an existing local file.
    local found="" i=0
    while [ "$i" -lt 50 ] && [ -z "$found" ]; do
      t "$sock" capture-pane -p -J -t main > "$ARTIFACTS/A23-pane.txt" 2>/dev/null
      found="$(python3 -I -c '
import os, re, sys
text = open(sys.argv[1], errors="replace").read()
pattern = re.compile(r"(/(?:[^\s\x27\"\\]|\\.)+\.(?:png|jpe?g|tiff?|heic|gif))", re.IGNORECASE)
for match in pattern.findall(text):
    path = match.replace("\\", "")
    if os.path.isfile(path):
        print(path)
        break
' "$ARTIFACTS/A23-pane.txt")"
      sleep 0.2; i=$((i + 1))
    done
    [ ! -s "$calls" ] && pass "no ssh, scp or sftp ran for the paste" \
      || fail "the paste ran ssh tools on a local mirror: $(tr '\n' ';' < "$calls")"
    [ -n "$found" ] && pass "the pane received a local image path (R8): $found" \
      || fail "the pane received no existing local image path within 10 s (drop reply: $RB_OUT; pane: $(grep -v '^[[:space:]]*$' "$ARTIFACTS/A23-pane.txt" | tr '\n' ';' | head -c 300))"
    [ -n "$previous" ] && [ "$previous" != "$first" ] && rpc workspace.select "{\"workspace_id\":\"$previous\"}" >/dev/null 2>&1
  fi
  local w; for w in $ids; do close_workspace "$w"; done
  t "$sock" kill-server 2>/dev/null
  relaunch_app || fail "could not relaunch the app normally"
  RELAUNCHED=""
}

# ---- A24 (review S1): a refused command leaves no tmux server or session -------
# D7 lets the CLI start a server for a plain mirror. A command that then fails
# must not leave one behind: with the remote tmux beta off, and for
# `attach <session>` naming a session that does not exist.
attack_A24() {
  require_feature || return
  local dir="$ADV_TMP_ROOT/a24" sock out
  mkdir -p "$dir"; chmod 700 "$dir"; sock="$dir/s"
  defaults write "$APP_BUNDLE_ID" remoteTmux.beta.enabled -bool false
  run_bounded 20 mirror_cli "$sock"; out="$RB_OUT"
  enable_betas
  printf 'beta-off(%s): %s\n' "$RB_STATUS" "$out" > "$ARTIFACTS/A24.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && pass "beta off: refused ($(printf '%s' "$out" | head -1))" \
    || fail "beta off: status $RB_STATUS: $out"
  if server_alive "$sock"; then
    fail "beta off: the CLI left a tmux server behind, with sessions: $(t "$sock" list-sessions -F '#{session_name}' | tr '\n' ' ')"
    t "$sock" kill-server
  else
    pass "beta off: no tmux server was started"
  fi
  run_bounded 20 cli tmux-mirror attach no-such-session --socket-path "$sock" --no-focus; out="$RB_OUT"
  printf 'attach-missing-no-server(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A24.txt"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && pass "attach to a missing session with no server: refused" \
    || fail "attach to a missing session with no server: status $RB_STATUS: $out"
  if server_alive "$sock"; then
    fail "attach to a missing session left a tmux server behind, with sessions: $(t "$sock" list-sessions -F '#{session_name}' | tr '\n' ' ')"
    t "$sock" kill-server
  else
    pass "attach to a missing session with no server: no server was started"
  fi
  local sock2 before after
  sock2="$(new_server a24b)"
  before="$(t "$sock2" list-sessions 2>/dev/null | grep -c .)"
  run_bounded 20 cli tmux-mirror attach no-such-session --socket-path "$sock2" --no-focus; out="$RB_OUT"
  printf 'attach-missing-with-server(%s): %s\n' "$RB_STATUS" "$out" >> "$ARTIFACTS/A24.txt"
  after="$(t "$sock2" list-sessions 2>/dev/null | grep -c .)"
  ended_cleanly && [ "$RB_STATUS" -ne 0 ] && pass "attach to a missing session on a running server: refused" \
    || fail "attach to a missing session on a running server: status $RB_STATUS: $out"
  [ "$after" -eq "$before" ] && pass "and no session was added ($after)" \
    || fail "a failed attach added sessions ($before -> $after)"
  t "$sock2" kill-server 2>/dev/null
}

# ---- A25 (review S3): a session created from cmux's UI starts in $HOME ---------
# D7: a session the app creates uses -c $HOME, because the app has no caller
# directory and its own working directory means nothing to the user. With
# "New Workspace on the remote host" on and a mirror workspace selected, New
# Workspace (cmd+n) creates a tmux session on that server.
attack_A25() {
  require_feature || return
  local key="remoteTmux.beta.newWorkspaceOnHost.enabled"
  local prior; prior="$(defaults read "$APP_BUNDLE_ID" "$key" 2>/dev/null)"
  defaults write "$APP_BUNDLE_ID" "$key" -bool true
  local sock; sock="$(new_server a25)"
  run_bounded 30 mirror_rpc "$sock"
  local ids; ids="$(workspace_ids_from "$RB_OUT")"
  wait_until 10 has_control_client "$sock" || { fail "mirror did not attach: $RB_OUT"; return; }
  local first; first="$(printf '%s\n' $ids | head -1)"
  cli workspace select --workspace "$first" >/dev/null 2>&1
  local before; before="$(t "$sock" list-sessions -F '#{session_name}' 2>/dev/null | sort)"
  run_bounded 10 rpc debug.shortcut.simulate '{"combo":"cmd+n"}'
  printf 'shortcut(%s): %s\n' "$RB_STATUS" "$RB_OUT" > "$ARTIFACTS/A25.txt"
  local new="" i=0
  while [ "$i" -lt 100 ] && [ -z "$new" ]; do
    new="$(comm -13 <(printf '%s\n' "$before") <(t "$sock" list-sessions -F '#{session_name}' 2>/dev/null | sort) | head -1)"
    sleep 0.1; i=$((i + 1))
  done
  if [ -z "$new" ]; then
    skip "New Workspace on a selected mirror created no tmux session through debug.shortcut.simulate, so the start directory could not be checked (see A25.txt)"
  else
    local spath ppath
    spath="$(t "$sock" display-message -p -t "$new" '#{session_path}' 2>/dev/null)"
    ppath="$(t "$sock" display-message -p -t "$new" '#{pane_current_path}' 2>/dev/null)"
    printf 'new session %s: session_path=%s pane_current_path=%s HOME=%s\n' "$new" "$spath" "$ppath" "$HOME" >> "$ARTIFACTS/A25.txt"
    [ "$spath" != "/" ] && [ "$ppath" != "/" ] && pass "the session made from cmux's UI did not start in /" \
      || fail "the session made from cmux's UI started in / (session_path=$spath, pane=$ppath)"
    [ "$spath" = "$HOME" ] && pass "it started in \$HOME, as D7 says" \
      || fail "it started in '$spath', not \$HOME ($HOME)"
  fi
  if [ -n "$prior" ]; then defaults write "$APP_BUNDLE_ID" "$key" -bool "$([ "$prior" = 1 ] && echo true || echo false)"
  else defaults delete "$APP_BUNDLE_ID" "$key" 2>/dev/null; fi
  local w; for w in $ids; do close_workspace "$w"; done
  t "$sock" kill-server 2>/dev/null
}

# ---- run -------------------------------------------------------------------------
log "tmux: $("$TMUX_BIN" -V 2>/dev/null); old tmux: $([ -x "$TMUX_OLD_BIN" ] && "$TMUX_OLD_BIN" -V)"
enable_betas
FEATURE=0
if ensure_app; then
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
