#!/bin/bash
# ============================================================================
# Benchmarks for `cmux tmux-mirror`, the local tmux transport (issue #38854).
#
#   T14 (R15)  Attach latency: a private server with --sessions sessions of --windows windows;
#              time from the mirror request until every session shows all its windows, median
#              of --runs runs, against --attach-limit-ms (the requirement: 1000 ms for 10 x 5).
#   T15 (R16)  Added input latency: --keystrokes characters typed into one pane through the
#              local mirror and through a plain tmux client in an ordinary cmux terminal; a
#              separate control-mode client timestamps each echo. The mirror's 95th percentile
#              minus the plain client's must stay within --added-p95-limit-ms (5 ms).
#
# Runs against a running tagged dev build and tmux servers this script starts on private
# sockets; it never touches the default tmux server. Results: <artifacts>/bench.json.
#
# Usage:
#   CMUX_TAG=<tag> [TMUX_BIN=/path/to/tmux] scripts/remote-tmux-local-bench.sh \
#     [--sessions 10] [--windows 5] [--runs 5] [--attach-limit-ms 1000] \
#     [--keystrokes 200] [--added-p95-limit-ms 5] [--only attach|input] [--artifacts <dir>]
#
# Exit status: 0 when both limits hold; otherwise the number of benchmarks that failed or could
# not run because the build has no local transport yet; 2 for a usage error.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
unset TMUX TMUX_PANE TMUX_TMPDIR
[ -n "${CMUX_TAG:-}" ] || { echo "CMUX_TAG is required: the tag of a running tagged dev build" >&2; exit 2; }
PYTHON="${PYTHON:-$(command -v python3 || true)}"
[ -n "$PYTHON" ] || { echo "python3 is required" >&2; exit 2; }
exec "$PYTHON" scripts/remote_tmux_local/bench.py "$@"
