#!/bin/bash
# Claude Conductor - Done Tasks Pane
# Displays completed tasks from today's daily log.

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

    {
        echo -e "${BOLD}  Done Tasks${NC}"
        echo -e "${DIM}  ──────────────────────────${NC}"
        echo ""

        if [ ${#DAILY_FILES[@]} -gt 0 ]; then
            daily_stats=$(cat "${DAILY_FILES[@]}" | jq -s '{
                count: length,
                turns: ([.[].summary.total_turns // 0] | add),
                calls: ([.[].summary.total_tool_calls // 0] | add)
            }' 2>/dev/null)
            task_count=$(echo "$daily_stats" | jq -r '.count')
            total_turns=$(echo "$daily_stats" | jq -r '.turns')
            total_calls=$(echo "$daily_stats" | jq -r '.calls')

            echo -e "  ${YELLOW}${BOLD}${task_count}${NC} tasks  ${DIM}${total_turns} turns / ${total_calls} calls${NC}"
            echo ""

            cat "${DAILY_FILES[@]}" | jq -r --arg rocket "🚀" --arg chat "💬" --arg memo "📝" '[
                .tab,
                (.summary.total_turns // "-" | tostring),
                (.completed_at | .[11:16]),
                ([ (if .markers.merged then $rocket else empty end),
                   (if .markers.slack  then $chat else empty end),
                   (if .markers.doc    then $memo else empty end)
                ] | join(""))
            ] | join("\t")' 2>/dev/null | while IFS="$(printf '\t')" read -r tab turns time markers; do
                if [ -n "$markers" ]; then
                    printf "  ${GREEN}⚡${NC} %-14s %3s t  ${DIM}[%s]${NC} %s\n" "$tab" "$turns" "$time" "$markers"
                else
                    printf "  ${GREEN}⚡${NC} %-14s %3s t  ${DIM}[%s]${NC}\n" "$tab" "$turns" "$time"
                fi
            done
        else
            echo -e "  ${DIM}No tasks completed yet${NC}"
        fi
    } > "$TMPFILE"

    printf '\033[H'
    cat "$TMPFILE"
    printf '\033[J'

    sleep 5
done
