#!/bin/bash
# Claude Conductor - Done Tasks Pane
# Displays completed tasks from today's daily log.
# r+number restores a task back to the dashboard.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

DAILY_BASE="$HOME/.claude-conductor/daily"

TMPFILE=$(mktemp)
printf '\033[?25l'
trap 'printf "\033[?25h"; rm -f "$TMPFILE"' EXIT
clear

while true; do
    TODAY=$(date '+%Y-%m-%d')
    DAILY_FILES=()
    while IFS= read -r -d '' f; do
        DAILY_FILES+=("$f")
    done < <(find "$DAILY_BASE" -name "${TODAY}.jsonl" -type f -print0 2>/dev/null)

    # Restore lookup arrays, populated in display order (index = shown number - 1)
    r_tabs=()
    r_sessions=()
    r_completed=()
    count=0

    {
        echo -e "${BOLD}  Done Tasks${NC}"
        echo -e "${DIM}  ──────────────────────────${NC}"
        echo ""

        if [ ${#DAILY_FILES[@]} -gt 0 ]; then
            daily_stats=$(cat "${DAILY_FILES[@]}" | jq -s 'map(select((.restored // false) != true)) | {
                count: length,
                turns: ([.[].summary.total_turns // 0] | add),
                calls: ([.[].summary.total_tool_calls // 0] | add),
                cost: ([.[].summary.total_cost_usd // 0] | add)
            }' 2>/dev/null)
            task_count=$(echo "$daily_stats" | jq -r '.count')
            total_turns=$(echo "$daily_stats" | jq -r '.turns')
            total_calls=$(echo "$daily_stats" | jq -r '.calls')
            total_cost=$(echo "$daily_stats" | jq -r '.cost | if . > 0 then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "$0.00" end')
        else
            task_count=0
        fi

        if [ "${task_count:-0}" -gt 0 ]; then
            echo -e "  ${YELLOW}${BOLD}${task_count}${NC} tasks  ${DIM}${total_turns} turns / ${total_calls} calls / ${total_cost}${NC}"
            echo ""

            i=1
            while IFS="$(printf '\t')" read -r tab session completed turns cost time markers; do
                if [ -n "$markers" ]; then
                    printf "  ${YELLOW}[%d]${NC} ${GREEN}⚡${NC} %-14s %3s t  %7s  ${DIM}[%s]${NC} %s\n" "$i" "$tab" "$turns" "$cost" "$time" "$markers"
                else
                    printf "  ${YELLOW}[%d]${NC} ${GREEN}⚡${NC} %-14s %3s t  %7s  ${DIM}[%s]${NC}\n" "$i" "$tab" "$turns" "$cost" "$time"
                fi
                r_tabs+=("$tab")
                r_sessions+=("$session")
                r_completed+=("$completed")
                i=$((i + 1))
            done < <(cat "${DAILY_FILES[@]}" | jq -s -r --arg rocket "🚀" --arg chat "💬" --arg memo "📝" 'map(select((.restored // false) != true)) | sort_by(.completed_at) | .[] | [
                .tab,
                .session,
                .completed_at,
                (.summary.total_turns // "-" | tostring),
                (.summary.total_cost_usd // null | if . != null then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "-" end),
                (.completed_at | .[11:16]),
                ([ (if .markers.merged then $rocket else empty end),
                   (if .markers.slack  then $chat else empty end),
                   (if .markers.doc    then $memo else empty end)
                ] | join(""))
            ] | join("\t")' 2>/dev/null)

            count=${#r_tabs[@]}

            echo ""
            echo -e "${DIM}  ──────────────────────────${NC}"
            echo -e "  ${DIM}r+[num]: restore to dashboard${NC}"
        else
            echo -e "  ${DIM}No tasks completed yet${NC}"
        fi
    } > "$TMPFILE"

    printf '\033[H'
    cat "$TMPFILE"
    printf '\033[J'

    if [ "$count" -eq 0 ]; then
        sleep 5
    else
        key=""
        read -t 5 -n 1 -s key || true

        if [[ "$key" == "r" ]]; then
            echo -ne "\r  ${YELLOW}${BOLD}Restore number...${NC}  "
            key2=""
            read -t 3 -n 1 -s key2 || true
            if [[ "$key2" =~ [1-9] ]] && [[ $key2 -le $count ]]; then
                idx=$((key2 - 1))
                bash "$CONDUCTOR_HOME/scripts/restore-task.sh" \
                    "${r_tabs[$idx]}" "${r_sessions[$idx]}" "${r_completed[$idx]}" 2>/dev/null
            fi
        fi
    fi
done
