#!/bin/bash
# Claude Conductor - AI Tech News Pane
# Displays AI tech news fetched from TechCrunch.
# Reads from ~/.claude-conductor/news/YYYY-MM-DD.json

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
NEWS_DIR="$CONDUCTOR_HOME/news"

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
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

    local i=0
    while [[ $i -lt $count ]]; do
        local title description url
        title=$(jq -r ".items[$i].title" "$NEWS_FILE" 2>/dev/null)
        description=$(jq -r ".items[$i].description" "$NEWS_FILE" 2>/dev/null)
        url=$(jq -r ".items[$i].url" "$NEWS_FILE" 2>/dev/null)

        # OSC 8 hyperlink: clickable title linking to full URL
        if [[ "$url" != "null" ]] && [[ -n "$url" ]]; then
            printf "  ${YELLOW}%d.${NC} \033]8;;%s\033\\\\${BOLD}%.42s${NC}\033]8;;\033\\\\\n" "$((i+1))" "$url" "$title"
        else
            printf "  ${YELLOW}%d.${NC} ${BOLD}%.42s${NC}\n" "$((i+1))" "$title"
        fi
        if [[ "$description" != "null" ]] && [[ -n "$description" ]]; then
            printf "     ${DIM}%.42s${NC}\n" "$description"
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
