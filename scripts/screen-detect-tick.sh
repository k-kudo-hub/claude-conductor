#!/bin/bash
# Claude Conductor - Screen Detection Tick
# CLI entry point for screen_detect_lib's per-poll observation, so the
# dashboard can drive it without sourcing the library itself.
#
# Usage: screen-detect-tick.sh <zellij-session>

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# shellcheck source=scripts/screen-detect-lib.sh
. "$CONDUCTOR_HOME/scripts/screen-detect-lib.sh"

screen_detect_tick "${1:-${ZELLIJ_SESSION_NAME:-unknown}}" 2>/dev/null
