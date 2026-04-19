#!/bin/bash
# Claude Conductor - Interactive Task Creator
# Mainタブ下部ペインで動作するタスク作成UI

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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

    local layout_count
    layout_count=$(jq -r ".task_types[\"$type\"].layout | length" "$config_file")

    if [[ "$layout_count" -eq 0 ]]; then
        return
    fi

    sleep 0.3

    local i
    for (( i=0; i<layout_count; i++ )); do
        local action direction command
        action=$(jq -r ".task_types[\"$type\"].layout[$i].action" "$config_file")
        direction=$(jq -r ".task_types[\"$type\"].layout[$i].direction" "$config_file")
        command=$(jq -r ".task_types[\"$type\"].layout[$i].command // empty" "$config_file")

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
                amount=$(jq -r ".task_types[\"$type\"].layout[$i].amount // 1" "$config_file")
                local j
                for (( j=0; j<amount; j++ )); do
                    zellij action resize "$direction"
                done
                ;;
        esac
    done

    zellij action focus-previous-pane
}

create_task() {
    local dir="$1"
    local type="$2"
    local name="$3"

    zellij action new-tab -n "$name" --cwd "$dir" -- env TASK_TAB_NAME="$name" claude
    sleep 0.3

    zellij action new-pane --direction down --cwd "$dir" -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"
    local i
    for i in {1..30}; do
        zellij action resize decrease up
    done
    zellij action focus-previous-pane

    apply_layout "$dir" "$type"
}

while true; do
    clear
    echo -e "${BOLD}  New Task${NC}  ${DIM}[$SESSION_NAME]${NC}"
    echo -e "${DIM}  ──────────────────────────${NC}"
    echo ""
    echo -e "  ${DIM}[n]${NC} Create task"
    echo ""

    key=""
    read -n 1 -s key

    case "$key" in
        n|N)
            config_file=$(load_config)

            # Step 1: ディレクトリ選択
            fd_args=()
            while IFS= read -r d; do
                expanded="${d/#\~/$HOME}"
                [[ -d "$expanded" ]] && fd_args+=("$expanded")
            done < <(jq -r '.search_dirs[]' "$config_file")

            if [[ ${#fd_args[@]} -eq 0 ]]; then
                echo -e "  ${RED}検索対象ディレクトリが見つかりません${NC}"
                sleep 2
                continue
            fi

            search_depth=$(jq -r '.search_depth' "$config_file")

            dir=$(fd --type d --max-depth "$search_depth" . "${fd_args[@]}" 2>/dev/null | fzf --prompt="Directory: ")
            [[ -z "$dir" ]] && continue

            # Step 2: タスクタイプ選択
            type=$(jq -r '.task_types | to_entries[] | "\(.key)  \(.value.description)"' "$config_file" \
                | column -t \
                | fzf --prompt="Task type: " | awk '{print $1}')
            [[ -z "$type" ]] && continue

            # Step 3: タスク名入力
            echo -ne "  ${BOLD}Task name: ${NC}"
            read -r name
            [[ -z "$name" ]] && name="$type-$(date +%H%M%S)"

            # タスク作成
            echo -e "  ${GREEN}Creating ${type} task '${name}' in ${dir}...${NC}"
            create_task "$dir" "$type" "$name"
            ;;
    esac
done
