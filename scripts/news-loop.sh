#!/bin/bash
# Claude Conductor - AI Tech News Pane
# Displays AI tech news fetched from TechCrunch.
# Reads from ~/.claude-conductor/news/YYYY-MM-DD.json
# Press [1-5] to open article in browser.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
NEWS_DIR="$CONDUCTOR_HOME/news"

BOLD='\033[1m'
DIM='\033[2m'
YELLOW='\033[0;33m'
NC='\033[0m'

render() {
    clear

    echo -e "${BOLD}  AI Tech News${NC} ${DIM}[$(date '+%Y-%m-%d')]${NC}"
    echo -e "${DIM}  ──────────────────────${NC}"
    echo ""

    TODAY=$(date '+%Y-%m-%d')
    NEWS_FILE="$NEWS_DIR/$TODAY.json"

    if [[ ! -f "$NEWS_FILE" ]]; then
        echo -e "  ${DIM}No news yet. Run mdev to fetch.${NC}"
        return
    fi

    local count
    count=$(jq -r '.items | length' "$NEWS_FILE" 2>/dev/null)

    if [[ "$count" == "0" ]] || [[ -z "$count" ]]; then
        echo -e "  ${DIM}No news yet. Run mdev to fetch.${NC}"
        return
    fi

    ITEM_COUNT=$count

    local i=0
    while [[ $i -lt $count ]]; do
        local title description
        title=$(jq -r ".items[$i].title" "$NEWS_FILE" 2>/dev/null)
        description=$(jq -r ".items[$i].description" "$NEWS_FILE" 2>/dev/null)

        echo -e "  ${YELLOW}$((i+1)).${NC} ${BOLD}${title}${NC}"
        if [[ "$description" != "null" ]] && [[ -n "$description" ]]; then
            echo -e "     ${DIM}${description}${NC}"
        fi
        echo ""

        i=$((i + 1))
    done

    echo -e "${DIM}  ──────────────────────${NC}"
    echo -e "  ${DIM}[1-${count}]: open in browser${NC}"
}

# Single-pass mode for testing
if [[ "$CONDUCTOR_NEWS_ONCE" == "1" ]]; then
    render
    exit 0
fi

ITEM_COUNT=0

while true; do
    render

    key=""
    read -t 5 -n 1 -s key || true

    if [[ "$key" =~ [1-9] ]] && [[ $key -le ${ITEM_COUNT:-0} ]]; then
        TODAY=$(date '+%Y-%m-%d')
        NEWS_FILE="$NEWS_DIR/$TODAY.json"
        url=$(jq -r ".items[$((key-1))].url" "$NEWS_FILE" 2>/dev/null)
        if [[ -n "$url" ]] && [[ "$url" != "null" ]]; then
            if command -v open &>/dev/null; then
                open "$url" 2>/dev/null
            elif command -v xdg-open &>/dev/null; then
                xdg-open "$url" 2>/dev/null
            fi
        fi
    fi
done
