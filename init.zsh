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
    bash "$CONDUCTOR_HOME/scripts/fetch-news.sh"
    zellij --new-session-with-layout "$CONDUCTOR_HOME/layouts/multi.kdl" --session "$session_name"
}

# Launch an isolated test session for a worktree in a new terminal window.
# Points CONDUCTOR_HOME at the worktree so its scripts/layouts/hooks run,
# without overwriting the installed ~/.claude-conductor environment.
#
# Usage:
#   mdev-test <worktree-path>     # absolute or relative path to a worktree
#   mdev-test <branch-name>       # resolved under <repo>/.worktree/<name>
#   mdev-test                     # pick from .worktree/ with fzf
mdev-test() {
    local input="$1"
    local wt_path wt_name session

    # Locate the main repository root (works from main repo or a worktree)
    local common_dir main_root=""
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
    if [[ -n "$common_dir" ]]; then
        [[ "$common_dir" != /* ]] && common_dir="$(pwd)/$common_dir"
        main_root="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)"
    fi

    # No argument: pick a worktree from .worktree/ via fzf
    if [[ -z "$input" ]]; then
        if [[ -z "$main_root" || ! -d "$main_root/.worktree" ]]; then
            echo "mdev-test: no .worktree/ directory found (run from a conductor repo)" >&2
            return 1
        fi
        input=$(command ls -1 "$main_root/.worktree" 2>/dev/null | fzf --prompt="Select worktree: ")
        [[ -z "$input" ]] && return 1
    fi

    # Resolve the worktree path
    if [[ -d "$input" ]]; then
        wt_path="$(cd "$input" && pwd)"
    elif [[ -n "$main_root" && -d "$main_root/.worktree/$input" ]]; then
        wt_path="$main_root/.worktree/$input"
    else
        echo "mdev-test: worktree not found: $input" >&2
        return 1
    fi

    # Validate it is a conductor worktree
    if [[ ! -d "$wt_path/scripts" || ! -d "$wt_path/layouts" ]]; then
        echo "mdev-test: not a conductor worktree (missing scripts/ or layouts/): $wt_path" >&2
        return 1
    fi

    wt_name="$(basename "$wt_path")"
    session="test-$wt_name"

    # Warn if the worktree's layout predates CONDUCTOR_HOME support: its Main-tab
    # panes hardcode ~/.claude-conductor, so they run the INSTALLED scripts rather
    # than this worktree's (data/hooks are still isolated via CONDUCTOR_HOME).
    if ! grep -q 'CONDUCTOR_HOME' "$wt_path/layouts/multi.kdl" 2>/dev/null; then
        echo "mdev-test: WARNING: $wt_name/layouts/multi.kdl has no CONDUCTOR_HOME reference." >&2
        echo "mdev-test:   Main-tab panes will run INSTALLED scripts, not this worktree's (partial isolation)." >&2
    fi

    # zellij (>=0.44) rejects session names longer than 24 characters. Truncate,
    # appending a short hash of the full path so distinct worktrees whose names
    # share a prefix don't collapse onto the same session name.
    if (( ${#session} > 24 )); then
        local wt_hash
        wt_hash=$(printf '%s' "$wt_path" | cksum | cut -d' ' -f1)
        wt_hash=${wt_hash: -4}
        session="${session:0:19}"
        session="${session%-}-$wt_hash"
        echo "mdev-test: session name truncated to '$session' (zellij 24-char limit)" >&2
    fi

    # Command executed inside the new terminal window. Delete any existing session
    # of this name first so a re-run always starts fresh from the worktree's current
    # layout/scripts (zellij would otherwise error, or `attach` would resurrect the
    # stale serialized layout). delete-session is a no-op if the session is absent.
    local run_cmd="export CONDUCTOR_HOME='$wt_path'; cd '$wt_path'; bash '$wt_path/scripts/fetch-news.sh'; zellij delete-session '$session' --force 2>/dev/null; zellij --new-session-with-layout '$wt_path/layouts/multi.kdl' --session '$session'"

    # Dry-run mode for testing: print the resolved launch spec and exit
    if [[ -n "$CONDUCTOR_MDEV_TEST_DRYRUN" ]]; then
        echo "CONDUCTOR_HOME=$wt_path"
        echo "SESSION=$session"
        echo "CMD=$run_cmd"
        return 0
    fi

    echo "Launching fresh isolated test session '$session' from $wt_path"
    echo "mdev-test: any existing session named '$session' is replaced." >&2

    # Warp: launch natively via a temporary Launch Configuration, which opens a new
    # tab already in the worktree with the command auto-running (no separate app,
    # no Automation permission). The exec runs after .zshrc, so its CONDUCTOR_HOME
    # export overrides the installed default.
    if [[ "$TERM_PROGRAM" == "WarpTerminal" ]]; then
        local lc_dir="$HOME/.warp/launch_configurations"
        mkdir -p "$lc_dir"
        rm -f "$lc_dir"/mdev-test-*.yaml(N)        # clean up previous runs (N: no error if none)
        local lc_name="mdev-test-$session"
        {
            echo "---"
            echo "name: $lc_name"
            echo "windows:"
            echo "  - tabs:"
            echo "      - title: $session"
            echo "        layout:"
            echo "          cwd: \"$wt_path\""
            echo "          commands:"
            echo "            - exec: \"$run_cmd\""
        } > "$lc_dir/$lc_name.yaml"
        open "warp://launch/$lc_name"
        return 0
    fi

    # Write the launch command to a temp .command script.
    # macOS mktemp rejects a suffix after the X's, so create then rename;
    # Terminal.app runs *.command files directly.
    local launch_script
    launch_script="$(mktemp "${TMPDIR:-/tmp}/mdev-test-XXXXXX")" || {
        echo "mdev-test: failed to create temp launch script" >&2
        return 1
    }
    mv "$launch_script" "$launch_script.command"
    launch_script="$launch_script.command"
    {
        echo "#!/bin/bash"
        echo "$run_cmd"
        echo "rm -f '$launch_script'"
    } > "$launch_script"
    chmod +x "$launch_script"

    # Open a new OS terminal window and run the script there.
    # Terminal.app executes an opened *.command via LaunchServices (no Automation
    # permission needed) with the login PATH. iTerm does not reliably run an opened
    # .command, so drive it through its scripting API, falling back to Terminal.app
    # if that is blocked (e.g. Automation permission denied).
    case "$TERM_PROGRAM" in
        iTerm.app)
            # Create the window and run the command in a single statement so a
            # partial failure can't leave an empty window plus a Terminal fallback.
            osascript -e "tell application \"iTerm\" to create window with default profile command \"bash '$launch_script'\"" >/dev/null 2>&1 \
                || open -a Terminal "$launch_script"
            ;;
        *)
            open -a Terminal "$launch_script"
            ;;
    esac
}

# Single dev session (Claude + Neovim + lazygit)
dev() {
    local session_name="${1:-$(basename $(pwd))-$(date +%H%M%S)}"
    zellij --new-session-with-layout "$CONDUCTOR_HOME/layouts/dev.kdl" --session "$session_name"
}

# Attach or create a session
zs() {
    local session_name="${1:-$(zellij list-sessions 2>/dev/null | fzf --prompt="Select session: ")}"
    if [[ -n "$session_name" ]]; then
        zellij attach "$session_name" 2>/dev/null || zellij --session "$session_name"
    fi
}

# Clear all pending entries
pending-clear() {
    rm -rf ~/.claude-pending/* 2>/dev/null
    echo "Pending queue cleared"
}
