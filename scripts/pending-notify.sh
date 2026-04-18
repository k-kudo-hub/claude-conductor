#!/bin/bash
# Claude Conductor - Notification/Stop Hook
# Records pending status to a file keyed by Claude Code session_id.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
mkdir -p "$PENDING_DIR"

STDIN_DATA=$(cat)

CLAUDE_SESSION_ID=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$CLAUDE_SESSION_ID" ]; then
    exit 0
fi

TAB_NAME="${TASK_TAB_NAME:-$(basename "$(echo "$STDIN_DATA" | jq -r '.cwd // empty' 2>/dev/null)")}"
if [ -z "$TAB_NAME" ]; then
    TAB_NAME="unknown"
fi

MESSAGE=$(echo "$STDIN_DATA" | jq -r '.message // "Needs attention"' 2>/dev/null)
HOOK_EVENT=$(echo "$STDIN_DATA" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$STDIN_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)

PENDING_FILE="$PENDING_DIR/${CLAUDE_SESSION_ID}.json"

# Don't overwrite a Notification pending with a Stop event
if [ -f "$PENDING_FILE" ] && [ "$HOOK_EVENT" = "Stop" ]; then
    EXISTING_EVENT=$(jq -r '.event' "$PENDING_FILE" 2>/dev/null)
    if [ "$EXISTING_EVENT" = "Notification" ]; then
        exit 0
    fi
fi

jq -n \
    --arg tab "$TAB_NAME" \
    --arg session "$SESSION_NAME" \
    --arg claude_session_id "$CLAUDE_SESSION_ID" \
    --arg message "$MESSAGE" \
    --arg event "$HOOK_EVENT" \
    --arg time "$(date '+%H:%M:%S')" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    '{tab: $tab, session: $session, claude_session_id: $claude_session_id, message: $message, event: $event, time: $time}
     + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)' \
    > "$PENDING_FILE"
