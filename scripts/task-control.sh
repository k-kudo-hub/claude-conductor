#!/bin/bash
# Claude Conductor - Task Tab Control Bar
# m: Go to Main tab / w: Toggle Waiting / dd: Delete this tab
# When the task is Waiting (blocked on an external response), the bar
# shows a WAITING indicator so the state is visible from the task tab.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
TAB_NAME="${1:-unknown}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

DIM='\033[2m'
BOLD='\033[1m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Current pending event for this tab (empty if none)
current_event() {
    local f
    for f in "$PENDING_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$TAB_NAME" ]]; then
            jq -r '.event' "$f" 2>/dev/null
            return
        fi
    done
}

render_bar() {
    if [[ "$(current_event)" == "Waiting" ]]; then
        echo -e "${YELLOW}${BOLD}  ● WAITING${NC}${DIM}  |  m: Main  |  w: Resume  |  dd: Delete tab${NC}"
    else
        echo -e "${DIM}  m: Main  |  w: Waiting  |  dd: Delete tab${NC}"
    fi
}

# Single-pass mode for testing
if [[ "$CONDUCTOR_TASKCTL_ONCE" == "1" ]]; then
    render_bar
    exit 0
fi

while true; do
    clear
    render_bar

    key=""
    read -t 2 -n 1 -s key || true

    case "$key" in
        m)
            zellij action go-to-tab-name "Main" 2>/dev/null
            ;;
        w)
            bash "$CONDUCTOR_HOME/scripts/waiting-toggle.sh" "$TAB_NAME"
            ;;
        d)
            echo -ne "\r${RED}${BOLD}  Press d to confirm delete...${NC}  "
            key2=""
            read -t 2 -n 1 -s key2
            if [[ "$key2" == "d" ]]; then
                bash "$CONDUCTOR_HOME/scripts/record-output.sh" "$TAB_NAME"
                # Upload the work log synchronously. If it fails, cancel deletion.
                echo -ne "\r${DIM}  Uploading log...${NC}  "
                if ! bash "$CONDUCTOR_HOME/scripts/upload-log.sh" "$TAB_NAME"; then
                    echo -ne "\r${RED}${BOLD}  Upload failed. Deletion cancelled.${NC}  "
                    sleep 2
                    continue
                fi
                for f in "$PENDING_DIR"/*.json; do
                    [[ -f "$f" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$TAB_NAME" ]]; then
                        rm -f "$f"
                    fi
                done
                # Close this task's own tab by id, not the active tab: the
                # synchronous upload can take seconds, during which the active
                # tab may have switched (e.g. auto-routing to Main), so
                # `close-tab` could close the wrong tab. Fall back to close-tab
                # only if the id lookup fails.
                tab_id=$(zellij action list-tabs 2>/dev/null | awk -v name="$TAB_NAME" '$3 == name {print $1}')
                if [[ -n "$tab_id" ]]; then
                    zellij action close-tab-by-id "$tab_id" 2>/dev/null
                else
                    zellij action close-tab 2>/dev/null
                fi
                exit 0
            fi
            ;;
    esac
done
