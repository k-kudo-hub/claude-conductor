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

# shellcheck source=scripts/lock-lib.sh
source "$CONDUCTOR_HOME/scripts/lock-lib.sh"
# shellcheck source=scripts/registry-lib.sh
source "$CONDUCTOR_HOME/scripts/registry-lib.sh"

mkdir -p "$DAILY_DIR"

# The tab is being deleted: drop its task-registry entries so the task is not
# resurrected on the next session restore (issue #36). By tab, not sid — a
# --resume restart changes the session id, leaving multiple entries per tab.
# This must run even when no pending file remains (early exit below).
registry_remove_by_tab "$SESSION_NAME" "$TAB_NAME"

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
DIR=""
TASK_TYPE=""
CLAUDE_SESSION_ID=""
AGENT=""
FOUND=false

for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    ftab=$(jq -r '.tab' "$f" 2>/dev/null)
    [ "$ftab" = "$TAB_NAME" ] || continue

    TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' "$f" 2>/dev/null)
    MESSAGE=$(jq -r '.message // empty' "$f" 2>/dev/null)
    DIR=$(jq -r '.dir // empty' "$f" 2>/dev/null)
    TASK_TYPE=$(jq -r '.task_type // empty' "$f" 2>/dev/null)
    CLAUDE_SESSION_ID=$(jq -r '.claude_session_id // empty' "$f" 2>/dev/null)
    AGENT=$(jq -r '.agent // empty' "$f" 2>/dev/null)
    FOUND=true
    break
done

if [ "$FOUND" = "false" ]; then
    exit 0
fi

