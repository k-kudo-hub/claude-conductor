#!/bin/bash
# Claude Conductor - Waiting Toggle
# Toggles a task's pending status between Waiting and Notification.
# Called from task-control.sh (w key).
#
# Waiting represents a task blocked on an external response (e.g. PR review).
# It is separated from the Dashboard and shown in the Waiting pane instead.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
mkdir -p "$PENDING_DIR"

TAB_NAME="${1:-unknown}"

# Find an existing pending file for this tab
TARGET=""
for f in "$PENDING_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$TAB_NAME" ]]; then
        TARGET="$f"
        break
    fi
done

if [[ -n "$TARGET" ]]; then
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
else
    # No pending file yet: create a new Waiting entry keyed by sanitized tab name
    SAFE_TAB=$(printf '%s' "$TAB_NAME" | tr -c 'a-zA-Z0-9_-' '_')
    jq -n \
        --arg tab "$TAB_NAME" \
        --arg session "$SESSION_NAME" \
        --arg time "$(date '+%H:%M:%S')" \
        '{tab: $tab, session: $session, message: "Waiting for external response", event: "Waiting", time: $time}' \
        > "$PENDING_DIR/waiting-${SAFE_TAB}.json"
fi
