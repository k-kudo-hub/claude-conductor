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

# shellcheck source=scripts/task-lib.sh
source "$CONDUCTOR_HOME/scripts/task-lib.sh"

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
