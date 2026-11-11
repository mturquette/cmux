#!/bin/bash
# ============================================================================
# Live requirements tests for `cmux tmux-mirror`, the local tmux transport (issue #38854).
#
# Runs tests T1-T20 from the design's test plan against a running tagged dev build and against
# tmux servers this script starts itself, each on its own `-S` socket under a private directory
# in /tmp. It never touches the default tmux server or any server it did not start, and it
# removes TMUX, TMUX_PANE and TMUX_TMPDIR from everything it runs.
#
# The tests observe public surfaces only: the CLI's output and exit status, control-socket
# replies, the mirrored workspaces, tabs and splits as the socket reports them, and tmux state.
# scripts/remote_tmux_local/REQUIREMENTS.md maps each requirement to its test.
#
# Each test ends as PASS, FAIL, NOT-IMPLEMENTED (the build lacks the feature the test needs,
# which is the expected result on a main without the local transport) or SKIP (cannot run here,
# with the reason; a skip never counts as a pass). Several tests relaunch the tagged app with a
# test environment; the app is always restored to its base environment before the script exits.
#
# Prerequisites: the tagged app built with `./scripts/reload.sh --tag <tag>` and running, tmux
# 3.2 or later, and python3. The script turns the remote tmux beta on for the tagged bundle id.
#
# Usage:
#   CMUX_TAG=<tag> [TMUX_BIN=/path/to/tmux] scripts/remote-tmux-local-conformance.sh \
#     [--artifacts <dir>] [--only T1,T3] [--leak-cycles 50] [--list]
#
# Exit status: the number of FAIL and NOT-IMPLEMENTED tests (0 = every requirement holds),
# 2 for a usage error.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
unset TMUX TMUX_PANE TMUX_TMPDIR
if [ "${1:-}" != "--list" ] && [ -z "${CMUX_TAG:-}" ]; then
  echo "CMUX_TAG is required: the tag of a running tagged dev build" >&2
  exit 2
fi
PYTHON="${PYTHON:-$(command -v python3 || true)}"
[ -n "$PYTHON" ] || { echo "python3 is required" >&2; exit 2; }
exec "$PYTHON" scripts/remote_tmux_local/conformance.py "$@"
