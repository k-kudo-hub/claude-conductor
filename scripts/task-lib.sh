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

# Agent launch command (config .agent.command). The value is a single string
# that callers word-split on purpose, so wrapper invocations like
# "fdev secrets exec my-header -- claude" work as-is.
agent_command() {
    local cmd
    cmd=$(jq -r '.agent.command // empty' "$(load_config)" 2>/dev/null)
    [[ -z "$cmd" ]] && cmd="claude"
    echo "$cmd"
}

# Arguments inserted between the agent command and the session id when
# resuming (config .agent.resume_args). Word-split like agent_command.
agent_resume_args() {
    local args
    args=$(jq -r '.agent.resume_args // empty' "$(load_config)" 2>/dev/null)
    [[ -z "$args" ]] && args="--resume"
    echo "$args"
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

    local -a agent_cmd
    read -r -a agent_cmd <<< "$(agent_command)"

    if [[ -n "$resume" ]]; then
        local -a resume_flags
        read -r -a resume_flags <<< "$(agent_resume_args)"
        zellij action new-tab -n "$name" --cwd "$dir" -- env TASK_TAB_NAME="$name" TASK_TYPE="$type" "${agent_cmd[@]}" "${resume_flags[@]}" "$resume"
    else
        zellij action new-tab -n "$name" --cwd "$dir" -- env TASK_TAB_NAME="$name" TASK_TYPE="$type" "${agent_cmd[@]}"
    fi
    # Report tab-creation success to the caller (restore relies on this).
    # Bail out before building panes if the tab itself could not be created.
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi
    sleep 0.3

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
