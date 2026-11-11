#!/bin/bash
# ============================================================================
# Shared helpers for the local tmux-mirror adversarial and leak scripts:
#   scripts/remote-tmux-local-adversarial.sh   (DESIGN.md section 5, A1-A14)
#   scripts/remote-tmux-local-leak-check.sh    (R17, A6)
#
# Sourced, never run. Everything here talks to the app only through public
# surfaces: the tagged CLI (`scripts/cmux-debug-cli.sh`), its `rpc` command,
# and tmux state on private servers that these scripts start themselves with
# an explicit `-S <socket>`. Nothing here reads or touches a tmux server the
# scripts did not start, and every server is killed on exit.
#
# Required environment: CMUX_TAG (a running tagged Debug app). Optional:
# TMUX_BIN (tmux used for private servers), TMUX_OLD_BIN (tmux 3.2a).
# Written for /bin/bash 3.2, which is what macOS ships.
# ============================================================================

ADV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Never inherit a tmux server from the environment; every scenario names its
# server with -S, and A11 sets these on purpose where it needs them.
unset TMUX TMUX_PANE TMUX_TMPDIR
TMUX_BIN="${TMUX_BIN:-$(command -v tmux || echo /opt/homebrew/bin/tmux)}"
TMUX_OLD_BIN="${TMUX_OLD_BIN:-/opt/tmux/3.2a/bin/tmux}"
TAG="${CMUX_TAG:?set CMUX_TAG=<tag> of a running tagged Debug app}"
TAG_SLUG="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
TAG_BUNDLE="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//')"
APP_BUNDLE_ID="com.cmuxterm.app.debug.${TAG_BUNDLE}"
APP_SOCKET="/tmp/cmux-debug-${TAG_SLUG}.sock"
APP_DERIVED="${CMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}}"
APP_PATH="${APP_DERIVED}/Build/Products/Debug/cmux DEV ${TAG_SLUG}.app"
APP_PROCESS_PATTERN="cmux DEV ${TAG_SLUG}.app/Contents/MacOS/"

# Private socket directories live under /tmp because a Unix socket path must
# fit in 104 bytes, which the artifacts directory does not guarantee.
ADV_TMP_ROOT="$(mktemp -d /tmp/cmuxadv.XXXXXX)"
# Servers are recorded in a file, not an array, because callers start them
# inside $(...) subshells, where an array update would be lost.
ADV_SERVERS_FILE="$ADV_TMP_ROOT/servers"
: > "$ADV_SERVERS_FILE"
FAILURES=0
SKIPS=0
PASSES=0
FAILED_IDS=()
CURRENT_ID=""

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { printf '  PASS %s: %s\n' "$CURRENT_ID" "$*"; PASSES=$((PASSES + 1)); }
fail() { printf '  FAIL %s: %s\n' "$CURRENT_ID" "$*"; FAILURES=$((FAILURES + 1)); FAILED_IDS+=("$CURRENT_ID"); }
# A skip is never a pass. It prints the reason and is counted separately.
skip() { printf '  SKIP %s: %s\n' "$CURRENT_ID" "$*"; SKIPS=$((SKIPS + 1)); }
info() { printf '  INFO %s: %s\n' "$CURRENT_ID" "$*"; }

# ---- process and time helpers ------------------------------------------------

# Runs a command with a wall-clock limit. Leaves its exit status in $RB_STATUS
# (124 when the limit killed it), combined output in $RB_OUT, elapsed seconds
# in $RB_ELAPSED. Kills the command's whole process group on timeout, so a
# hanging fake tmux cannot outlive the check.
run_bounded() {
  local limit="$1"; shift
  local out_file="$ADV_TMP_ROOT/rb.$$.$RANDOM"
  local start; start="$(date +%s)"
  set -m
  ( "$@" ) >"$out_file" 2>&1 &
  local pid=$!
  set +m
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 10)) ]; then
      kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      RB_STATUS=124
      RB_OUT="$(cat "$out_file")"
      RB_ELAPSED=$(( $(date +%s) - start ))
      rm -f "$out_file"
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
  RB_STATUS=$?
  RB_OUT="$(cat "$out_file")"
  RB_ELAPSED=$(( $(date +%s) - start ))
  rm -f "$out_file"
  return "$RB_STATUS"
}

