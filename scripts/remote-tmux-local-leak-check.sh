#!/bin/bash
# ============================================================================
# Leak check for the local tmux mirror (R17, DESIGN.md T16 and A6).
#
# Attaches a mirror of a private tmux server and detaches it, N times, through
# the socket API, and requires that afterwards:
#   - the app's open file descriptor count (lsof -p) is back at its baseline;
#   - the app's child process count, and its tmux or script descendants, are
#     back at their baseline;
#   - the app has no zombie children;
#   - the server has no control client left attached, and its session still
#     runs (closing a mirror never kills the session, R7).
#
# The baseline is taken after two warm-up cycles, because the first attach
# loads code and opens caches that stay open for the life of the app.
#
# Usage: CMUX_TAG=<tag> scripts/remote-tmux-local-leak-check.sh
#          [--cycles N] [--race N] [--artifacts DIR]
#   --cycles  sequential attach and detach cycles (default 50, R17)
#   --race    extra cycles where detach is sent while the attach is still in
#             flight (default 0; the adversarial suite runs A6 with 200)
# Exit status: the number of failed checks (0 means clean). Runs only in the
# test VM, through check.sh's "leaks" stage.
# ============================================================================
set -uo pipefail
source "$(dirname "$0")/remote-tmux-local-adversarial-lib.sh"

CYCLES=50
RACE=0
ARTIFACTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cycles) CYCLES="$2"; shift 2 ;;
    --race) RACE="$2"; shift 2 ;;
    --artifacts) ARTIFACTS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ARTIFACTS" ] || ARTIFACTS="$ADV_TMP_ROOT/artifacts"
mkdir -p "$ARTIFACTS"
trap adv_cleanup EXIT
CURRENT_ID="R17"

enable_betas
if ! ensure_app; then
  fail "the tagged app ($TAG) is not answering on $APP_SOCKET"
  summary; exit "$FAILURES"
fi
if ! feature_present; then
  fail "this build has no 'cmux tmux-mirror' command, so the local transport cannot be leak-checked"
  summary; exit "$FAILURES"
fi

PID="$(app_pid)"
SOCK="$(new_server leak)" || { fail "could not start a private tmux server"; summary; exit "$FAILURES"; }
t "$SOCK" split-window -t main >/dev/null 2>&1
t "$SOCK" new-window -t main >/dev/null 2>&1

# One attach and detach. Returns non-zero if either half did not happen.
cycle() {
  local reply ids
  reply="$(mirror_rpc "$SOCK" 2>&1)" || { printf '%s\n' "$reply" >> "$ARTIFACTS/cycle-errors.log"; return 1; }
  ids="$(workspace_ids_from "$reply")"
  [ -n "$ids" ] || { printf 'no workspace_ids: %s\n' "$reply" >> "$ARTIFACTS/cycle-errors.log"; return 1; }
  wait_until 10 has_control_client "$SOCK" || return 1
  # shellcheck disable=SC2086
  detach_mirror_workspaces "$SOCK" $ids
}

# A racing cycle: start the attach, and close whatever it opened without
# waiting for it to settle; also send the detach RPC while the attach runs.
race_cycle() {
  local out="$ADV_TMP_ROOT/race.$1"
  ( mirror_rpc "$SOCK" > "$out" 2>&1 ) &
  local apid=$!
  rpc remote.tmux.detach "$(local_params "$SOCK" main)" >/dev/null 2>&1
  wait "$apid"
  local ids; ids="$(workspace_ids_from "$(cat "$out")")"
  local w; for w in $ids; do close_workspace "$w"; done
  rm -f "$out"
}

snapshot() {
  printf 'fds=%s children=%s tmux_desc=%s zombies=%s clients=%s\n' \
    "$(fd_count "$PID")" "$(pgrep -P "$PID" | grep -c .)" "$(tmux_descendant_count "$PID")" \
    "$(zombie_children "$PID")" "$(control_clients "$SOCK")"
}

log "warm-up"
cycle || info "a warm-up cycle failed; see cycle-errors.log"
cycle || true
wait_until 10 no_control_clients "$SOCK"
BASE_FDS="$(fd_count "$PID")"
BASE_CHILDREN="$(pgrep -P "$PID" | grep -c .)"
BASE_TMUX="$(tmux_descendant_count "$PID")"
lsof -p "$PID" > "$ARTIFACTS/lsof-baseline.txt" 2>/dev/null
log "baseline: $(snapshot)"

failed_cycles=0
i=1
while [ "$i" -le "$CYCLES" ]; do
  cycle || failed_cycles=$((failed_cycles + 1))
  [ $((i % 10)) -eq 0 ] && log "cycle $i: $(snapshot)"
  i=$((i + 1))
done
i=1
while [ "$i" -le "$RACE" ]; do
  race_cycle "$i"
  [ $((i % 25)) -eq 0 ] && log "race $i: $(snapshot)"
  i=$((i + 1))
done
wait_until 15 no_control_clients "$SOCK"

# Descriptors can take a moment to close after the last detach; allow ten
# seconds for every count to settle before judging.
settled() {
  [ "$(fd_count "$PID")" -le "$BASE_FDS" ] \
    && [ "$(pgrep -P "$PID" | grep -c .)" -le "$BASE_CHILDREN" ] \
    && [ "$(tmux_descendant_count "$PID")" -le "$BASE_TMUX" ]
}
wait_until 10 settled
lsof -p "$PID" > "$ARTIFACTS/lsof-after.txt" 2>/dev/null
log "after: $(snapshot)"

[ "$failed_cycles" -eq 0 ] && pass "all $CYCLES cycles attached and detached" \
  || fail "$failed_cycles of $CYCLES cycles did not attach or detach (see cycle-errors.log)"
fds="$(fd_count "$PID")"
[ "$fds" -le "$BASE_FDS" ] && pass "descriptors back at baseline ($fds <= $BASE_FDS)" \
  || fail "descriptors grew from $BASE_FDS to $fds; diff lsof-baseline.txt lsof-after.txt"
kids="$(pgrep -P "$PID" | grep -c .)"
[ "$kids" -le "$BASE_CHILDREN" ] && pass "child processes back at baseline ($kids)" \
  || fail "child processes grew from $BASE_CHILDREN to $kids"
td="$(tmux_descendant_count "$PID")"
[ "$td" -le "$BASE_TMUX" ] && pass "no tmux or script descendants left ($td)" \
  || fail "$td tmux or script descendants remain (baseline $BASE_TMUX)"
z="$(zombie_children "$PID")"
[ "$z" -eq 0 ] && pass "no zombie children" || fail "$z zombie children"
no_control_clients "$SOCK" && pass "no control client left attached" \
  || fail "$(control_clients "$SOCK") control clients still attached"
server_alive "$SOCK" && pass "the session survived every detach" || fail "the tmux session is gone"
diff <(awk '{print $4, $5, $9}' "$ARTIFACTS/lsof-baseline.txt" | sort) \
     <(awk '{print $4, $5, $9}' "$ARTIFACTS/lsof-after.txt" | sort) > "$ARTIFACTS/lsof-diff.txt"

summary
exit "$FAILURES"
