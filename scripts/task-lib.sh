#!/bin/bash
# Claude Conductor - Task Library
# Shared functions for creating tasks (tabs) and applying layouts.
# Sourced by task-create-loop.sh and done-loop.sh; defines functions only.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

load_config() {
    local config_file="$CONDUCTOR_HOME/config.json"
    if [[ ! -f "$config_file" ]]; then
        config_file="$CONDUCTOR_HOME/config.default.json"
    fi
    echo "$config_file"
}

# Agent launch command. With a name, resolves config .agents.<name>.command
# (an unknown name falls back to the name itself as the command). Without a
# name, keeps the legacy .agent.command path. The value is a single string
# that callers word-split on purpose, so wrapper invocations like
# "fdev secrets exec my-header -- claude" work as-is.
agent_command() {
    local agent="$1" cmd
    if [[ -n "$agent" ]]; then
        cmd=$(jq -r --arg a "$agent" '.agents[$a].command // empty' "$(load_config)" 2>/dev/null)
        [[ -z "$cmd" ]] && cmd="$agent"
    else
        cmd=$(jq -r '.agent.command // empty' "$(load_config)" 2>/dev/null)
        [[ -z "$cmd" ]] && cmd="claude"
    fi
    echo "$cmd"
}

# Arguments inserted between the agent command and the session id when
# resuming. With a name, resolves config .agents.<name>.resume_args;
# without one, the legacy .agent.resume_args. Word-split like agent_command.
agent_resume_args() {
    local agent="$1" args
    if [[ -n "$agent" ]]; then
        args=$(jq -r --arg a "$agent" '.agents[$a].resume_args // empty' "$(load_config)" 2>/dev/null)
    else
        args=$(jq -r '.agent.resume_args // empty' "$(load_config)" 2>/dev/null)
    fi
    [[ -z "$args" ]] && args="--resume"
    echo "$args"
}

# Configured agent names (config .agents keys), one per line. Empty output
# means no named agents are configured and tasks use the legacy single-agent
# path.
agent_names() {
    jq -r '.agents // {} | keys_unsorted[]' "$(load_config)" 2>/dev/null
}

# State detection method for an agent: "hooks" (Claude Code lifecycle hooks
# own the pending files) or "screen" (issue #28: the dashboard polls the
# tab's screen and matches config .agents.<name>.patterns). Anything not
# explicitly configured as "screen" falls back to hooks so agent-less legacy
# tabs and unknown agents are never screen-scanned.
agent_detection() {
    local agent="$1" method=""
    if [[ -n "$agent" ]]; then
        method=$(jq -r --arg a "$agent" '.agents[$a].detection // empty' "$(load_config)" 2>/dev/null)
    fi
    [[ -z "$method" ]] && method="hooks"
    echo "$method"
}

# Screen-detection regexes (grep -E) for one state ("neutral" / "blocked" /
# "working"), one per line. Empty output means the agent defines no patterns
# for that state and it can never be classified as such.
agent_patterns() {
    local agent="$1" state="$2"
    [[ -z "$agent" ]] && return 0
    jq -r --arg a "$agent" --arg s "$state" \
        '.agents[$a].patterns[$s] // [] | .[]' "$(load_config)" 2>/dev/null
}

# Tab name -> filesystem-safe slug keying a tab's screen-detection files
# (pending + last-state). tr -c mangles multibyte names byte-wise, so two
# Japanese tab names would collide on the sanitized part alone — the cksum
# suffix keeps distinct names distinct.
_screen_tab_slug() {
    local safe hash
    safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
    hash=$(printf '%s' "$1" | cksum | awk '{print $1}')
    printf '%s-%s' "$safe" "$hash"
}

apply_layout() {
    local dir="$1"
    local type="$2"
    local config_file
    config_file=$(load_config)

    local steps
    steps=$(jq -c --arg t "$type" '.task_types[$t].layout[]' "$config_file" 2>/dev/null)

    if [[ -z "$steps" ]]; then
        return
    fi

    sleep 0.3

    while IFS= read -r step; do
        local action direction command
        action=$(echo "$step" | jq -r '.action')
        direction=$(echo "$step" | jq -r '.direction')
        command=$(echo "$step" | jq -r '.command // empty')

        case "$action" in
            new-pane)
                if [[ -n "$command" ]]; then
                    zellij action new-pane --direction "$direction" --cwd "$dir" -- "$command"
                else
                    zellij action new-pane --direction "$direction" --cwd "$dir"
                fi
                ;;
            move-focus)
                zellij action move-focus "$direction"
                ;;
            focus-previous-pane)
                zellij action focus-previous-pane
                ;;
            resize)
                local amount
                amount=$(echo "$step" | jq -r '.amount // 1')
                local j
                for (( j=0; j<amount; j++ )); do
                    zellij action resize "$direction"
                done
                ;;
        esac
    done <<< "$steps"
}

create_task() {
    local dir="$1"
    local type="$2"
    local name="$3"
    local resume="$4"   # optional: agent session id to resume
    local agent="$5"    # optional: named agent (config .agents key)

    local -a agent_cmd
    read -r -a agent_cmd <<< "$(agent_command "$agent")"

    # A tab recreated under a previous task's name must not inherit that
    # task's screen-detection state: a stale "working" would fake an instant
    # Stop (or a stale "blocked" an unwanted jump to Main) on the new tab's
    # first poll.
    rm -f "$HOME/.claude-pending/${ZELLIJ_SESSION_NAME:-unknown}/.screen-state/$(_screen_tab_slug "$name")"

    # TASK_AGENT rides along only for named agents, so tabs on the legacy
    # single-agent path keep their exact env (and pending files stay
    # agent-less, which downstream treats as claude).
    local -a envs=(TASK_TAB_NAME="$name" TASK_TYPE="$type")
    [[ -n "$agent" ]] && envs+=(TASK_AGENT="$agent")

    local rc
    if [[ -n "$resume" ]]; then
        local -a resume_flags
        read -r -a resume_flags <<< "$(agent_resume_args "$agent")"
        zellij action new-tab -n "$name" --cwd "$dir" -- env "${envs[@]}" "${agent_cmd[@]}" "${resume_flags[@]}" "$resume"
        rc=$?
    else
        zellij action new-tab -n "$name" --cwd "$dir" -- env "${envs[@]}" "${agent_cmd[@]}"
        rc=$?
    fi
    # Report tab-creation success to the caller (restore relies on this).
    # Bail out before building panes if the tab itself could not be created.
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi

    sleep 0.3

    # zellij 0.44.1 degrades by dropping only new-tab's *implicit* focus switch
    # (an explicit go-to-tab-name still works), which would leave the caller on
    # the old tab while every pane command below lands on the new one. Focusing
    # by name removes that dependency; it is a no-op when new-tab already moved
    # focus there. Runs after the settle sleep so a slow server has registered
    # the tab by the time we address it by name.
    zellij action go-to-tab-name "$name" 2>/dev/null

    zellij action new-pane --direction down --cwd "$dir" -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"
    local i
    for i in {1..30}; do
        zellij action resize decrease up
    done
    zellij action focus-previous-pane

    # Layout is cosmetic; its status must not mask tab-creation success.
    apply_layout "$dir" "$type"
    return 0
}