# wait_until <seconds> <command...>: polls every 100 ms until the command
# succeeds. This is a test script observing an external system, so polling is
# the only option; product code never does this.
wait_until() {
  local limit="$1"; shift
  local i=0
  while [ "$i" -lt $((limit * 10)) ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  "$@" >/dev/null 2>&1
}

# ---- tmux private servers ------------------------------------------------------

# new_server <name> [tmux-binary]: starts a private server with one session
# called "main" and prints its socket path.
new_server() {
  local name="$1" bin="${2:-$TMUX_BIN}"
  local dir="$ADV_TMP_ROOT/$name"
  mkdir -p "$dir"; chmod 700 "$dir"
  local sock="$dir/s"
  "$bin" -S "$sock" -f /dev/null new-session -d -s main -x 160 -y 48 || return 1
  track_server "$sock" "$bin"
  printf '%s\n' "$sock"
}

# track_server <socket> [tmux-binary]: kill this server on exit.
track_server() { printf '%s|%s\n' "$1" "${2:-$TMUX_BIN}" >> "$ADV_SERVERS_FILE"; }

# t <socket> <tmux args...>: runs tmux against one private server.
t() { local sock="$1"; shift; "$TMUX_BIN" -S "$sock" "$@"; }

server_alive() { "$TMUX_BIN" -S "$1" list-sessions >/dev/null 2>&1; }

# Number of control-mode clients attached to a server (cmux's mirror client
# is a control client; nothing else these scripts start is, unless a scenario
# says so).
control_clients() {
  "$TMUX_BIN" -S "$1" list-clients -F '#{client_control_mode}' 2>/dev/null | grep -c '^1$'
}
no_control_clients() { [ "$(control_clients "$1")" -eq 0 ]; }
has_control_client() { [ "$(control_clients "$1")" -ge 1 ]; }

# Control clients attached to one session.
control_clients_on() {
  "$TMUX_BIN" -S "$1" list-clients -F '#{client_control_mode} #{session_name}' 2>/dev/null \
    | awk -v s="$2" '$1 == 1 { $1 = ""; sub(/^ /, ""); if ($0 == s) n++ } END { print n + 0 }'
}

kill_all_servers() {
  local entry sock bin
  while IFS= read -r entry; do
    sock="${entry%%|*}"; bin="${entry#*|}"
    "$bin" -S "$sock" kill-server >/dev/null 2>&1
  done < "$ADV_SERVERS_FILE"
}

adv_cleanup() {
  kill_all_servers
  # Directories a scenario made unreadable must be restored before removal.
  chmod -R u+rwx "$ADV_TMP_ROOT" 2>/dev/null
  rm -rf "$ADV_TMP_ROOT"
}

# ---- the app -------------------------------------------------------------------

cli() { CMUX_QUIET=1 CMUX_TAG="$TAG" "$ADV_REPO_ROOT/scripts/cmux-debug-cli.sh" "$@"; }

# rpc <method> <json>: raw v2 call. Output on stdout; status from the CLI.
rpc() { cli rpc "$1" "$2"; }

app_pid() { pgrep -f "$APP_PROCESS_PATTERN" | head -1; }
app_alive() { [ -n "$(app_pid)" ]; }

# Every descendant of a pid, one per line (not the pid itself).
descendants() {
  local kids k
  kids="$(pgrep -P "$1" 2>/dev/null)"
  for k in $kids; do
    printf '%s\n' "$k"
    descendants "$k"
  done
}
descendant_count() { descendants "$1" | grep -c .; }
tmux_descendant_count() {
  local p n=0
  for p in $(descendants "$1"); do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *tmux*|*script*) n=$((n + 1)) ;; esac
  done
  echo "$n"
}
zombie_children() { ps -axo ppid=,stat= 2>/dev/null | awk -v p="$1" '$1 == p && $2 ~ /Z/' | grep -c .; }
fd_count() { lsof -p "$1" 2>/dev/null | tail -n +2 | grep -c .; }
rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }

# In a subshell, so a liveness check never overwrites a caller's RB_* results.
app_responds() { ( run_bounded 10 cli ping ) >/dev/null 2>&1; }

enable_betas() {
  defaults write "$APP_BUNDLE_ID" remoteTmux.beta.enabled -bool true
}

app_executable() {
  local name
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
  [ -n "$name" ] && printf '%s\n' "$APP_PATH/Contents/MacOS/$name"
}

# Stops the tagged app and starts it again, optionally with extra environment
# (KEY=VALUE pairs) so a scenario can control what the app inherits.
#
# The app is started the way track B's harness and reload.sh start a tagged
# build: its executable directly, in its own process group, from an `env -i`
# base that carries the tag's socket settings. `open` would pass none of
# them, and without CMUX_SOCKET_* the app does not listen on the tagged socket.
relaunch_app() {
  local pid exe
  pid="$(app_pid)"
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null
    wait_until 15 bash -c "! kill -0 $pid 2>/dev/null" || kill -KILL "$pid" 2>/dev/null
  fi
  exe="$(app_executable)"
  [ -n "$exe" ] && [ -x "$exe" ] || { echo "relaunch_app: no executable under $APP_PATH" >&2; return 1; }
  local env_args=(
    "HOME=$HOME" "USER=${USER:-$(id -un)}" "LOGNAME=${USER:-$(id -un)}" "SHELL=${SHELL:-/bin/zsh}"
    "PATH=$(dirname "$TMUX_BIN"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=${TMPDIR:-/tmp}"
    "CMUX_TAG=$TAG_SLUG" "CMUX_BUNDLE_ID=$APP_BUNDLE_ID"
    "CMUX_SOCKET_ENABLE=1" "CMUX_SOCKET_MODE=allowAll" "CMUX_SOCKET_PATH=$APP_SOCKET"
    "CMUX_DEBUG_LOG=/tmp/cmux-debug-${TAG_SLUG}.log"
    "CMUX_BUNDLED_CLI_PATH=$APP_PATH/Contents/Resources/bin/cmux"
    "CMUX_SHELL_INTEGRATION_DIR=$APP_PATH/Contents/Resources/shell-integration"
    "CMUXD_UNIX_PATH=$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
    "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1"
    "CMUX_DEV_BACKEND_MODE=${CMUX_DEV_BACKEND_MODE:-local}"
  )
  # Scenario overrides come last, so they win.
  local kv; for kv in "$@"; do env_args+=("$kv"); done
  set -m
  ( exec env -i "${env_args[@]}" "$exe" < /dev/null >> "$ADV_TMP_ROOT/app-launch.log" 2>&1 ) &
  set +m
  disown 2>/dev/null
  wait_until 90 app_responds
}

