# Claude Conductor - Shell Functions
# Source this file from your .zshrc:
#   source "$HOME/.claude-conductor/init.zsh"

export CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# --- Zellij aliases ---
alias zj='zellij'
alias zja='zellij attach'
alias zjl='zellij list-sessions'
alias zjk='zellij kill-session'

# --- Session launchers ---

# Multi-task session with dashboard
mdev() {
    local session_name="${1:-$(basename $(pwd))-$(date +%H%M%S)}"
    zellij --new-session-with-layout "$CONDUCTOR_HOME/layouts/multi.kdl" --session "$session_name"
}

# Single dev session (Claude + Neovim + lazygit)
dev() {
    local session_name="${1:-$(basename $(pwd))-$(date +%H%M%S)}"
    zellij --new-session-with-layout "$CONDUCTOR_HOME/layouts/dev.kdl" --session "$session_name"
}

# Select a project directory and start a dev session
pdev() {
    local project=$(fd --type d --max-depth 2 . ~/projects | fzf --prompt="Select project: ")
    if [[ -n "$project" ]]; then
        cd "$project"
        dev
    fi
}

# Attach or create a session
zs() {
    local session_name="${1:-$(zellij list-sessions 2>/dev/null | fzf --prompt="Select session: ")}"
    if [[ -n "$session_name" ]]; then
        zellij attach "$session_name" 2>/dev/null || zellij --session "$session_name"
    fi
}

# --- Task management (run inside Zellij) ---

# Add a task tab with Claude + control pane
task() {
    local type="${1:-dev}"
    local name="${2:-$type-$(date +%H%M%S)}"

    # タイプのバリデーション
    case "$type" in
        dev|k8s|review|docs|survey) ;;
        *)
            echo "Unknown task type: $type"
            echo "Available: dev, k8s, review, docs, survey"
            return 1
            ;;
    esac

    # 共通: タブ作成 → コントロールバーを全幅で先に確保
    zellij action new-tab -n "$name" -- env TASK_TAB_NAME="$name" claude
    sleep 0.3
    zellij action new-pane --direction down -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"
    local i
    for i in {1..30}; do
        zellij action resize decrease up
    done
    zellij action focus-previous-pane

    # タスクタイプ別: メインエリアのペイン分割
    case "$type" in
        dev)
            # 左: Claude Code, 右: LazyVim
            sleep 0.3
            zellij action new-pane --direction right -- nvim
            zellij action focus-previous-pane
            ;;
        k8s)
            # 左上: Claude, 右上: k9s, 左下: Shell, 右下: LazyVim
            sleep 0.3
            zellij action new-pane --direction right -- k9s
            zellij action new-pane --direction down -- nvim
            zellij action move-focus left
            zellij action new-pane --direction down
            zellij action move-focus up
            ;;
        review|docs|survey)
            # Claude Codeのみ（追加ペインなし）
            ;;
    esac
}

# Clear all pending entries
pending-clear() {
    rm -rf ~/.claude-pending/* 2>/dev/null
    echo "Pending queue cleared"
}
