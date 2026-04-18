#!/bin/bash
# Claude Conductor - Interactive Dashboard
# Pending tasks are displayed in Zellij tab order.
# Number keys to jump, d+number to delete.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
mkdir -p "$PENDING_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

while true; do
    clear

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Claude Conductor${NC} ${DIM}[$SESSION_NAME]${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    tabs=()
    i=1

    # Display pending items sorted by Zellij tab position
    tab_order=$(zellij action list-tabs 2>/dev/null | tail -n +2 | awk '{print $3}')

    for tab_name in $tab_order; do
        for f in "$PENDING_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            ftab=$(jq -r '.tab' "$f" 2>/dev/null)
            [[ "$ftab" == "$tab_name" ]] || continue

            msg=$(jq -r '.message' "$f" 2>/dev/null | head -c 60)
            time=$(jq -r '.time' "$f" 2>/dev/null)
            event=$(jq -r '.event' "$f" 2>/dev/null)

            if [[ "$event" == "Stop" ]]; then
                echo -e "  ${YELLOW}[$i]${NC} ${GREEN}■${NC} ${BOLD}$ftab${NC} ${DIM}[$time]${NC} done"
            else
                echo -e "  ${YELLOW}[$i]${NC} ${RED}■${NC} ${BOLD}$ftab${NC} ${DIM}[$time]${NC}"
            fi
            echo -e "      $msg"
            echo ""

            tabs+=("$ftab")
            i=$((i + 1))
        done
    done

    count=${#tabs[@]}

    if [[ $count -eq 0 ]]; then
        echo -e "  ${GREEN}All tasks running${NC}"
        echo ""
        echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        sleep 2
    else
        echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${BOLD}Pending: ${count}${NC}  ${DIM}[num]: jump / d+[num]: delete${NC}"
        echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        key=""
        read -t 2 -n 1 -s key || true

        if [[ "$key" == "d" ]]; then
            echo -ne "\r  ${RED}${BOLD}Delete tab number...${NC}  "
            key2=""
            read -t 3 -n 1 -s key2 || true
            if [[ "$key2" =~ [1-9] ]] && [[ $key2 -le $count ]]; then
                target_tab="${tabs[$((key2-1))]}"
                for f in "$PENDING_DIR"/*.json; do
                    [[ -f "$f" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$target_tab" ]]; then
                        rm -f "$f"
                    fi
                done
                tab_id=$(zellij action list-tabs 2>/dev/null | awk -v name="$target_tab" '$3 == name {print $1}')
                if [[ -n "$tab_id" ]]; then
                    zellij action close-tab-by-id "$tab_id" 2>/dev/null
                fi
            fi
        elif [[ "$key" =~ [1-9] ]] && [[ $key -le $count ]]; then
            zellij action go-to-tab-name "${tabs[$((key-1))]}" 2>/dev/null
        fi
    fi
done