# Starts the tagged app if it is not answering. check.sh's teardown stops the
# app after every single-stage run (Q-B8), so a stage run on its own finds none.
ensure_app() {
  app_responds && return 0
  [ -d "$APP_PATH" ] || return 1
  relaunch_app
}

# ---- the feature under test ------------------------------------------------------

# Whether this build has `cmux tmux-mirror` at all. On upstream main it does
# not, and every live check then fails with that reason: a missing feature is
# never reported as a pass.
feature_present() {
  # An unknown command's error also names "tmux-mirror", so require the
  # command's own usage line and a zero status.
  run_bounded 20 cli tmux-mirror --help >/dev/null 2>&1 || return 1
  case "$RB_OUT" in *"Usage: cmux tmux-mirror"*) return 0 ;; esac
  return 1
}

local_params() {
  # local_params <socket> [session] -> JSON params for the local transport.
  if [ -n "${2:-}" ]; then
    python3 -c 'import json,sys; print(json.dumps({"transport":"local","socket_path":sys.argv[1],"session":sys.argv[2]}))' "$1" "$2"
  else
    python3 -c 'import json,sys; print(json.dumps({"transport":"local","socket_path":sys.argv[1],"activate":False}))' "$1"
  fi
}

# mirror_rpc <socket>: attaches through the socket API. Prints the reply JSON.
mirror_rpc() { rpc remote.tmux.mirror "$(local_params "$1")"; }

# mirror_cli <socket> [args...]: attaches through the CLI, in the background focus mode.
mirror_cli() { local sock="$1"; shift; cli tmux-mirror --socket-path "$sock" --no-focus "$@"; }

state_json() { rpc remote.tmux.state "$(local_params "$1" "${2:-main}")" 2>/dev/null; }
state_field() {
  state_json "$1" "${3:-main}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
d = d.get("result", d)
v = d.get(sys.argv[1])
print("" if v is None else (json.dumps(v) if isinstance(v, (list, dict)) else v))
' "$2"
}
mirror_attached() { [ "$(state_field "$1" attached "${2:-main}")" = "True" ] && [ "$(state_field "$1" exited "${2:-main}")" != "True" ]; }
mirror_window_count() { state_field "$1" window_count "${2:-main}"; }
# Predicates for wait_until, which re-runs them on every poll.
window_count_is() { [ "$(mirror_window_count "$1" "${3:-main}")" = "$2" ]; }
output_changed() { [ "$(state_field "$1" "$2")" != "$3" ]; }
tree_contains() { cli tree --all 2>/dev/null | grep -qF -- "$1"; }
# A socket call was refused: non-zero status, or an error object in the reply.
rpc_refused() { [ "$RB_STATUS" -ne 0 ] || printf '%s' "$RB_OUT" | grep -qiE '"error"|^error'; }

# workspace_ids_from <reply-json>: the workspace UUIDs a mirror reply names.
workspace_ids_from() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
d = d.get("result", d)
for w in d.get("workspace_ids", []):
    print(w)
' "$1"
}

all_workspace_ids() {
  cli --id-format uuids tree --all --json 2>/dev/null | python3 -c '
import json, re, sys
text = sys.stdin.read()
for m in sorted(set(re.findall(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", text))):
    print(m.upper())
'
}
workspace_exists() { all_workspace_ids | grep -qix "$1"; }
workspace_gone() { ! workspace_exists "$1"; }

close_workspace() { cli workspace close --workspace "$1" >/dev/null 2>&1; }

# detach_all_mirrors <socket>: closes every workspace a mirror of this server
# opened, then waits for tmux to show no control client.
detach_mirror_workspaces() {
  local sock="$1"; shift
  local w
  for w in "$@"; do close_workspace "$w"; done
  wait_until 10 no_control_clients "$sock"
}

# mentions_ssh <text>: R6 says local failures never talk about SSH.
mentions_ssh() { printf '%s' "$1" | grep -qiE '(^|[^a-z])ssh([^a-z]|$)'; }

summary() {
  echo
  echo "passed: $PASSES  failed: $FAILURES  skipped: $SKIPS"
  [ "$FAILURES" -gt 0 ] && echo "failed checks: ${FAILED_IDS[*]}"
  return 0
}
