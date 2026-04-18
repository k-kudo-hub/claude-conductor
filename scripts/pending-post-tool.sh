#!/bin/bash
# Claude Conductor - PostToolUse Hook
# Resolves Notification pending after permission approval.
# Stop pending is left untouched (resolved by UserPromptSubmit).

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

STDIN_DATA=$(cat)

CLAUDE_SESSION_ID=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$CLAUDE_SESSION_ID" ]; then
    exit 0
fi

PENDING_FILE="$PENDING_DIR/${CLAUDE_SESSION_ID}.json"
if [ ! -f "$PENDING_FILE" ]; then
    exit 0
fi

EXISTING_EVENT=$(jq -r '.event' "$PENDING_FILE" 2>/dev/null)
if [ "$EXISTING_EVENT" != "Notification" ]; then
    exit 0
fi

rm -f "$PENDING_FILE"

if [ -n "$ZELLIJ_SESSION_NAME" ]; then
    zellij action go-to-tab-name "Main" 2>/dev/null
fi
