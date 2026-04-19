#!/bin/bash
# Claude Conductor - Fetch AI Tech News
# Fetches AI-related news from Hacker News Algolia API and saves to a daily file.
# Skips if today's file already exists.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
NEWS_DIR="$CONDUCTOR_HOME/news"
TODAY=$(date '+%Y-%m-%d')
NEWS_FILE="$NEWS_DIR/$TODAY.json"

# Skip if today's news already fetched
if [[ -f "$NEWS_FILE" ]]; then
    exit 0
fi

mkdir -p "$NEWS_DIR"

# Fetch AI-related stories from Hacker News (timeout 5s, filter by points>10)
RESPONSE=$(curl -s --max-time 5 \
    "https://hn.algolia.com/api/v1/search?query=AI+LLM+GPT+Claude&tags=story&numericFilters=points%3E10&hitsPerPage=5" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$RESPONSE" ]]; then
    exit 0
fi

# Validate JSON, extract fields, and generate HN discussion URL
RESULT=$(echo "$RESPONSE" | jq '{
    hits: [.hits[] | {
        title: .title,
        url: ("https://news.ycombinator.com/item?id=" + .objectID),
        points: .points,
        num_comments: .num_comments,
        created_at: .created_at,
        objectID: .objectID
    }]
}' 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$RESULT" ]]; then
    exit 0
fi

echo "$RESULT" > "$NEWS_FILE"