COMPLETED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
OUT=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ "$AGENT" = "codex" ]; then
    # Codex rollout jsonl: turns are user_message events, tool calls are
    # response_items whose type ends in "_call" (custom_tool_call etc.),
    # usage is the cumulative total of the last token_count event, and the
    # model comes from turn_context. Unknown models yield a null cost rather
    # than borrowing claude pricing.
    RECORD=$(jq -sc --arg tab "$TAB_NAME" --arg completed_at "$COMPLETED_AT" --arg message "$MESSAGE" --arg session "$SESSION_NAME" --arg dir "$DIR" --arg task_type "$TASK_TYPE" --arg claude_session_id "$CLAUDE_SESSION_ID" --arg transcript_path "$TRANSCRIPT_PATH" --arg agent "$AGENT" --argjson pricing "$PRICING_JSON" '
        ([.[] | select(.type == "event_msg" and .payload.type == "user_message")] | length) as $turns |
        [.[] | select(.type == "response_item") | .payload | select(.type != null) | select(.type | test("_call$"))] as $tools |
        ($tools | length) as $calls |
        ($tools | [.[] | .name // .type] | unique) as $used |
        ([.[] | select(.type == "event_msg" and .payload.type == "token_count") | .payload.info.total_token_usage | select(. != null)] | last) as $usage |
        ((($usage.input_tokens // 0) - ($usage.cached_input_tokens // 0)) ) as $in |
        ($usage.output_tokens // 0) as $out |
        ($usage.cached_input_tokens // 0) as $cache_read |
        ($usage.cache_write_input_tokens // 0) as $cache_write |
        ([.[] | select(.type == "turn_context") | .payload.model | select(. != null)] | last // "unknown") as $model |
        ($pricing[$model] // null) as $p |
        (if $p == null then null else
            (
                ($in * $p.input) +
                ($out * $p.output) +
                ($cache_read * ($p.cache_hit // 0)) +
                ($cache_write * ($p.cache_write // 0))
            ) / 1000000
        end) as $cost |
        ($tools | [.[] | ((.input // .arguments // "") | tostring) | select(test("gh\\s+pr\\s+merge"))] | length > 0) as $has_merged |
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
                speed: "standard",
                total_input_tokens: $in,
                total_output_tokens: $out,
                cache_read_tokens: $cache_read,
                cache_write_tokens: $cache_write,
                total_cost_usd: (if $cost == null then null else ($cost * 1000000 | round | . / 1000000) end)
            },
            markers: {
                merged: $has_merged,
                slack: false,
                doc: false
            },
            agent: $agent
        }
        + (if $dir != "" then {dir: $dir} else {} end)
        + (if $task_type != "" then {task_type: $task_type} else {} end)
        + (if $claude_session_id != "" then {claude_session_id: $claude_session_id} else {} end)
        + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
    ' "$TRANSCRIPT_PATH" 2>/dev/null)

    if [ -z "$RECORD" ]; then
        RECORD=$(jq -n -c \
            --arg tab "$TAB_NAME" \
            --arg session "$SESSION_NAME" \
            --arg completed_at "$COMPLETED_AT" \
            --arg message "${MESSAGE:-Parse failed}" \
            --arg dir "$DIR" \
            --arg task_type "$TASK_TYPE" \
            --arg claude_session_id "$CLAUDE_SESSION_ID" \
            --arg transcript_path "$TRANSCRIPT_PATH" \
            --arg agent "$AGENT" \
            '{
                tab: $tab,
                session: $session,
                completed_at: $completed_at,
                message: $message,
                summary: null,
                markers: { merged: false, slack: false, doc: false },
                agent: $agent
            }
            + (if $dir != "" then {dir: $dir} else {} end)
            + (if $task_type != "" then {task_type: $task_type} else {} end)
            + (if $claude_session_id != "" then {claude_session_id: $claude_session_id} else {} end)
            + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)')
    fi
    OUT="$RECORD"
elif [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Extract session summary, markers, and cost in a single jq pass
    RECORD=$(jq -sc --arg tab "$TAB_NAME" --arg completed_at "$COMPLETED_AT" --arg message "$MESSAGE" --arg session "$SESSION_NAME" --arg dir "$DIR" --arg task_type "$TASK_TYPE" --arg claude_session_id "$CLAUDE_SESSION_ID" --arg transcript_path "$TRANSCRIPT_PATH" --arg agent "$AGENT" --argjson pricing "$PRICING_JSON" '. as $all |
        ([.[] | select(.type == "user")] | length) as $turns |
        [.[] | .message.content[]? | select(.type == "tool_use")] as $tools |
        ($tools | length) as $calls |
        ($tools | [.[].name] | unique) as $used |
        [.[] | select(.message.usage?) | .message.usage] as $usage |
        ($usage | [.[].input_tokens] | add // 0) as $in |
        ($usage | [.[].output_tokens] | add // 0) as $out |
        ($usage | [.[].cache_read_input_tokens // 0] | add // 0) as $cache_read |
        ($usage | [.[].cache_creation?.ephemeral_5m_input_tokens // 0] | add // 0) as $cache_5m |
        ($usage | [.[].cache_creation?.ephemeral_1h_input_tokens // 0] | add // 0) as $cache_1h |
        ([.[] | select(.message.model?) | .message.model] | .[0] // "unknown") as $model |
        ([.[] | select(.message.usage?.speed?) | .message.usage.speed] | .[0] // "standard") as $speed |
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
        + (if $dir != "" then {dir: $dir} else {} end)
        + (if $task_type != "" then {task_type: $task_type} else {} end)
        + (if $claude_session_id != "" then {claude_session_id: $claude_session_id} else {} end)
        + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
        + (if $agent != "" then {agent: $agent} else {} end)
    ' "$TRANSCRIPT_PATH" 2>/dev/null)

    if [ -n "$RECORD" ]; then
        OUT="$RECORD"
    else
        OUT=$(jq -n -c \
            --arg tab "$TAB_NAME" \
            --arg session "$SESSION_NAME" \
            --arg completed_at "$COMPLETED_AT" \
            --arg message "${MESSAGE:-Parse failed}" \
            --arg dir "$DIR" \
            --arg task_type "$TASK_TYPE" \
            --arg claude_session_id "$CLAUDE_SESSION_ID" \
            --arg transcript_path "$TRANSCRIPT_PATH" \
            --arg agent "$AGENT" \
            '{
                tab: $tab,
                session: $session,
                completed_at: $completed_at,
                message: $message,
                summary: null,
                markers: { merged: false, slack: false, doc: false }
            }
            + (if $dir != "" then {dir: $dir} else {} end)
            + (if $task_type != "" then {task_type: $task_type} else {} end)
            + (if $claude_session_id != "" then {claude_session_id: $claude_session_id} else {} end)
            + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
            + (if $agent != "" then {agent: $agent} else {} end)')
    fi
else
    OUT=$(jq -n -c \
        --arg tab "$TAB_NAME" \
        --arg session "$SESSION_NAME" \
        --arg completed_at "$COMPLETED_AT" \
        --arg message "${MESSAGE:-No summary available}" \
        --arg dir "$DIR" \
        --arg task_type "$TASK_TYPE" \
        --arg claude_session_id "$CLAUDE_SESSION_ID" \
        --arg transcript_path "$TRANSCRIPT_PATH" \
        --arg agent "$AGENT" \
        '{
            tab: $tab,
            session: $session,
            completed_at: $completed_at,
            message: $message,
            summary: null,
            markers: { merged: false, slack: false, doc: false }
        }
        + (if $dir != "" then {dir: $dir} else {} end)
        + (if $task_type != "" then {task_type: $task_type} else {} end)
        + (if $claude_session_id != "" then {claude_session_id: $claude_session_id} else {} end)
        + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
        + (if $agent != "" then {agent: $agent} else {} end)')
fi

# Append under the daily-log lock, held only for the write itself so the hold
# time stays sub-millisecond — a slow transcript parse above must never block a
# concurrent restore long enough to trip its fail-open rewrite.
if [ -n "$OUT" ]; then
    DAILY_LOCK="$DAILY_FILE.lock"
    if acquire_lock "$DAILY_LOCK" 2; then
        printf '%s\n' "$OUT" >> "$DAILY_FILE"
        release_lock "$DAILY_LOCK"
    else
        echo "record-output: proceeding without daily-log lock" >&2
        printf '%s\n' "$OUT" >> "$DAILY_FILE"
    fi
fi
