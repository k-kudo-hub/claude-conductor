#!/bin/bash
# Claude Conductor - AI Tech News Pane
# Displays AI tech news fetched from Hacker News.
# Reads from ~/.claude-conductor/news/YYYY-MM-DD.json

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
NEWS_DIR="$CONDUCTOR_HOME/news"

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

render() {
    clear

    echo -e "${BOLD}  AI Tech News${NC} ${DIM}[$(date '+%Y-%m-%d')]${NC}"
    echo -e "${DIM}  ──────────────────────────${NC}"
    echo ""

    TODAY=$(date '+%Y-%m-%d')
    NEWS_FILE="$NEWS_DIR/$TODAY.json"

    if [[ ! -f "$NEWS_FILE" ]]; then
        echo -e "  ${DIM}No news yet. Run mdev to fetch.${NC}"
        return
    fi

    local count
    count=$(jq -r '.hits | length' "$NEWS_FILE" 2>/dev/null)

    if [[ "$count" == "0" ]] || [[ -z "$count" ]]; then
        echo -e "  ${DIM}No news yet. Run mdev to fetch.${NC}"
        return
    fi

    local i=0
    while [[ $i -lt $count ]]; do
        local title points num_comments url
        title=$(jq -r ".hits[$i].title" "$NEWS_FILE" 2>/dev/null)
        points=$(jq -r ".hits[$i].points" "$NEWS_FILE" 2>/dev/null)
        num_comments=$(jq -r ".hits[$i].num_comments" "$NEWS_FILE" 2>/dev/null)
        url=$(jq -r ".hits[$i].url" "$NEWS_FILE" 2>/dev/null)

        echo -e "  ${YELLOW}$((i+1)).${NC} ${BOLD}${title}${NC}"
        echo -e "     ${GREEN}▲${points}${NC}  ${DIM}💬${num_comments}${NC}"
        if [[ "$url" != "null" ]] && [[ -n "$url" ]]; then
            echo -e "     ${CYAN}${url}${NC}"
        fi
        echo ""

        i=$((i + 1))
    done
}

# Single-pass mode for testing
if [[ "$CONDUCTOR_NEWS_ONCE" == "1" ]]; then
    render
    exit 0
fi

while true; do
    render
    sleep 300
done
