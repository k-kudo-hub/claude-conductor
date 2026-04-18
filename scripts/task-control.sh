#!/bin/bash
# Claude Conductor - Task Tab Control Bar
# m: Go to Main tab / dd: Delete this tab

TAB_NAME="${1:-unknown}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

DIM='\033[2m'
BOLD='\033[1m'
RED='\033[0;31m'
NC='\033[0m'

while true; do
    clear
    echo -e "${DIM}  m: Main  |  dd: Delete tab${NC}"

    key=""
    read -n 1 -s key

    case "$key" in
        m)
            zellij action go-to-tab-name "Main" 2>/dev/null
            ;;
        d)
            echo -ne "\r${RED}${BOLD}  Press d to confirm delete...${NC}  "
            key2=""
            read -t 2 -n 1 -s key2
            if [[ "$key2" == "d" ]]; then
                for f in "$PENDING_DIR"/*.json; do
                    [[ -f "$f" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$TAB_NAME" ]]; then
                        rm -f "$f"
                    fi
                done
                zellij action close-tab 2>/dev/null
                exit 0
            fi
            ;;
    esac
done
