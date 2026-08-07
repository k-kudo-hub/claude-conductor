#!/bin/bash
# Claude Conductor - Restore tasks after a session restart (issue #36)
# Rebuilds task tabs from the task registry ($CONDUCTOR_HOME/tasks/<session>/),
# resuming each agent's previous conversation (claude --resume / codex resume)
# when its transcript is still on disk — herdr's "Native Agent Resume"
# equivalent. Runs inside the target zellij session (dashboard startup).
#
# Best-effort by design: a task that cannot be recreated is skipped with its
# entry kept for a later retry; an entry whose directory vanished is dropped.
# Always exits 0 so a failed restore never breaks the dashboard.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"

REG_DIR="$CONDUCTOR_HOME/tasks/$SESSION_NAME"
if [ ! -d "$REG_DIR" ]; then
    exit 0
fi
ls "$REG_DIR"/*.json >/dev/null 2>&1 || exit 0

# shellcheck source=scripts/task-lib.sh
source "$CONDUCTOR_HOME/scripts/task-lib.sh"
# shellcheck source=scripts/registry-lib.sh
source "$CONDUCTOR_HOME/scripts/registry-lib.sh"

EXISTING_TABS=$(zellij action query-tab-names 2>/dev/null)

RESTORED=0
# One candidate per tab, newest updated_at wins: a --resume restart changes
# the agent session id, so older entries for the same tab hold stale ids.
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    tab=$(echo "$entry" | jq -r '.tab // empty')
    dir=$(echo "$entry" | jq -r '.dir // empty')
    task_type=$(echo "$entry" | jq -r '.task_type // empty')
    agent=$(echo "$entry" | jq -r '.agent // empty')
    sid=$(echo "$entry" | jq -r '.claude_session_id // empty')
    transcript=$(echo "$entry" | jq -r '.transcript_path // empty')

    [ -n "$tab" ] || continue

    # Tab already present (live session, or restored moments ago): keep the
    # entry, nothing to rebuild.
    if printf '%s\n' "$EXISTING_TABS" | grep -Fxq "$tab"; then
        continue
    fi

    # No recorded dir, or it vanished (e.g. a closed worktree): there is
    # nowhere to recreate the task, so drop its entries.
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        registry_remove_by_tab "$SESSION_NAME" "$tab"
        continue
    fi

    # Resume only when the transcript is still on disk (no broken --resume).
    resume_id=""
    if [ -n "$sid" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
        resume_id="$sid"
    fi

    if create_task "$dir" "$task_type" "$tab" "$resume_id" "$agent"; then
        RESTORED=$((RESTORED + 1))
    fi
done <<EOF
$(for f in "$REG_DIR"/*.json; do
    # Validate per file: jq -s is all-or-nothing, and one corrupt entry
    # (e.g. truncated by a full disk) must not silently disable restore.
    jq -c . "$f" 2>/dev/null
done | jq -sc 'group_by(.tab) | map(max_by(.updated_at // "")) | .[]' 2>/dev/null)
EOF

# create_task leaves focus on the last recreated tab; end on the dashboard.
if [ "$RESTORED" -gt 0 ]; then
    zellij action go-to-tab-name "Main" 2>/dev/null
fi
exit 0
