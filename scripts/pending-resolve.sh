#!/bin/bash
# Claude Conductor - UserPromptSubmit Hook
# Resolves pending status and returns to Main tab.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

STDIN_DATA=$(cat)

CLAUDE_SESSION_ID=$(echo "$STDIN_DATA" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$CLAUDE_SESSION_ID" ]; then
    exit 0
fi

PENDING_FILE="$PENDING_DIR/${CLAUDE_SESSION_ID}.json"
if [ -f "$PENDING_FILE" ]; then
    rm -f "$PENDING_FILE"
fi

if [ -n "$ZELLIJ_SESSION_NAME" ]; then
    zellij action go-to-tab-name "Main" 2>/dev/null
fi
