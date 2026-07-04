#!/bin/bash
# Claude Conductor - Restore a Done task back to the dashboard.
# Recreates the task's tab (resuming the previous Claude session when available)
# and marks the daily-log entry restored.
# Usage: restore-task.sh <tab> <session> <completed_at>
#
# Exit codes:
#   0  restored (tab recreated, daily entry marked)
#   1  invalid arguments / entry not found
#   2  entry has no recorded dir (older entry, cannot recreate the tab)

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# shellcheck source=scripts/task-lib.sh
source "$CONDUCTOR_HOME/scripts/task-lib.sh"

TAB="$1"
SESSION="$2"
COMPLETED_AT="$3"

if [ -z "$TAB" ] || [ -z "$SESSION" ] || [ -z "$COMPLETED_AT" ]; then
    exit 1
fi

# The entry lives in the daily log for its own session and completion date.
DATE="${COMPLETED_AT:0:10}"
DAILY_FILE="$CONDUCTOR_HOME/daily/$SESSION/$DATE.jsonl"

if [ ! -f "$DAILY_FILE" ]; then
    exit 1
fi

# Locate the matching, not-yet-restored entry.
ENTRY=$(jq -c --arg t "$TAB" --arg c "$COMPLETED_AT" \
    'select(.tab == $t and .completed_at == $c and (.restored // false) != true)' \
    "$DAILY_FILE" 2>/dev/null | head -1)

if [ -z "$ENTRY" ]; then
    exit 1
fi

DIR=$(echo "$ENTRY" | jq -r '.dir // empty')
TASK_TYPE=$(echo "$ENTRY" | jq -r '.task_type // empty')
CLAUDE_SESSION_ID=$(echo "$ENTRY" | jq -r '.claude_session_id // empty')
TRANSCRIPT_PATH=$(echo "$ENTRY" | jq -r '.transcript_path // empty')

# Without a working directory the tab cannot be recreated (entry predates dir recording).
if [ -z "$DIR" ]; then
    exit 2
fi

# Resume the previous conversation when its session is still available.
# Fall back to a fresh session if the id is unknown or its transcript is gone.
RESUME_ID=""
if [ -n "$CLAUDE_SESSION_ID" ]; then
    if [ -z "$TRANSCRIPT_PATH" ] || [ -f "$TRANSCRIPT_PATH" ]; then
        RESUME_ID="$CLAUDE_SESSION_ID"
    fi
fi

# Recreate the tab. A missing task_type falls back to no special layout.
create_task "$DIR" "$TASK_TYPE" "$TAB" "$RESUME_ID"

# Mark the entry restored (temp file + move, per repo convention).
TMP=$(mktemp)
jq -c --arg t "$TAB" --arg c "$COMPLETED_AT" \
    'if (.tab == $t and .completed_at == $c) then .restored = true else . end' \
    "$DAILY_FILE" > "$TMP" && mv "$TMP" "$DAILY_FILE"
