#!/bin/bash
# Claude Conductor - Task Registry Library
# Persistent per-task records used to restore tasks after the zellij session
# dies (issue #36). Unlike pending files (which exist only while a task waits
# for the user), registry entries live for the task's whole lifetime: hooks
# upsert them on every event, task deletion removes them.
# Layout: $CONDUCTOR_HOME/tasks/<zellij-session>/<agent-session-id>.json
# Sourced by hooks and restore-session.sh; defines functions only.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

registry_dir() {
    echo "$CONDUCTOR_HOME/tasks/$1"
}

# registry_upsert <session> <sid> <tab> <dir> <task_type> <agent> <transcript_path>
# Creates or overwrites the entry for (session, sid). Empty optional fields are
# omitted so readers can keep using plain `// empty` checks.
registry_upsert() {
    local session="$1" sid="$2" tab="$3" dir="$4" task_type="$5" agent="$6" transcript="$7"
    if [ -z "$session" ] || [ -z "$sid" ]; then
        return 0
    fi
    local rdir tmp
    rdir="$(registry_dir "$session")"
    mkdir -p "$rdir"
    # Write via temp file + move (repo convention) so a concurrent reader
    # never sees a half-written entry.
    tmp=$(mktemp)
    if jq -n \
        --arg tab "$tab" \
        --arg session "$session" \
        --arg claude_session_id "$sid" \
        --arg dir "$dir" \
        --arg task_type "$task_type" \
        --arg agent "$agent" \
        --arg transcript_path "$transcript" \
        --arg updated_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        '{tab: $tab, session: $session, claude_session_id: $claude_session_id, updated_at: $updated_at}
         + (if $dir != "" then {dir: $dir} else {} end)
         + (if $task_type != "" then {task_type: $task_type} else {} end)
         + (if $agent != "" then {agent: $agent} else {} end)
         + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)' \
        > "$tmp" 2>/dev/null; then
        mv "$tmp" "$rdir/$sid.json"
    else
        rm -f "$tmp"
    fi
}

# registry_remove <session> <sid>
registry_remove() {
    local session="$1" sid="$2"
    if [ -z "$session" ] || [ -z "$sid" ]; then
        return 0
    fi
    rm -f "$(registry_dir "$session")/$sid.json"
}

# registry_remove_by_tab <session> <tab>
# Removes every entry recorded for the tab. Used on deletion paths that have
# no pending file (and therefore no sid) to identify the task.
registry_remove_by_tab() {
    local session="$1" tab="$2" f t
    if [ -z "$session" ] || [ -z "$tab" ]; then
        return 0
    fi
    for f in "$(registry_dir "$session")"/*.json; do
        [ -f "$f" ] || continue
        t=$(jq -r '.tab // empty' "$f" 2>/dev/null)
        if [ "$t" = "$tab" ]; then
            rm -f "$f"
        fi
    done
}
