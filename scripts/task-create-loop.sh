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

# ディレクトリ名とタスクタイプからデフォルトのタスク名候補を生成する
# 例: /home/user/myapp, dev -> myapp-dev
generate_default_name() {
    local dir="$1"
    local type="$2"
    echo "$(basename "$dir")-$type"
}

# config.json で名前入力スキップモードが有効かどうかを判定する
skip_name_input_enabled() {
    local config_file
    config_file=$(load_config)
    [[ "$(jq -r '.skip_task_name_input // false' "$config_file" 2>/dev/null)" == "true" ]]
}

# 入力値を解決する。空ならデフォルト候補を採用する（Step 3 の実処理を関数化しテスト可能にする）
resolve_name() {
    local default_name="$1"
    local input="$2"
    if [[ -z "$input" ]]; then
        echo "$default_name"
    else
        echo "$input"
    fi
}

# 既存タブ名と重複しないよう一意なタブ名を返す。
# 重複時は -2, -3... を付与する。Zellij外やコマンド失敗時は元の名前をそのまま返す。
ensure_unique_tab_name() {
    local base="$1"
    local existing
    existing=$(zellij action query-tab-names 2>/dev/null) || { echo "$base"; return; }

    local candidate="$base"
    local n=2
    while grep -Fxq "$candidate" <<< "$existing"; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    echo "$candidate"
}

main_loop() {
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

            # Step 3: タスク名入力（デフォルト候補を提示）
            default_name=$(generate_default_name "$dir" "$type")
            if skip_name_input_enabled; then
                name="$default_name"
            elif (( BASH_VERSINFO[0] >= 4 )); then
                # bash 4以降: 初期値を編集可能な状態で提示（read -i は 4.0 以降）
                read -e -i "$default_name" -r -p "  Task name: " raw_name
                name=$(resolve_name "$default_name" "$raw_name")
            else
                # bash 3.x（macOSデフォルト）: [候補] を提示し Enter で確定、入力で上書き
                echo -ne "  ${BOLD}Task name ${NC}${DIM}[${default_name}]${NC}: "
                read -r raw_name
                name=$(resolve_name "$default_name" "$raw_name")
            fi

            # 既存タブと名前が重複しないよう一意化する（旧: timestampで担保していた一意性を維持）
            name=$(ensure_unique_tab_name "$name")

            # タスク作成
            echo -e "  ${GREEN}Creating ${type} task '${name}' in ${dir}...${NC}"
            create_task "$dir" "$type" "$name"
            ;;
    esac
done
}

# スクリプトが直接実行された場合のみメインループを起動する（source時はテスト用に関数のみ提供）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_loop
fi
