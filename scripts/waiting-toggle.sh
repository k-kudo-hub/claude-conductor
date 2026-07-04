#!/bin/bash
# Claude Conductor - Waiting Toggle
# Toggles a task's pending status between Waiting and Notification.
# Called from task-control.sh (w key).
#
# Waiting represents a task blocked on an external response (e.g. PR review).
# It is separated from the Dashboard and shown in the Waiting pane instead.
#
# Only tasks that already have a pending entry (i.e. Claude has fired a
# Notification or Stop hook) can be toggled. This keeps a single pending file
# per task keyed by Claude's session_id, so the existing resolve hooks continue
# to clean it up. If no pending entry exists yet, this is a no-op.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

TAB_NAME="${1:-unknown}"

# Find the existing pending file for this tab (no-op if there is none)
TARGET=""
for f in "$PENDING_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$TAB_NAME" ]]; then
        TARGET="$f"
        break
    fi
done

[[ -n "$TARGET" ]] || exit 0

CURRENT=$(jq -r '.event' "$TARGET" 2>/dev/null)
if [[ "$CURRENT" == "Waiting" ]]; then
    NEW_EVENT="Notification"
else
    NEW_EVENT="Waiting"
fi

tmp=$(mktemp)
if jq --arg event "$NEW_EVENT" --arg time "$(date '+%H:%M:%S')" \
    '.event = $event | .time = $time' "$TARGET" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$TARGET"
else
    rm -f "$tmp"
fi
