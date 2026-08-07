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

# The task keeps running after the user answers, so refresh its registry entry
# (issue #36). Guarded to conductor task tabs, same as pending-notify.sh.
if [ -n "$ZELLIJ_SESSION_NAME" ] && [ -n "$TASK_TAB_NAME" ]; then
    DIR=$(echo "$STDIN_DATA" | jq -r '.cwd // empty' 2>/dev/null)
    TRANSCRIPT_PATH=$(echo "$STDIN_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)
    # shellcheck source=scripts/registry-lib.sh
    . "${CONDUCTOR_HOME:-$HOME/.claude-conductor}/scripts/registry-lib.sh"
    registry_upsert "$SESSION_NAME" "$CLAUDE_SESSION_ID" "$TASK_TAB_NAME" \
        "$DIR" "${TASK_TYPE:-}" "${TASK_AGENT:-claude}" "$TRANSCRIPT_PATH"
fi

if [ -n "$ZELLIJ_SESSION_NAME" ]; then
    zellij action go-to-tab-name "Main" 2>/dev/null
fi
