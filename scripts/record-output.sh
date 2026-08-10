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
if [ -f "$CONDUCTOR_HOME/scripts/codex-rollout-lib.sh" ]; then
    # shellcheck source=scripts/codex-rollout-lib.sh
    source "$CONDUCTOR_HOME/scripts/codex-rollout-lib.sh"
fi

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
    # Codex rollout jsonl. The layout knowledge (v1 events vs v2 item_completed
    # items, and why the tool views are picked rather than summed) lives in
    # codex-rollout-lib.sh; only the pricing and record shaping are local.
    # usage is the cumulative total of the last token_count event and the model
    # comes from turn_context; both are unchanged in v2. Unknown models yield a
    # null cost rather than borrowing claude pricing.
    RECORD=$(jq -sc --arg tab "$TAB_NAME" --arg completed_at "$COMPLETED_AT" --arg message "$MESSAGE" --arg session "$SESSION_NAME" --arg dir "$DIR" --arg task_type "$TASK_TYPE" --arg claude_session_id "$CLAUDE_SESSION_ID" --arg transcript_path "$TRANSCRIPT_PATH" --arg agent "$AGENT" --argjson pricing "$PRICING_JSON" "$CODEX_ROLLOUT_JQ"'
        codex_turns as $turns |
        codex_tools as $tools |
        ($tools | length) as $calls |
        ($tools | [.[] | codex_tool_name] | unique) as $used |
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
        codex_merged as $has_merged |
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

# Write under the daily-log lock, held only for the write itself so the hold
# time stays short — a slow transcript parse above must never block a
# concurrent restore long enough to trip its fail-open rewrite.
#
# The write replaces rather than appends: an upload failure cancels dd, so the
# same tab is recorded again on every retry and the Done pane would otherwise
# grow one entry per attempt. The key is (tab, claude_session_id), and an entry
# is replaced only when ALL of the following hold:
#   1. claude_session_id is non-empty and is NOT a synthesized "screen-<slug>"
#      id. screen-detect-lib.sh derives that id from the tab name alone, so it
#      is identical across completely unrelated tasks that happened to reuse a
#      tab name — replacing on it would silently delete an older, unrelated
#      task's entry. Screen-detected records are always appended (the previous
#      behaviour: a duplicate is recoverable, a deleted history entry is not).
#   2. The existing entry is not yet restored. A restored entry is the history
#      of a task that went back to the dashboard and must survive.
#   3. The daily-log lock was actually acquired. Rewriting the whole file
#      without it could roll back a restored:true flag that restore-task.sh set
#      concurrently, so an unlocked write degrades to a plain append.
# Rewrite via lock + mktemp + mv, the same way restore-task.sh edits the file.
#
# Known limitations (accepted, documented for the mdev-go port):
#   - A tab whose pending flips between a real session id and screen-<slug>
#     between two retries records under two different keys and still leaves two
#     entries. The window is narrow, and a leftover duplicate is safer than
#     deleting an entry that may belong to another task.
#   - Every attempt re-stamps completed_at while restore-task.sh matches entries
#     by (tab, completed_at). An entry re-recorded inside the done-loop's
#     5s + 3s `r<number>` confirmation window makes that one restore miss; the
#     next refresh shows the new timestamp and the retry succeeds. Changing
#     restore-task.sh's matching key is out of scope here.
if [ -n "$OUT" ]; then
    DAILY_LOCK="$DAILY_FILE.lock"
    LOCK_HELD=0
    TMP=""
    if acquire_lock "$DAILY_LOCK" 2; then
        LOCK_HELD=1
    else
        echo "record-output: proceeding without daily-log lock" >&2
    fi
    trap '[ "$LOCK_HELD" = 1 ] && release_lock "$DAILY_LOCK"; rm -f "$TMP"' EXIT

    # Condition 1: only a real session id is a usable dedupe key.
    DEDUPE_KEY=""
    case "$CLAUDE_SESSION_ID" in
        ""|screen-*) ;;
        *) DEDUPE_KEY="$CLAUDE_SESSION_ID" ;;
    esac

    if [ -n "$DEDUPE_KEY" ] && [ "$LOCK_HELD" = 1 ] && [ -f "$DAILY_FILE" ]; then
        TMP=$(mktemp)
        # A jq failure (unparsable daily file) leaves the file untouched and
        # falls through to a plain append: a duplicate entry is recoverable,
        # a truncated daily log is not.
        if jq -c --arg tab "$TAB_NAME" --arg sid "$DEDUPE_KEY" \
            'select(((.tab == $tab) and ((.claude_session_id // "") == $sid) and ((.restored // false) != true)) | not)' \
            "$DAILY_FILE" > "$TMP" 2>/dev/null; then
            mv "$TMP" "$DAILY_FILE"
            TMP=""
        fi
    fi

    # Replacement is delete + append, so the re-recorded entry lands at the tail.
    # upload-log.sh picks a tab's record with `tail -1`, i.e. by file order, so
    # the newest attempt must be the last line. The Done pane does not depend on
    # this (done-loop.sh sorts entries by completed_at).
    printf '%s\n' "$OUT" >> "$DAILY_FILE"
fi
