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
DAILY_DIR="$HOME/.claude-conductor/daily"
DAILY_FILE="$DAILY_DIR/$(date '+%Y-%m-%d').jsonl"

mkdir -p "$DAILY_DIR"

TRANSCRIPT_PATH=""
MESSAGE=""

for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    ftab=$(jq -r '.tab' "$f" 2>/dev/null)
    [ "$ftab" = "$TAB_NAME" ] || continue

    TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' "$f" 2>/dev/null)
    MESSAGE=$(jq -r '.message // empty' "$f" 2>/dev/null)
    break
done

COMPLETED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    SUMMARY=$(jq -s '. as $all |
        ([.[] | select(.type == "user")] | length) as $turns |
        [.[] | .message.content[]? | select(.type == "tool_use")] as $tools |
        ($tools | length) as $calls |
        ($tools | [.[].name] | unique) as $used |
        [.[] | select(.message.usage?) | .message.usage] as $usage |
        ($usage | [.[].input_tokens] | add // 0) as $in |
        ($usage | [.[].output_tokens] | add // 0) as $out |
        {
            total_turns: $turns,
            total_tool_calls: $calls,
            tools_used: $used,
            total_input_tokens: $in,
            total_output_tokens: $out
        }
    ' "$TRANSCRIPT_PATH" 2>/dev/null)

    jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "$MESSAGE" \
        --argjson summary "${SUMMARY:-null}" \
        '{
            tab: $tab,
            completed_at: $completed_at,
            message: $message,
            summary: $summary
        }' >> "$DAILY_FILE"
else
    jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "${MESSAGE:-No summary available}" \
        '{
            tab: $tab,
            completed_at: $completed_at,
            message: $message,
            summary: null
        }' >> "$DAILY_FILE"
fi
