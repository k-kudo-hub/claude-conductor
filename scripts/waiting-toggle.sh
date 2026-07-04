#!/bin/bash
# Claude Conductor - Waiting Toggle
# Toggles a task's Waiting state. Entering Waiting saves the current event
# (Notification or Stop) into prev_event; resuming restores it (default
# Notification), so a completed (Stop/done) task returns to done, not to
# an unhandled Notification. Called from task-control.sh (w key).
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

tmp=$(mktemp)
if [[ "$CURRENT" == "Waiting" ]]; then
    # Resume: restore the event we saved when entering Waiting (default Notification)
    FILTER='.event = (.prev_event // "Notification") | del(.prev_event) | .time = $time'
    JQ_ARGS=(--arg time "$(date '+%H:%M:%S')")
else
    # Enter Waiting: remember the current event so we can restore it on resume
    FILTER='.prev_event = .event | .event = "Waiting" | .time = $time'
    JQ_ARGS=(--arg time "$(date '+%H:%M:%S')")
fi

if jq "${JQ_ARGS[@]}" "$FILTER" "$TARGET" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$TARGET"
else
    rm -f "$tmp"
fi
