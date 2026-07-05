#!/bin/bash
# Claude Conductor - Update Check
# On session start, compares the installed version with the latest remote tag
# and prints a one-line notice when a newer release exists. Best-effort:
# a disabled config, missing URL, or any network/parse failure exits silently
# and never blocks the session from starting.
#
# Usage: check-update.sh [--force]   (--force ignores the once-a-day cache)

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
# shellcheck source=/dev/null
source "$CONDUCTOR_HOME/scripts/update-lib.sh"

CACHE_FILE="$CONDUCTOR_HOME/.update-check"
TODAY=$(date '+%Y-%m-%d')

FORCE=0
[[ "$1" == "--force" ]] && FORCE=1

# Config toggle: update_check.enabled (default true when the key is absent).
# NOTE: do not use jq's `//` here — `false // true` returns true, so an
# explicit `enabled: false` would be ignored. Read the raw value instead.
config_file="$CONDUCTOR_HOME/config.json"
[ -f "$config_file" ] || config_file="$CONDUCTOR_HOME/config.default.json"
ENABLED=$(jq -r '.update_check.enabled' "$config_file" 2>/dev/null)
[[ "$ENABLED" == "false" ]] && exit 0

# Update source URL (recorded by install.sh). No URL -> nothing to check.
REPO_URL=""
[ -f "$CONDUCTOR_HOME/REPO_URL" ] && REPO_URL=$(cat "$CONDUCTOR_HOME/REPO_URL")
[ -n "$REPO_URL" ] || exit 0

# Once-a-day cache: reuse today's cached tag, else fetch and cache it.
LATEST=""
if [[ "$FORCE" -eq 0 ]] && [[ -f "$CACHE_FILE" ]]; then
    read -r CACHE_DATE CACHE_TAG < "$CACHE_FILE" 2>/dev/null
    [[ "$CACHE_DATE" == "$TODAY" ]] && LATEST="$CACHE_TAG"
fi

if [[ -z "$LATEST" ]]; then
    LATEST=$(uc_latest_tag "$REPO_URL") || exit 0
    echo "$TODAY $LATEST" > "$CACHE_FILE"
fi
[ -n "$LATEST" ] || exit 0

CURRENT=$(uc_current_version)

if uc_version_gt "$LATEST" "$CURRENT"; then
    echo ""
    echo "  📦 新しいバージョン $LATEST があります（現在: $CURRENT）。"
    echo "     'mdev update' で更新できます。"
    echo ""
    # Give the user a moment to read the notice before zellij takes the screen.
    # Skipped when stdout is not a terminal (e.g. under test capture).
    [ -t 1 ] && sleep 2
fi
exit 0
