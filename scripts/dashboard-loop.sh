#!/bin/bash
# Claude Conductor - Interactive Dashboard (Current Tasks)
# Pending tasks are displayed in Zellij tab order.
# Number keys to jump, d+number to delete.
# Waiting tasks are excluded here and shown in the Waiting pane instead.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
mkdir -p "$PENDING_DIR"

# Screen-based state detection for hook-less agents (issue #28): each poll
# snapshots their panes and maps approval prompts / turn ends onto the same
# pending files the hooks write.
# shellcheck source=scripts/screen-detect-lib.sh
. "$CONDUCTOR_HOME/scripts/screen-detect-lib.sh"

# Rebuild tasks registered for this session before the first render
# (issue #36). No-op when the registry is empty or the tabs already exist.
bash "$CONDUCTOR_HOME/scripts/restore-session.sh" 2>/dev/null

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

tabs=()
pfiles=()
count=0

render() {
    tabs=()
    pfiles=()
    local i=1

    # Detect hook-less agent states before reading the pending files so the
    # list below already reflects this poll's screen observations.
    screen_detect_tick "$SESSION_NAME" 2>/dev/null

    # Display pending items sorted by Zellij tab position
    local tab_order
    tab_order=$(zellij action list-tabs 2>/dev/null | tail -n +2 | awk '{print $3}')

    echo -e "${BOLD}  Current Tasks${NC} ${DIM}[$SESSION_NAME]${NC}"
    echo -e "${DIM}  ──────────────────────────${NC}"
    echo ""

    local tab_name f ftab msg time event
    for tab_name in $tab_order; do
        for f in "$PENDING_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            ftab=$(jq -r '.tab' "$f" 2>/dev/null)
            [[ "$ftab" == "$tab_name" ]] || continue

            event=$(jq -r '.event' "$f" 2>/dev/null)
            # Waiting tasks belong to the Waiting pane, skip them here
            [[ "$event" == "Waiting" ]] && continue

            msg=$(jq -r '.message' "$f" 2>/dev/null | head -c 60)
            time=$(jq -r '.time' "$f" 2>/dev/null)

            if [[ "$event" == "Stop" ]]; then
                echo -e "  ${YELLOW}[$i]${NC} ${GREEN}■${NC} ${BOLD}$ftab${NC} ${DIM}[$time]${NC} done"
            else
                echo -e "  ${YELLOW}[$i]${NC} ${RED}■${NC} ${BOLD}$ftab${NC} ${DIM}[$time]${NC}"
            fi
            echo -e "      $msg"
            echo ""

            tabs+=("$ftab")
            pfiles+=("$f")
            i=$((i + 1))
        done
    done

    count=${#tabs[@]}

    if [[ $count -eq 0 ]]; then
        echo -e "  ${GREEN}All tasks running${NC}"
        echo ""
        echo -e "${DIM}  ──────────────────────────${NC}"
    else
        echo -e "${DIM}  ──────────────────────────${NC}"
        echo -e "  ${BOLD}Pending: ${count}${NC}  ${DIM}[num]: jump / d+[num]: delete${NC}"
        echo -e "${DIM}  ──────────────────────────${NC}"
    fi
}

# Single-pass mode for testing
if [[ "$CONDUCTOR_DASHBOARD_ONCE" == "1" ]]; then
    render
    exit 0
fi

TMPFILE=$(mktemp)
printf '\033[?25l'
trap 'printf "\033[?25h"; rm -f "$TMPFILE"' EXIT
clear

while true; do
    render > "$TMPFILE"

    printf '\033[H'
    cat "$TMPFILE"
    printf '\033[J'

    if [[ $count -eq 0 ]]; then
        sleep 2
    else
        key=""
        read -t 2 -n 1 -s key || true

        if [[ "$key" == "d" ]]; then
            echo -ne "\r  ${RED}${BOLD}Delete tab number...${NC}  "
            key2=""
            read -t 3 -n 1 -s key2 || true
            if [[ "$key2" =~ [1-9] ]] && [[ $key2 -le $count ]]; then
                target_tab="${tabs[$((key2-1))]}"
                bash "$CONDUCTOR_HOME/scripts/record-output.sh" "$target_tab"
                # Upload the work log synchronously. If it fails, cancel deletion.
                echo -ne "\r  ${DIM}Uploading log...${NC}  "
                if upload_out=$(bash "$CONDUCTOR_HOME/scripts/upload-log.sh" "$target_tab"); then
                    # Show the upload result (URL) briefly so it is confirmable
                    # before the tab closes. Empty output means nothing was
                    # uploaded (disabled / no pending) -> close immediately.
                    if [[ -n "$upload_out" ]]; then
                        echo -ne "\r\033[K  ${GREEN}${BOLD}${upload_out#upload-log: }${NC}"
                        sleep 2
                    fi
                else
                    echo -ne "\r  ${RED}${BOLD}Upload failed. Deletion cancelled.${NC}  "
                    sleep 2
                    continue
                fi
                for f in "$PENDING_DIR"/*.json; do
                    [[ -f "$f" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$target_tab" ]]; then
                        rm -f "$f"
                    fi
                done
                # Deletion is committed: drop the task's registry entries so a
                # later session restore does not resurrect it (issue #36),
                # and its screen-detection state so a same-named future tab
                # starts fresh.
                # shellcheck source=scripts/registry-lib.sh
                . "$CONDUCTOR_HOME/scripts/registry-lib.sh"
                registry_remove_by_tab "$SESSION_NAME" "$target_tab"
                rm -f "$PENDING_DIR/.screen-state/$(_screen_tab_slug "$target_tab")"
                # Match the tab name as everything past the id/position columns,
                # so names containing spaces still resolve to the right tab id.
                tab_id=$(zellij action list-tabs 2>/dev/null | awk -v name="$target_tab" \
                    'NR>1 { line=$0; sub(/^[^ ]+ +[^ ]+ +/, "", line); if (line == name) print $1 }')
                if [[ -n "$tab_id" ]]; then
                    zellij action close-tab-by-id "$tab_id" 2>/dev/null
                fi
            fi
        elif [[ "$key" =~ [1-9] ]] && [[ $key -le $count ]]; then
            zellij action go-to-tab-name "${tabs[$((key-1))]}" 2>/dev/null
            # An entry is cleared on jump only for agents with neither hooks
            # nor screen detection — nothing else would ever clear it. claude
            # hooks and screen detection own their lifecycles: a screen
            # Notification stays until the turn visibly resumes (like a
            # claude permission prompt stays until answered), so deleting it
            # here would just have the next poll recreate it.
            jump_file="${pfiles[$((key-1))]}"
            jump_agent=$(jq -r '.agent // "claude"' "$jump_file" 2>/dev/null)
            if [[ -f "$jump_file" && "$jump_agent" != "claude" \
                  && "$(agent_detection "$jump_agent")" != "screen" ]]; then
                rm -f "$jump_file"
            fi
        fi
    fi
done
