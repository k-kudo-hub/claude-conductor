#!/bin/bash
# Claude Conductor - Fetch AI Tech News
# Fetches AI-related news from TechCrunch AI RSS feed and saves to a daily JSON file.
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

# Fetch TechCrunch AI RSS feed (timeout 5s)
RSS=$(curl -s --max-time 5 \
    "https://techcrunch.com/category/artificial-intelligence/feed/" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$RSS" ]]; then
    exit 0
fi

# Parse RSS XML with awk (BSD-compatible) and convert to JSON (first 5 items)
RESULT=$(echo "$RSS" | awk '
function extract(str, open, end,    n, parts, val) {
    n = split(str, parts, open)
    if (n < 2) return ""
    split(parts[2], val, end)
    return val[1]
}
BEGIN {
    RS = "<item>"
    count = 0
    print "{\"items\":["
}
NR > 1 && count < 5 {
    title = ""; link = ""; desc = ""

    # Extract title (try CDATA first, then plain)
    raw = extract($0, "<title>", "</title>")
    gsub(/<!\[CDATA\[/, "", raw)
    gsub(/\]\]>/, "", raw)
    title = raw

    # Extract link
    link = extract($0, "<link>", "</link>")

    # Extract description (try CDATA first, then plain)
    raw = extract($0, "<description>", "</description>")
    gsub(/<!\[CDATA\[/, "", raw)
    gsub(/\]\]>/, "", raw)
    desc = raw

    if (title != "" && link != "") {
        # Escape double quotes and backslashes in title and desc
        gsub(/\\/, "\\\\", title)
        gsub(/"/, "\\\"", title)
        gsub(/\\/, "\\\\", desc)
        gsub(/"/, "\\\"", desc)
        # Strip HTML tags from description
        gsub(/<[^>]*>/, "", desc)
        # Trim description to 120 chars
        if (length(desc) > 120) desc = substr(desc, 1, 120) "..."

        if (count > 0) print ","
        printf "{\"title\":\"%s\",\"url\":\"%s\",\"description\":\"%s\"}", title, link, desc
        count++
    }
}
END {
    print "]}"
}
' 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$RESULT" ]]; then
    exit 0
fi

# Validate JSON with jq before saving
echo "$RESULT" | jq '.' > "$NEWS_FILE" 2>/dev/null

if [[ $? -ne 0 ]]; then
    rm -f "$NEWS_FILE"
fi
