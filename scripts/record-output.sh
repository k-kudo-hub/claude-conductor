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
    TOTAL_TURNS=$(jq -s '[.[] | select(.type == "user")] | length' "$TRANSCRIPT_PATH" 2>/dev/null)
    TOTAL_TOOL_CALLS=$(jq -s '[.[] | .message.content[]? | select(.type == "tool_use")] | length' "$TRANSCRIPT_PATH" 2>/dev/null)
    TOOLS_USED=$(jq -s '[.[] | .message.content[]? | select(.type == "tool_use") | .name] | unique' "$TRANSCRIPT_PATH" 2>/dev/null)
    TOTAL_INPUT_TOKENS=$(jq -s '[.[] | select(.message.usage?) | .message.usage.input_tokens] | add // 0' "$TRANSCRIPT_PATH" 2>/dev/null)
    TOTAL_OUTPUT_TOKENS=$(jq -s '[.[] | select(.message.usage?) | .message.usage.output_tokens] | add // 0' "$TRANSCRIPT_PATH" 2>/dev/null)

    jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "$MESSAGE" \
        --argjson total_turns "${TOTAL_TURNS:-0}" \
        --argjson total_tool_calls "${TOTAL_TOOL_CALLS:-0}" \
        --argjson tools_used "${TOOLS_USED:-[]}" \
        --argjson total_input_tokens "${TOTAL_INPUT_TOKENS:-0}" \
        --argjson total_output_tokens "${TOTAL_OUTPUT_TOKENS:-0}" \
        '{
            tab: $tab,
            completed_at: $completed_at,
            message: $message,
            summary: {
                total_turns: $total_turns,
                total_tool_calls: $total_tool_calls,
                tools_used: $tools_used,
                total_input_tokens: $total_input_tokens,
                total_output_tokens: $total_output_tokens
            }
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
