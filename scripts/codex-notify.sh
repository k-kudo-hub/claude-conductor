#!/bin/bash
# Claude Conductor - Codex Notify Bridge
# Registered as `notify` in ~/.codex/config.toml (user-global; codex ignores
# project-local notify). Codex appends a JSON payload as the LAST argument on
# agent-turn-complete and runs this as a child of the codex process, so the
# task tab's TASK_TAB_NAME / TASK_TYPE / ZELLIJ_SESSION_NAME env is inherited.
#
# Translates the event into the same pending-file shape pending-notify.sh
# writes for a Stop hook, so Dashboard / Waiting / Done work for codex tasks
# unchanged. Codex has no Notification / UserPromptSubmit equivalents; those
# lifecycle points are covered by screen detection (screen-detect-lib.sh,
# issue #28), which surfaces approval waits and clears entries when the turn
# visibly resumes.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

PAYLOAD="${@: -1}"
if [ -z "$PAYLOAD" ]; then
    exit 0
fi

TYPE=$(echo "$PAYLOAD" | jq -r '.type // empty' 2>/dev/null)
if [ "$TYPE" != "agent-turn-complete" ]; then
    exit 0
fi

THREAD_ID=$(echo "$PAYLOAD" | jq -r '."thread-id" // empty' 2>/dev/null)
if [ -z "$THREAD_ID" ]; then
    exit 0
fi

DIR=$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)
MESSAGE=$(echo "$PAYLOAD" | jq -r '."last-assistant-message" // "Task complete"' 2>/dev/null)
TASK_TYPE="${TASK_TYPE:-}"

TAB_NAME="${TASK_TAB_NAME:-$(basename "$DIR")}"
if [ -z "$TAB_NAME" ]; then
    TAB_NAME="unknown"
fi

# Rollout transcript for this thread. Newer codex records the path in the
# versioned state DB (threads.rollout_path); older versions only leave the
# file under sessions/. Both lookups are best-effort.
TRANSCRIPT_PATH=""
STATE_DB=$(ls "$CODEX_HOME"/state_*.sqlite 2>/dev/null | sort -t_ -k2 -n | tail -1)
if [ -n "$STATE_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    TRANSCRIPT_PATH=$(sqlite3 -cmd '.timeout 200' "$STATE_DB" \
        "SELECT rollout_path FROM threads WHERE id='$THREAD_ID' LIMIT 1" 2>/dev/null)
fi
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_PATH=$(find "$CODEX_HOME/sessions" -type f -name "*${THREAD_ID}.jsonl" 2>/dev/null | head -1)
fi
if [ -n "$TRANSCRIPT_PATH" ] && [ ! -f "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_PATH=""
fi

# Keep the task registry current for restart restore (issue #36), guarded to
# conductor task tabs like pending-notify.sh.
if [ -n "$ZELLIJ_SESSION_NAME" ] && [ -n "$TASK_TAB_NAME" ]; then
    # shellcheck source=scripts/registry-lib.sh
    . "${CONDUCTOR_HOME:-$HOME/.claude-conductor}/scripts/registry-lib.sh"
    registry_upsert "$SESSION_NAME" "$THREAD_ID" "$TAB_NAME" \
        "$DIR" "$TASK_TYPE" "${TASK_AGENT:-codex}" "$TRANSCRIPT_PATH"
fi

mkdir -p "$PENDING_DIR"
PENDING_FILE="$PENDING_DIR/${THREAD_ID}.json"

# Don't clobber a Waiting entry: the task is parked on an external response
# and a completed turn must not pull it back onto the dashboard.
if [ -f "$PENDING_FILE" ]; then
    EXISTING_EVENT=$(jq -r '.event' "$PENDING_FILE" 2>/dev/null)
    if [ "$EXISTING_EVENT" = "Waiting" ]; then
        exit 0
    fi
fi

jq -n \
    --arg tab "$TAB_NAME" \
    --arg session "$SESSION_NAME" \
    --arg claude_session_id "$THREAD_ID" \
    --arg message "$MESSAGE" \
    --arg time "$(date '+%H:%M:%S')" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg dir "$DIR" \
    --arg task_type "$TASK_TYPE" \
    --arg agent "${TASK_AGENT:-codex}" \
    '{tab: $tab, session: $session, claude_session_id: $claude_session_id, message: $message, event: "Stop", time: $time, agent: $agent}
     + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
     + (if $dir != "" then {dir: $dir} else {} end)
     + (if $task_type != "" then {task_type: $task_type} else {} end)' \
    > "$PENDING_FILE"
