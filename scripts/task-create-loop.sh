#!/bin/bash
# Claude Conductor - Interactive Task Creator
# Mainタブ下部ペインで動作するタスク作成UI

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
SEARCH_DIRS=("$HOME/projects" "$HOME/works")
SEARCH_DEPTH=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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

    case "$type" in
        dev)
            sleep 0.3
            zellij action new-pane --direction right --cwd "$dir" -- nvim
            zellij action focus-previous-pane
            ;;
        k8s)
            sleep 0.3
            zellij action new-pane --direction right --cwd "$dir" -- k9s
            zellij action new-pane --direction down --cwd "$dir" -- nvim
            zellij action move-focus left
            zellij action new-pane --direction down --cwd "$dir"
            zellij action move-focus up
            ;;
    esac
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
            # Step 1: ディレクトリ選択
            fd_args=()
            for d in "${SEARCH_DIRS[@]}"; do
                [[ -d "$d" ]] && fd_args+=("$d")
            done

            if [[ ${#fd_args[@]} -eq 0 ]]; then
                echo -e "  ${RED}検索対象ディレクトリが見つかりません${NC}"
                sleep 2
                continue
            fi

            dir=$(fd --type d --max-depth "$SEARCH_DEPTH" . "${fd_args[@]}" 2>/dev/null | fzf --prompt="Directory: ")
            [[ -z "$dir" ]] && continue

            # Step 2: タスクタイプ選択
            type=$(printf '%s\n' \
                "dev      Claude Code + LazyVim" \
                "review   Claude Code only" \
                "docs     Claude Code only" \
                "survey   Claude Code only" \
                "k8s      Claude Code + k9s + Shell + LazyVim" \
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
