#!/bin/bash
# Claude Conductor - Restore a Done task back to the dashboard.
# Recreates the task's tab (resuming the previous Claude session when available)
# and marks the daily-log entry restored.
# Usage: restore-task.sh <tab> <session> <completed_at>
#
# Exit codes:
#   0  restored (tab recreated, daily entry marked)
#      create_task の rc=3（タブは出来たがフォーカス未確認でペイン未構築）も
#      ここに含める。タブとエージェントは動いており、Done に残すと再試行で
#      同名タブが二重に作られるため、復元成功として扱う。
#   1  invalid arguments / entry not found
#   2  entry has no recorded dir (older entry, cannot recreate the tab)
#   3  recorded dir no longer exists (e.g. the worktree was removed)
#   4  tab recreation failed (entry left in Done for retry)
#      タブがそもそも作られなかった場合のみ。
#   5  tab created but daily-log update failed (task may reappear in Done)

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# shellcheck source=scripts/task-lib.sh
source "$CONDUCTOR_HOME/scripts/task-lib.sh"
# shellcheck source=scripts/lock-lib.sh
source "$CONDUCTOR_HOME/scripts/lock-lib.sh"

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
AGENT=$(echo "$ENTRY" | jq -r '.agent // empty')

# Without a working directory the tab cannot be recreated (entry predates dir recording).
if [ -z "$DIR" ]; then
    exit 2
fi

# The working directory may have been removed since completion (e.g. a closed
# worktree). Don't mark the task restored when there is nowhere to recreate it.
if [ ! -d "$DIR" ]; then
    exit 3
fi

# Resume the previous conversation only for a real session id whose transcript
# is still on disk. An unknown session, a synthesized screen-<slug> id or a
# missing transcript all mean a fresh session (no broken --resume).
# See resume_session_id in task-lib.sh.
RESUME_ID=$(resume_session_id "$CLAUDE_SESSION_ID" "$TRANSCRIPT_PATH")

# Recreate the tab. A missing task_type falls back to no special layout;
# a missing agent falls back to the legacy single-agent path (claude).
# Only mark the entry restored if the tab was actually created, otherwise the
# task would vanish from the Done pane with no working tab to show for it.
# rc=3 は「タブは作られたが control ペインとレイアウトが未構築」。タブは存在する
# ので Done に残して再試行させると同名タブが増えるだけになる。復元済みとして進む。
create_task "$DIR" "$TASK_TYPE" "$TAB" "$RESUME_ID" "$AGENT"
CT_RC=$?
if [ "$CT_RC" -ne 0 ] && [ "$CT_RC" -ne 3 ]; then
    exit 4
fi
if [ "$CT_RC" -eq 3 ]; then
    echo "restore-task: tab '$TAB' restored without its control pane" >&2
fi

# Mark the entry restored (temp file + move, per repo convention).
# Flip only the first not-yet-restored match — (tab, completed_at) is not a
# unique key, and only one tab was recreated above.
# Hold the daily-log lock across the read-modify-rewrite so a concurrent
# record-output.sh append can't be clobbered by the mv.
DAILY_LOCK="$DAILY_FILE.lock"
LOCK_HELD=0
if acquire_lock "$DAILY_LOCK" 2; then
    LOCK_HELD=1
else
    echo "restore-task: proceeding without daily-log lock" >&2
fi
TMP=$(mktemp)
trap '[ "$LOCK_HELD" = 1 ] && release_lock "$DAILY_LOCK"; rm -f "$TMP"' EXIT

if jq -s -c --arg t "$TAB" --arg c "$COMPLETED_AT" \
    '(map(.tab == $t and .completed_at == $c and (.restored // false) != true) | index(true)) as $i
     | if $i == null then . else (.[$i] += {restored: true}) end
     | .[]' \
    "$DAILY_FILE" > "$TMP" && mv "$TMP" "$DAILY_FILE"; then
    exit 0
else
    exit 5
fi
