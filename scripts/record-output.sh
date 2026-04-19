#!/bin/bash
# Claude Conductor - Record Output
# Extracts session summary from transcript and appends to daily log.
# Usage: record-output.sh <tab_name>

TAB_NAME="$1"
if [ -z "$TAB_NAME" ]; then
    exit 0
fi

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
DAILY_DIR="$HOME/.claude-conductor/daily/$SESSION_NAME"
DAILY_FILE="$DAILY_DIR/$(date '+%Y-%m-%d').jsonl"

mkdir -p "$DAILY_DIR"

TRANSCRIPT_PATH=""
MESSAGE=""
FOUND=false

for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    ftab=$(jq -r '.tab' "$f" 2>/dev/null)
    [ "$ftab" = "$TAB_NAME" ] || continue

    TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' "$f" 2>/dev/null)
    MESSAGE=$(jq -r '.message // empty' "$f" 2>/dev/null)
    FOUND=true
    break
done

if [ "$FOUND" = "false" ]; then
    exit 0
fi

COMPLETED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Extract session summary and output markers in a single jq pass
    RECORD=$(jq -sc --arg tab "$TAB_NAME" --arg completed_at "$COMPLETED_AT" --arg message "$MESSAGE" '. as $all |
        ([.[] | select(.type == "user")] | length) as $turns |
        [.[] | .message.content[]? | select(.type == "tool_use")] as $tools |
        ($tools | length) as $calls |
        ($tools | [.[].name] | unique) as $used |
        [.[] | select(.message.usage?) | .message.usage] as $usage |
        ($usage | [.[].input_tokens] | add // 0) as $in |
        ($usage | [.[].output_tokens] | add // 0) as $out |
        ($tools | [.[] | select(.name | test("^mcp__slack"))] | length > 0) as $has_slack |
        ($tools | [.[] | select(.name == "Write" or .name == "Edit")] |
            [.[].input? // {} | .file_path? // "" | select(test("\\.(md|mdx|txt|rst|adoc)$"))] | length > 0) as $has_doc |
        ($tools | [.[] | select(
            .name == "mcp__github__merge_pull_request" or
            (.name == "Bash" and (.input?.command? // "" | test("gh\\s+pr\\s+merge")))
        )] | length > 0) as $has_merged |
        {
            tab: $tab,
            completed_at: $completed_at,
            message: $message,
            summary: {
                total_turns: $turns,
                total_tool_calls: $calls,
                tools_used: $used,
                total_input_tokens: $in,
                total_output_tokens: $out
            },
            markers: {
                merged: $has_merged,
                slack: $has_slack,
                doc: $has_doc
            }
        }
    ' "$TRANSCRIPT_PATH" 2>/dev/null)

    if [ -n "$RECORD" ]; then
        echo "$RECORD" >> "$DAILY_FILE"
    else
        jq -n -c \
            --arg tab "$TAB_NAME" \
            --arg completed_at "$COMPLETED_AT" \
            --arg message "${MESSAGE:-Parse failed}" \
            '{
                tab: $tab,
                completed_at: $completed_at,
                message: $message,
                summary: null,
                markers: { merged: false, slack: false, doc: false }
            }' >> "$DAILY_FILE"
    fi
else
    jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "${MESSAGE:-No summary available}" \
        '{
            tab: $tab,
            completed_at: $completed_at,
            message: $message,
            summary: null,
            markers: { merged: false, slack: false, doc: false }
        }' >> "$DAILY_FILE"
fi
