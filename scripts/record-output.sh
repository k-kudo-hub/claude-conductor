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
CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
DAILY_DIR="$CONDUCTOR_HOME/daily/$SESSION_NAME"
DAILY_FILE="$DAILY_DIR/$(date '+%Y-%m-%d').jsonl"
CONFIG_FILE="$CONDUCTOR_HOME/config.json"
CONFIG_DEFAULT="$CONDUCTOR_HOME/config.default.json"

mkdir -p "$DAILY_DIR"

# Load pricing from config (fallback to config.default.json)
PRICING_JSON=""
if [ -f "$CONFIG_FILE" ]; then
    PRICING_JSON=$(jq -c '.pricing // empty' "$CONFIG_FILE" 2>/dev/null)
fi
if [ -z "$PRICING_JSON" ] && [ -f "$CONFIG_DEFAULT" ]; then
    PRICING_JSON=$(jq -c '.pricing // empty' "$CONFIG_DEFAULT" 2>/dev/null)
fi
PRICING_JSON="${PRICING_JSON:-"{}"}"

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
    # Extract session summary, markers, and cost in a single jq pass
    RECORD=$(jq -sc --arg tab "$TAB_NAME" --arg completed_at "$COMPLETED_AT" --arg message "$MESSAGE" --arg session "$SESSION_NAME" --argjson pricing "$PRICING_JSON" '. as $all |
        ([.[] | select(.type == "user")] | length) as $turns |
        [.[] | .message.content[]? | select(.type == "tool_use")] as $tools |
        ($tools | length) as $calls |
        ($tools | [.[].name] | unique) as $used |
        [.[] | select(.message.usage?) | .message.usage] as $usage |
        ($usage | [.[].input_tokens] | add // 0) as $in |
        ($usage | [.[].output_tokens] | add // 0) as $out |
        ($usage | [.[].cache_read_input_tokens // 0] | add // 0) as $cache_read |
        ($usage | [.[].cache_creation_input_tokens // 0] | add // 0) as $cache_creation_total |
        ($usage | [.[].cache_creation?.ephemeral_5m_input_tokens // 0] | add // 0) as $cache_5m |
        ($usage | [.[].cache_creation?.ephemeral_1h_input_tokens // 0] | add // 0) as $cache_1h |
        ([.[] | select(.message.model?) | .message.model] | first // "unknown") as $model |
        ([.[] | select(.message.usage?.speed?) | .message.usage.speed] | first // "standard") as $speed |
        ($pricing[$model] // $pricing["claude-sonnet-4-6"] // {input:3,output:15,cache_write_5m:3.75,cache_write_1h:6,cache_hit:0.3}) as $p |
        (if $speed == "fast" then ($pricing.fast_multiplier // 6) else 1 end) as $fm |
        (
            ($in * $p.input * $fm / 1000000) +
            ($out * $p.output * $fm / 1000000) +
            ($cache_5m * $p.cache_write_5m * $fm / 1000000) +
            ($cache_1h * $p.cache_write_1h * $fm / 1000000) +
            ($cache_read * $p.cache_hit * $fm / 1000000)
        ) as $cost |
        ($tools | [.[] | select(.name | test("^mcp__slack"))] | length > 0) as $has_slack |
        ($tools | [.[] | select(.name == "Write" or .name == "Edit")] |
            [.[].input? // {} | .file_path? // "" | select(test("\\.(md|mdx|txt|rst|adoc)$"))] | length > 0) as $has_doc |
        ($tools | [.[] | select(
            .name == "mcp__github__merge_pull_request" or
            (.name == "Bash" and (.input?.command? // "" | test("gh\\s+pr\\s+merge")))
        )] | length > 0) as $has_merged |
        {
            tab: $tab,
            session: $session,
            completed_at: $completed_at,
            message: $message,
            summary: {
                total_turns: $turns,
                total_tool_calls: $calls,
                tools_used: $used,
                model: $model,
                speed: $speed,
                total_input_tokens: $in,
                total_output_tokens: $out,
                cache_read_tokens: $cache_read,
                cache_write_5m_tokens: $cache_5m,
                cache_write_1h_tokens: $cache_1h,
                total_cost_usd: ($cost * 1000000 | round | . / 1000000)
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
            --arg session "$SESSION_NAME" \
            --arg completed_at "$COMPLETED_AT" \
            --arg message "${MESSAGE:-Parse failed}" \
            '{
                tab: $tab,
                session: $session,
                completed_at: $completed_at,
                message: $message,
                summary: null,
                markers: { merged: false, slack: false, doc: false }
            }' >> "$DAILY_FILE"
    fi
else
    jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg session "$SESSION_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "${MESSAGE:-No summary available}" \
        '{
            tab: $tab,
            session: $session,
            completed_at: $completed_at,
            message: $message,
            summary: null,
            markers: { merged: false, slack: false, doc: false }
        }' >> "$DAILY_FILE"
fi
