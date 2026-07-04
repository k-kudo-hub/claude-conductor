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

    zellij action new-tab -n "$name" --cwd "$dir" -- env TASK_TAB_NAME="$name" TASK_TYPE="$type" claude
    sleep 0.3

    zellij action new-pane --direction down --cwd "$dir" -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"
    local i
    for i in {1..30}; do
        zellij action resize decrease up
    done
    zellij action focus-previous-pane

    apply_layout "$dir" "$type"
}
