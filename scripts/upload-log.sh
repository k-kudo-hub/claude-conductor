#!/bin/bash
# Claude Conductor - Upload Log
# Uploads a task work log (summary + conversation summary) to a dedicated
# log repository when a task tab is deleted (dd).
#
# Usage: upload-log.sh <tab_name>
#
# Exit codes:
#   0  = success, or intentionally skipped (upload disabled / repo unset / no pending)
#   >0 = failure (the caller MUST abort the tab deletion so the log is not lost)
#
# When sourced with UPLOAD_LOG_LIB=1 only the helper functions are defined
# (used by test.sh); the main flow is skipped.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# load_config: echo the effective config file path (config.json > config.default.json)
load_config() {
    local config_file="$CONDUCTOR_HOME/config.json"
    if [ ! -f "$config_file" ]; then
        config_file="$CONDUCTOR_HOME/config.default.json"
    fi
    echo "$config_file"
}

# ------------------------------------------------------------------
# Helper functions (filled in by later tasks)
# ------------------------------------------------------------------

# filter_secrets: read stdin, mask known secret patterns, write stdout.
# Uses ERE (sed -E) patterns that work on both BSD (macOS) and GNU sed.
# Over-masking is preferred over leaking a credential.
filter_secrets() {
    sed -E \
        -e 's/sk-ant-[A-Za-z0-9_-]{10,}/***REDACTED***/g' \
        -e 's/sk-[A-Za-z0-9_-]{20,}/***REDACTED***/g' \
        -e 's/gh[posur]_[A-Za-z0-9]{20,}/***REDACTED***/g' \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED***/g' \
        -e 's/AKIA[0-9A-Z]{16}/***REDACTED***/g' \
        -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/***REDACTED***/g' \
        -e 's/([Bb]earer )[A-Za-z0-9._-]{10,}/\1***REDACTED***/g'
}

# generate_summary <transcript_path>: print a conversation summary via the
# claude CLI. Returns non-zero on any failure so the caller can abort dd.
generate_summary() {
    local transcript="$1"
    command -v claude >/dev/null 2>&1 || return 1
    [ -n "$transcript" ] && [ -f "$transcript" ] || return 1

    # Extract human-readable text (user + assistant text blocks) from the JSONL transcript
    local convo
    convo=$(jq -rs '
        [ .[]
          | select(.type == "user" or .type == "assistant")
          | .message.content as $c
          | (if ($c | type) == "string" then $c
             else ([ $c[]? | select(.type == "text") | .text ] | join("\n"))
             end)
          | select(. != null and . != "")
        ] | join("\n")
    ' "$transcript" 2>/dev/null)

    [ -n "$convo" ] || return 1

    # Strip secrets before sending the conversation to the model
    convo=$(printf '%s' "$convo" | filter_secrets)

    local summary
    summary=$(printf '%s' "$convo" | claude -p "以下はあるタスクの作業会話ログです。何を行ったかを日本語の箇条書き3〜6点で簡潔に要約してください。前置きや後書きは不要です。" 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ] || [ -z "$summary" ]; then
        return 1
    fi
    printf '%s' "$summary"
}

# build_log_path <base_dir> <completed_at> <taskname>:
# print "base_dir/YYYY/MM/DD/HHMMSS_taskname.md" (taskname sanitized).
build_log_path() {
    local base_dir="$1" completed_at="$2" taskname="$3"
    local yyyy="${completed_at:0:4}" mm="${completed_at:5:2}" dd="${completed_at:8:2}"
    local hh="${completed_at:11:2}" mi="${completed_at:14:2}" ss="${completed_at:17:2}"
    local ts="${hh}${mi}${ss}"
    local safe
    safe=$(printf '%s' "$taskname" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [ -n "$safe" ] || safe="task"
    printf '%s/%s/%s/%s/%s_%s.md' "$base_dir" "$yyyy" "$mm" "$dd" "$ts" "$safe"
}

# build_markdown <daily_record_json> <summary_text>: print the log markdown
# (secrets stripped from the final output).
build_markdown() {
    local record="$1" summary_text="$2"
    local tab session completed_at message model turns calls cost tools merged slack doc
    tab=$(printf '%s' "$record" | jq -r '.tab // "unknown"')
    session=$(printf '%s' "$record" | jq -r '.session // "unknown"')
    completed_at=$(printf '%s' "$record" | jq -r '.completed_at // ""')
    message=$(printf '%s' "$record" | jq -r '.message // ""')
    model=$(printf '%s' "$record" | jq -r '.summary.model // "unknown"')
    turns=$(printf '%s' "$record" | jq -r '.summary.total_turns // 0')
    calls=$(printf '%s' "$record" | jq -r '.summary.total_tool_calls // 0')
    cost=$(printf '%s' "$record" | jq -r '.summary.total_cost_usd // 0')
    tools=$(printf '%s' "$record" | jq -r '(.summary.tools_used // []) | join(", ")')
    merged=$(printf '%s' "$record" | jq -r 'if .markers.merged then "✅" else "-" end')
    slack=$(printf '%s' "$record" | jq -r 'if .markers.slack then "✅" else "-" end')
    doc=$(printf '%s' "$record" | jq -r 'if .markers.doc then "✅" else "-" end')

    cat <<EOF | filter_secrets
# $tab

- **Session**: $session
- **Completed**: $completed_at
- **Model**: $model

## メッセージ

$message

## サマリ

| 項目 | 値 |
|---|---|
| ターン数 | $turns |
| ツール呼び出し | $calls |
| コスト(USD) | $cost |
| 使用ツール | $tools |
| マージ | $merged |
| Slack | $slack |
| ドキュメント | $doc |

## 会話要約

$summary_text
EOF
}

# ------------------------------------------------------------------
# When sourced for tests, stop here (only expose the functions above).
# ------------------------------------------------------------------
if [ "${UPLOAD_LOG_LIB:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ==================================================================
# main
# ==================================================================
TAB_NAME="$1"
if [ -z "$TAB_NAME" ]; then
    exit 0
fi

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
DAILY_DIR="$CONDUCTOR_HOME/daily/$SESSION_NAME"
DAILY_FILE="$DAILY_DIR/$(date '+%Y-%m-%d').jsonl"

CONFIG_FILE=$(load_config)
UPLOAD_ENABLED=$(jq -r '.upload.enabled // false' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_REPO=$(jq -r '.upload.repo // ""' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_BASE_DIR=$(jq -r '.upload.base_dir // "work-log"' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_BRANCH=$(jq -r '.upload.branch // "main"' "$CONFIG_FILE" 2>/dev/null)

# Skip silently (success) when upload is disabled or no repository is configured.
if [ "$UPLOAD_ENABLED" != "true" ] || [ -z "$UPLOAD_REPO" ]; then
    exit 0
fi

# (subsequent tasks: locate pending, generate summary, build markdown, push)
exit 0
