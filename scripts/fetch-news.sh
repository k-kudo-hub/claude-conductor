#!/bin/bash
# Claude Conductor - Fetch AI Tech News
# Fetches AI-related news from TechCrunch AI RSS feed and saves to a daily JSON file.
# Skips if today's file already exists, unless --force is given.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
NEWS_DIR="$CONDUCTOR_HOME/news"
TODAY=$(date '+%Y-%m-%d')
NEWS_FILE="$NEWS_DIR/$TODAY.json"

# Parse arguments (--force re-fetches even if today's file exists)
FORCE=0
if [[ "$1" == "--force" ]]; then
    FORCE=1
fi

# Skip if today's news already fetched (unless forced)
if [[ "$FORCE" -eq 0 ]] && [[ -f "$NEWS_FILE" ]]; then
    exit 0
fi

mkdir -p "$NEWS_DIR"

# Fetch TechCrunch AI RSS feed (timeout 5s)
RSS=$(curl -s --max-time 5 \
    "https://techcrunch.com/category/artificial-intelligence/feed/" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$RSS" ]]; then
    exit 0
fi

# Parse RSS XML with awk (BSD-compatible) into tab-separated rows (first 5
# items), then let jq build the JSON.
#
# awk only extracts and cleans; it never escapes and never measures text.
# Hand-rolled escaping plus a byte-wise substr had two failure modes, both of
# which produced no news file at all for the whole day:
#   - escaping before trimming could cut inside an escape sequence and leave a
#     lone backslash, which made the document invalid JSON
#   - trimming with substr() cuts on bytes, so a cut through a multibyte
#     character makes BSD awk abort with "towc: multibyte conversion failure"
# jq owns both jobs now: it escapes correctly by construction and slices by
# codepoint, so the ordering problem cannot come back. Trimming is 120
# codepoints, matching the Go version (mdev-go internal/domain/news_rss.go:
# truncateRunes, also runes) rather than 120 bytes.
#
# LC_ALL=C keeps awk byte-oriented. Every regex here is ASCII, and awk no longer
# measures or cuts text, so this changes nothing about the output — it only
# removes the last path where a stray invalid UTF-8 byte in a feed could abort
# awk ("towc: multibyte conversion failure") and cost the whole day's file.
ROWS=$(echo "$RSS" | LC_ALL=C awk '
function extract(str, open, end,    n, parts, val) {
    n = split(str, parts, open)
    if (n < 2) return ""
    split(parts[2], val, end)
    return val[1]
}
BEGIN {
    RS = "<item>"
    count = 0
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
        # Strip HTML tags (they may contain quotes and stray angle brackets)
        gsub(/<[^>]*>/, "", title)
        gsub(/<[^>]*>/, "", desc)
        # Flatten every separator that would break "one item per line, one
        # field per tab" (CDATA blocks may contain newlines and tabs).
        # \r is dropped rather than replaced: CRLF would otherwise leave two
        # spaces where the text had one line break.
        gsub(/\r/, "", title); gsub(/\n/, " ", title); gsub(/\t/, " ", title)
        gsub(/\r/, "", desc);  gsub(/\n/, " ", desc);  gsub(/\t/, " ", desc)
        # A URL carries no whitespace, and feeds do wrap <link> across lines.
        # Drop the separators outright and trim what the wrapping indented,
        # otherwise the padded url fails to open from the news pane.
        gsub(/\r/, "", link); gsub(/\n/, "", link); gsub(/\t/, "", link)
        sub(/^[[:space:]]+/, "", link); sub(/[[:space:]]+$/, "", link)

        printf "%s\t%s\t%s\n", title, link, desc
        count++
    }
}
' 2>/dev/null)

if [[ $? -ne 0 ]]; then
    exit 0
fi

# Build the JSON from the rows. jq escapes each field by construction, and
# `.[:120]` slices by codepoint, so neither quotes nor multibyte text can
# produce a broken document.
RESULT=$(echo "$ROWS" | jq -R -n '
    {items: [
        inputs
        | select(length > 0)
        | split("\t")
        | {
            title: .[0],
            url: .[1],
            description: (.[2] // "" | if length > 120 then .[:120] + "..." else . end)
          }
    ]}' 2>/dev/null)

if [[ $? -eq 0 ]] && [[ -n "$RESULT" ]]; then
    echo "$RESULT" > "$NEWS_FILE"
fi

# Clean up news files older than 7 days
find "$NEWS_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null
