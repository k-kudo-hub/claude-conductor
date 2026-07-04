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

# generate_summary <transcript_path>: print a conversation summary, non-zero on failure.
generate_summary() {
    return 0
}

# build_log_path <base_dir> <completed_at> <taskname>: print the relative log path.
build_log_path() {
    return 0
}

# build_markdown <daily_record_json> <summary_text>: print the log markdown.
build_markdown() {
    return 0
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
