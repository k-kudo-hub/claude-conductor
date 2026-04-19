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

    # Detect pane width (fallback to 40 for narrow panes)
    local cols
    cols=$(tput cols 2>/dev/null || echo 40)
    local max_len=$((cols - 6))

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

        # Trim title to fit pane width
        if [[ ${#title} -gt $max_len ]]; then
            title="${title:0:$((max_len - 3))}..."
        fi

        echo -e "  ${YELLOW}$((i+1)).${NC} ${BOLD}${title}${NC}"
        if [[ "$description" != "null" ]] && [[ -n "$description" ]]; then
            local desc_trimmed="$description"
            if [[ ${#desc_trimmed} -gt $max_len ]]; then
                desc_trimmed="${desc_trimmed:0:$((max_len - 3))}..."
            fi
            echo -e "     ${DIM}${desc_trimmed}${NC}"
        fi
        if [[ "$url" != "null" ]] && [[ -n "$url" ]]; then
            local url_trimmed="$url"
            if [[ ${#url_trimmed} -gt $max_len ]]; then
                url_trimmed="${url_trimmed:0:$((max_len - 3))}..."
            fi
            echo -e "     ${CYAN}${url_trimmed}${NC}"
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
