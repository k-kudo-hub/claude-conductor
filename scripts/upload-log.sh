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

# Fail loudly if the shared lib is missing rather than silently degrading
# (a missing lib.sh would leave load_config undefined and skip the upload).
LIB="$CONDUCTOR_HOME/scripts/lib.sh"
if [ ! -f "$LIB" ]; then
    echo "upload-log: missing $LIB" >&2
    exit 1
fi
# shellcheck source=lib.sh
. "$LIB"

# ------------------------------------------------------------------
# Helper functions (unit-tested by test.sh via UPLOAD_LOG_LIB=1)
# ------------------------------------------------------------------

# filter_secrets: read stdin, mask known secret patterns, write stdout.
# A first awk pass masks PEM private key blocks: once BEGIN is seen, every line
# up to (and including) END is dropped and replaced by a single marker, so even
# a short (<40 char) trailing base64 line of the key body is never leaked. An
# unterminated BEGIN over-masks to end-of-input (security over content). A
# standalone long base64 line outside any block is masked as a backstop for
# marker-less key material. A second sed pass masks single-line tokens with ERE
# patterns portable across BSD/GNU sed. No awk interval expressions are used
# (BSD awk portability). Over-masking is preferred over leaking a credential.
filter_secrets() {
    awk '
        /-----BEGIN[ A-Za-z]*PRIVATE KEY-----/ {
            print "***REDACTED PRIVATE KEY***"
            inkey = 1
            next
        }
        inkey {
            if (/-----END[ A-Za-z]*PRIVATE KEY-----/) { inkey = 0 }
            next
        }
        (length($0) >= 40 && $0 ~ /^[A-Za-z0-9+\/=]+$/) {
            print "***REDACTED***"
            next
        }
        { print }
    ' | sed -E \
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
    local tab session completed_at model turns calls cost tools merged slack doc
    # Pull every field in a single jq pass (tab-separated) instead of forking jq per field.
    IFS=$'\t' read -r tab session completed_at model turns calls cost tools merged slack doc < <(
        printf '%s' "$record" | jq -r '
            [ (.tab // "unknown"),
              (.session // "unknown"),
              (.completed_at // ""),
              (.summary.model // "unknown"),
              (.summary.total_turns // 0 | tostring),
              (.summary.total_tool_calls // 0 | tostring),
              (.summary.total_cost_usd // 0 | tostring),
              ((.summary.tools_used // []) | join(", ")),
              (if .markers.merged then "✅" else "-" end),
              (if .markers.slack then "✅" else "-" end),
              (if .markers.doc then "✅" else "-" end)
            ] | @tsv'
    )

    cat <<EOF | filter_secrets
# $tab

- **Session**: $session
- **Completed**: $completed_at
- **Model**: $model

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

# resolve_repo_url <repo>: turn "owner/name" into an SSH URL; pass through
# full URLs (https/ssh) and local paths unchanged.
resolve_repo_url() {
    local repo="$1"
    case "$repo" in
        *://*|git@*|/*|./*|../*) printf '%s' "$repo" ;;
        *) printf 'git@github.com:%s.git' "$repo" ;;
    esac
}

# push_log <repo> <branch> <rel_path> <content>: write the log into a cached
# clone of the repo and push it. Prints a reference to the pushed log.
# Returns non-zero on any git failure.
push_log() {
    local repo="$1" branch="$2" rel_path="$3" content="$4"
    command -v git >/dev/null 2>&1 || return 1

    local url slug cache
    url=$(resolve_repo_url "$repo")
    slug=$(printf '%s' "$repo" | sed -E 's#[^A-Za-z0-9._-]+#_#g')
    cache="$CONDUCTOR_HOME/upload-cache/$slug"

    # Ensure a clone exists. Clone branch-agnostically so a brand-new empty
    # repo (no branches yet) still succeeds.
    if [ ! -d "$cache/.git" ]; then
        rm -rf "$cache"
        mkdir -p "$(dirname "$cache")"
        git clone --quiet --depth 1 "$url" "$cache" 2>/dev/null || return 1
    fi

    # Check out the target branch: base it on origin/$branch only when the fetch
    # actually succeeded (branch exists remotely). Keying off the fetch exit code
    # instead of a possibly-stale FETCH_HEAD avoids basing the branch on an old
    # ref when the fetch fails (network blip / branch removed / config change).
    if git -C "$cache" fetch --quiet --depth 1 origin "$branch" 2>/dev/null; then
        git -C "$cache" checkout --quiet -B "$branch" FETCH_HEAD 2>/dev/null || return 1
    else
        git -C "$cache" checkout --quiet -B "$branch" 2>/dev/null || return 1
    fi

    local target="$cache/$rel_path"
    mkdir -p "$(dirname "$target")" || return 1
    printf '%s\n' "$content" > "$target" || return 1

    git -C "$cache" add "$rel_path" 2>/dev/null || return 1
    # Commit only when the file actually changed; an identical re-upload is a
    # no-op success rather than a "nothing to commit" failure that would block dd.
    if ! git -C "$cache" diff --cached --quiet 2>/dev/null; then
        git -C "$cache" \
            -c user.email="conductor@local" -c user.name="claude-conductor" \
            commit --quiet -m "chore: add work log $rel_path" 2>/dev/null || return 1
    fi
    git -C "$cache" push --quiet -u origin "$branch" 2>/dev/null || return 1

    local sha
    sha=$(git -C "$cache" rev-parse HEAD 2>/dev/null)
    case "$repo" in
        *://*|git@*|/*|./*|../*) printf '%s @ %s\n' "$rel_path" "$sha" ;;
        *) printf 'https://github.com/%s/blob/%s/%s\n' "$repo" "$branch" "$rel_path" ;;
    esac
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

CONFIG_FILE=$(load_config)
UPLOAD_ENABLED=$(jq -r '.upload.enabled // false' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_REPO=$(jq -r '.upload.repo // ""' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_BASE_DIR=$(jq -r '.upload.base_dir // "work-log"' "$CONFIG_FILE" 2>/dev/null)
UPLOAD_BRANCH=$(jq -r '.upload.branch // "main"' "$CONFIG_FILE" 2>/dev/null)

# Skip silently (success) when upload is disabled or no repository is configured.
if [ "$UPLOAD_ENABLED" != "true" ] || [ -z "$UPLOAD_REPO" ]; then
    exit 0
fi

# Locate the pending file for this tab to get its transcript path.
# No pending file -> nothing to upload (not an error).
PENDING_FILE=$(find_pending_file "$PENDING_DIR" "$TAB_NAME") || exit 0
TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' "$PENDING_FILE" 2>/dev/null)

# Use the summary record for this tab. record-output.sh normally wrote it to
# today's file just before this runs, but scan every daily file (they are named
# YYYY-MM-DD.jsonl, so the glob is chronological) and keep the last match. This
# finds the record even when completion and deletion fall on different days or
# the date rolls over between record-output.sh and this script.
RECORD=""
for df in "$DAILY_DIR"/*.jsonl; do
    [ -f "$df" ] || continue
    r=$(jq -c --arg tab "$TAB_NAME" 'select(.tab == $tab)' "$df" 2>/dev/null | tail -1)
    [ -n "$r" ] && RECORD="$r"
done
if [ -z "$RECORD" ]; then
    RECORD=$(jq -n --arg tab "$TAB_NAME" --arg session "$SESSION_NAME" \
        '{tab:$tab, session:$session, completed_at:"", summary:null, markers:{}}')
fi

COMPLETED_AT=$(printf '%s' "$RECORD" | jq -r '.completed_at // empty')
[ -n "$COMPLETED_AT" ] || COMPLETED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')

# Generate the conversation summary. Failure MUST abort dd (exit non-zero).
SUMMARY_TEXT=$(generate_summary "$TRANSCRIPT_PATH")
if [ $? -ne 0 ] || [ -z "$SUMMARY_TEXT" ]; then
    echo "upload-log: 会話要約の生成に失敗しました（ddを中止します）" >&2
    exit 1
fi

REL_PATH=$(build_log_path "$UPLOAD_BASE_DIR" "$COMPLETED_AT" "$TAB_NAME")
MARKDOWN=$(build_markdown "$RECORD" "$SUMMARY_TEXT")

# Push to the log repository. Failure MUST abort dd (exit non-zero).
REF=$(push_log "$UPLOAD_REPO" "$UPLOAD_BRANCH" "$REL_PATH" "$MARKDOWN")
if [ $? -ne 0 ]; then
    echo "upload-log: ログリポジトリへのpushに失敗しました（ddを中止します）" >&2
    exit 1
fi

echo "upload-log: アップロードしました -> $REF"
exit 0
