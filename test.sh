#!/bin/bash
# Claude Conductor - Sandbox Test
# Creates a temporary $HOME and tests install/uninstall/scripts

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"
export CONDUCTOR_HOME="$HOME/.claude-conductor"

PASS=0
FAIL=0

pass() { echo -e "  \033[0;32m✓\033[0m $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  \033[0;31m✗\033[0m $1"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo -e "\033[1m=== $1 ===\033[0m"; }

cleanup() {
    rm -rf "$SANDBOX"
    echo ""
    echo -e "\033[1mResults: ${PASS} passed, ${FAIL} failed\033[0m"
    if [[ $FAIL -gt 0 ]]; then exit 1; fi
}
trap cleanup EXIT

# Create a mock zellij that records calls but doesn't hang
MOCK_BIN="$SANDBOX/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
MOCK
chmod +x "$MOCK_BIN/zellij"
export PATH="$MOCK_BIN:$PATH"

# ============================================================
section "1. Install (fresh environment)"
# ============================================================

# Pre-create minimal claude settings to test merge
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Bash", "Read"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "echo pre"}]
      }
    ]
  }
}
EOF

# Run install (non-interactive: skip .zshrc prompt)
touch "$HOME/.zshrc"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null

# Check file placement
[[ -f "$HOME/.claude-conductor/scripts/dashboard-loop.sh" ]] && pass "dashboard-loop.sh installed" || fail "dashboard-loop.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/pending-notify.sh" ]] && pass "pending-notify.sh installed" || fail "pending-notify.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/pending-resolve.sh" ]] && pass "pending-resolve.sh installed" || fail "pending-resolve.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/pending-post-tool.sh" ]] && pass "pending-post-tool.sh installed" || fail "pending-post-tool.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/task-control.sh" ]] && pass "task-control.sh installed" || fail "task-control.sh missing"
[[ -f "$HOME/.claude-conductor/layouts/multi.kdl" ]] && pass "multi.kdl installed" || fail "multi.kdl missing"
[[ -f "$HOME/.claude-conductor/layouts/dev.kdl" ]] && pass "dev.kdl installed" || fail "dev.kdl missing"
[[ -f "$HOME/.claude-conductor/init.zsh" ]] && pass "init.zsh installed" || fail "init.zsh missing"
[[ -x "$HOME/.claude-conductor/scripts/dashboard-loop.sh" ]] && pass "scripts are executable" || fail "scripts not executable"

# ============================================================
section "2. Hooks merge"
# ============================================================

# Check that existing hooks are preserved
PRE_TOOL=$(jq -r '.hooks.PreToolUse' "$HOME/.claude/settings.json")
[[ "$PRE_TOOL" != "null" ]] && pass "existing PreToolUse hook preserved" || fail "existing PreToolUse hook lost"

# Check that conductor hooks were added
NOTIFICATION=$(jq -r '.hooks.Notification' "$HOME/.claude/settings.json")
[[ "$NOTIFICATION" != "null" ]] && pass "Notification hook added" || fail "Notification hook missing"

STOP=$(jq -r '.hooks.Stop' "$HOME/.claude/settings.json")
[[ "$STOP" != "null" ]] && pass "Stop hook added" || fail "Stop hook missing"

POST_TOOL=$(jq -r '.hooks.PostToolUse' "$HOME/.claude/settings.json")
[[ "$POST_TOOL" != "null" ]] && pass "PostToolUse hook added" || fail "PostToolUse hook missing"

USER_PROMPT=$(jq -r '.hooks.UserPromptSubmit' "$HOME/.claude/settings.json")
[[ "$USER_PROMPT" != "null" ]] && pass "UserPromptSubmit hook added" || fail "UserPromptSubmit hook missing"

# Check that non-hooks settings are preserved
PERMS=$(jq -r '.permissions.allow[0]' "$HOME/.claude/settings.json")
[[ "$PERMS" == "Bash" ]] && pass "existing permissions preserved" || fail "permissions lost"

# Check that hook commands use CONDUCTOR_HOME variable
HOOK_CMD=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$HOME/.claude/settings.json")
[[ "$HOOK_CMD" == *'${CONDUCTOR_HOME:-$HOME/.claude-conductor}'* ]] \
  && pass "hook command uses CONDUCTOR_HOME variable" \
  || fail "hook command does not use CONDUCTOR_HOME: $HOOK_CMD"

# ============================================================
section "3. pending-notify.sh (Notification event)"
# ============================================================

PENDING_DIR="$HOME/.claude-pending/test-session"

echo '{"session_id":"sess-aaa","message":"Permission needed","hook_event_name":"Notification","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

[[ -f "$PENDING_DIR/sess-aaa.json" ]] && pass "pending file created" || fail "pending file not created"

TAB=$(jq -r '.tab' "$PENDING_DIR/sess-aaa.json")
[[ "$TAB" == "api-feature" ]] && pass "tab name from TASK_TAB_NAME" || fail "tab name wrong: $TAB"

EVENT=$(jq -r '.event' "$PENDING_DIR/sess-aaa.json")
[[ "$EVENT" == "Notification" ]] && pass "event is Notification" || fail "event wrong: $EVENT"

# ============================================================
section "4. pending-notify.sh (Stop does not overwrite Notification)"
# ============================================================

echo '{"session_id":"sess-aaa","message":"Task done","hook_event_name":"Stop","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

EVENT_AFTER=$(jq -r '.event' "$PENDING_DIR/sess-aaa.json")
[[ "$EVENT_AFTER" == "Notification" ]] && pass "Stop did not overwrite Notification" || fail "Stop overwrote Notification: $EVENT_AFTER"

# ============================================================
section "5. pending-notify.sh (Stop creates new entry)"
# ============================================================

echo '{"session_id":"sess-bbb","message":"Review done","hook_event_name":"Stop","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=review-pr \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

[[ -f "$PENDING_DIR/sess-bbb.json" ]] && pass "Stop pending created for new session" || fail "Stop pending not created"

EVENT_B=$(jq -r '.event' "$PENDING_DIR/sess-bbb.json")
[[ "$EVENT_B" == "Stop" ]] && pass "event is Stop" || fail "event wrong: $EVENT_B"

# ============================================================
section "6. pending-notify.sh (fallback tab name from cwd)"
# ============================================================

echo '{"session_id":"sess-ccc","message":"test","hook_event_name":"Notification","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

TAB_FALLBACK=$(jq -r '.tab' "$PENDING_DIR/sess-ccc.json")
[[ "$TAB_FALLBACK" == "myapp" ]] && pass "tab name fallback to cwd basename" || fail "fallback wrong: $TAB_FALLBACK"

# ============================================================
section "7. pending-post-tool.sh (resolves Notification only)"
# ============================================================

# sess-aaa is Notification, sess-bbb is Stop
echo '{"session_id":"sess-aaa"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-post-tool.sh"

[[ ! -f "$PENDING_DIR/sess-aaa.json" ]] && pass "Notification pending resolved by PostToolUse" || fail "Notification pending NOT resolved"

echo '{"session_id":"sess-bbb"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-post-tool.sh"

[[ -f "$PENDING_DIR/sess-bbb.json" ]] && pass "Stop pending NOT resolved by PostToolUse" || fail "Stop pending was incorrectly resolved"

# ============================================================
section "8. pending-resolve.sh (resolves any pending)"
# ============================================================

echo '{"session_id":"sess-bbb"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-resolve.sh"

[[ ! -f "$PENDING_DIR/sess-bbb.json" ]] && pass "Stop pending resolved by UserPromptSubmit" || fail "Stop pending NOT resolved"

# ============================================================
section "9. pending-resolve.sh (returns to Main even without pending file)"
# ============================================================

# Clear zellij call log to isolate this test
: > "$HOME/.claude-pending/zellij-calls.log"

echo '{"session_id":"sess-nonexistent"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-resolve.sh"

pass "no error on missing pending file"
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "go-to-tab-name Main called without pending file" \
  || fail "go-to-tab-name Main NOT called without pending file"

# ============================================================
section "10. CONDUCTOR_HOME overrides script path"
# ============================================================

# Create an alternate conductor home with a custom pending-resolve.sh
ALT_HOME="$SANDBOX/alt-conductor"
mkdir -p "$ALT_HOME/scripts"
cat > "$ALT_HOME/scripts/pending-resolve.sh" << 'ALTSCRIPT'
#!/bin/bash
echo "alt-conductor-resolve" >> "$HOME/.claude-pending/alt-calls.log"
ALTSCRIPT
chmod +x "$ALT_HOME/scripts/pending-resolve.sh"

CONDUCTOR_HOME="$ALT_HOME" bash -c '${CONDUCTOR_HOME:-$HOME/.claude-conductor}/scripts/pending-resolve.sh'

[[ -f "$HOME/.claude-pending/alt-calls.log" ]] \
  && pass "CONDUCTOR_HOME override used alternate script" \
  || fail "CONDUCTOR_HOME override did not use alternate script"

# ============================================================
section "11. pending-notify.sh (no-op without session_id)"
# ============================================================

echo '{"message":"no session id"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

FILE_COUNT=$(ls "$PENDING_DIR" 2>/dev/null | wc -l | tr -d ' ')
[[ "$FILE_COUNT" -eq 1 ]] && pass "no file created without session_id" || fail "unexpected file count: $FILE_COUNT"

# ============================================================
section "12. init.zsh loads without errors"
# ============================================================

OUTPUT=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && echo loaded" 2>&1)
[[ "$OUTPUT" == "loaded" ]] && pass "init.zsh sourced successfully" || fail "init.zsh failed: $OUTPUT"

# Check functions are defined
FUNCS=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && whence -w mdev dev zs pending-clear" 2>&1)
echo "$FUNCS" | grep -q "mdev: function" && pass "mdev function defined" || fail "mdev not defined"
echo "$FUNCS" | grep -q "dev: function" && pass "dev function defined" || fail "dev not defined"

# ============================================================
section "13. Zellij calls were made correctly"
# ============================================================

CALLS="$HOME/.claude-pending/zellij-calls.log"
if [[ -f "$CALLS" ]]; then
    grep -q 'go-to-tab-name Main' "$CALLS" && pass "go-to-tab-name Main was called" || fail "go-to-tab-name Main not called"
    pass "all zellij calls completed (no hangs)"
else
    fail "no zellij calls recorded"
fi

# ============================================================
section "14. record-output.sh (with transcript)"
# ============================================================

# Re-install for record-output tests
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null

DAILY_DIR="$HOME/.claude-conductor/daily/test-session"
DAILY_FILE="$DAILY_DIR/$(date '+%Y-%m-%d').jsonl"
PENDING_DIR="$HOME/.claude-pending/test-session"
mkdir -p "$PENDING_DIR"

# Create a mock transcript file (JSONL format)
MOCK_TRANSCRIPT="$SANDBOX/mock-transcript.jsonl"
cat > "$MOCK_TRANSCRIPT" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp/myapp","sessionId":"sess-rec","uuid":"u1","timestamp":"2026-04-18T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-04-18T10:00:01Z"}
{"type":"user","message":{"role":"user","content":"fix the bug"},"cwd":"/tmp/myapp","sessionId":"sess-rec","uuid":"u2","timestamp":"2026-04-18T10:00:02Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/app.ts"}},{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/README.md"}}],"usage":{"input_tokens":200,"output_tokens":100}},"uuid":"a2","timestamp":"2026-04-18T10:00:03Z"}
{"type":"user","message":{"role":"user","content":"send to slack"},"cwd":"/tmp/myapp","sessionId":"sess-rec","uuid":"u3","timestamp":"2026-04-18T10:00:04Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"mcp__slack__send_message","input":{"channel":"general","text":"done"}}],"usage":{"input_tokens":150,"output_tokens":75}},"uuid":"a3","timestamp":"2026-04-18T10:00:05Z"}
TRANSCRIPT

# Create pending file with transcript_path
cat > "$PENDING_DIR/sess-rec.json" << EOF
{
  "tab": "record-test",
  "session": "test-session",
  "claude_session_id": "sess-rec",
  "message": "Task complete",
  "event": "Stop",
  "time": "10:00:05",
  "transcript_path": "$MOCK_TRANSCRIPT"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "record-test"

[[ -f "$DAILY_FILE" ]] && pass "daily log file created" || fail "daily log file not created"

if [[ -f "$DAILY_FILE" ]]; then
    RECORD=$(cat "$DAILY_FILE")
    TAB_REC=$(echo "$RECORD" | jq -r '.tab')
    [[ "$TAB_REC" == "record-test" ]] && pass "tab name recorded" || fail "tab name wrong: $TAB_REC"

    TURNS=$(echo "$RECORD" | jq -r '.summary.total_turns')
    [[ "$TURNS" == "3" ]] && pass "total_turns=3" || fail "total_turns wrong: $TURNS"

    CALLS=$(echo "$RECORD" | jq -r '.summary.total_tool_calls')
    [[ "$CALLS" == "3" ]] && pass "total_tool_calls=3" || fail "total_tool_calls wrong: $CALLS"

    SLACK=$(echo "$RECORD" | jq -r '.markers.slack')
    [[ "$SLACK" == "true" ]] && pass "slack marker detected" || fail "slack marker not detected: $SLACK"

    DOC=$(echo "$RECORD" | jq -r '.markers.doc')
    [[ "$DOC" == "true" ]] && pass "doc marker detected" || fail "doc marker not detected: $DOC"
fi

# ============================================================
section "15. record-output.sh (without transcript)"
# ============================================================

cat > "$PENDING_DIR/sess-notranscript.json" << 'EOF'
{
  "tab": "no-transcript",
  "session": "test-session",
  "claude_session_id": "sess-notranscript",
  "message": "Quick task",
  "event": "Stop",
  "time": "11:00:00"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "no-transcript"

LINE_COUNT=$(wc -l < "$DAILY_FILE" | tr -d ' ')
[[ "$LINE_COUNT" == "2" ]] && pass "second record appended" || fail "line count wrong: $LINE_COUNT"

RECORD2=$(tail -1 "$DAILY_FILE")
SUMMARY2=$(echo "$RECORD2" | jq -r '.summary')
[[ "$SUMMARY2" == "null" ]] && pass "summary is null without transcript" || fail "summary not null: $SUMMARY2"

MARKERS2=$(echo "$RECORD2" | jq -r '.markers.merged')
[[ "$MARKERS2" == "false" ]] && pass "markers default to false" || fail "markers not false: $MARKERS2"

# ============================================================
section "16. record-output.sh (no pending file)"
# ============================================================

rm -f "$PENDING_DIR"/*.json
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "nonexistent-tab"

LINE_COUNT_AFTER=$(wc -l < "$DAILY_FILE" | tr -d ' ')
[[ "$LINE_COUNT_AFTER" == "2" ]] && pass "no record added without pending" || fail "unexpected record added: $LINE_COUNT_AFTER"

# ============================================================
section "17. fetch-news.sh (successful fetch)"
# ============================================================

# Re-install for news tests
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null

# Create a mock curl that returns fake TechCrunch RSS response
cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
cat << 'RSS'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>TechCrunch AI</title>
<item><title><![CDATA[GPT-5 Released with Major Improvements]]></title><link>https://techcrunch.com/gpt5</link><description><![CDATA[OpenAI has released GPT-5 with significant performance gains across all benchmarks.]]></description></item>
<item><title><![CDATA[Claude 4.6 Beats All Benchmarks]]></title><link>https://techcrunch.com/claude</link><description><![CDATA[Anthropic Claude 4.6 sets new records in reasoning and coding tasks.]]></description></item>
<item><title><![CDATA[Open Source LLM Surpasses Commercial Models]]></title><link>https://techcrunch.com/open-llm?ref=rss&amp;utm=ai</link><description><![CDATA[A new open-source model outperforms proprietary alternatives.]]></description></item>
<item><title><![CDATA[AI Chip Startup Raises 1B]]></title><link>https://techcrunch.com/ai-chip</link><description><![CDATA[Startup secures <a href="https://example.com">massive funding</a> for next-gen AI processors.]]></description></item>
<item><title><![CDATA[New AI Safety Framework Proposed]]></title><link>https://techcrunch.com/ai-safety</link><description><![CDATA[Researchers propose
comprehensive guidelines for safe
AI deployment.]]></description></item>
</channel>
</rss>
RSS
MOCKCURL
chmod +x "$MOCK_BIN/curl"

NEWS_DIR="$HOME/.claude-conductor/news"
rm -rf "$NEWS_DIR"

bash "$HOME/.claude-conductor/scripts/fetch-news.sh"

NEWS_FILE="$NEWS_DIR/$(date '+%Y-%m-%d').json"
[[ -f "$NEWS_FILE" ]] && pass "news file created" || fail "news file not created"

if [[ -f "$NEWS_FILE" ]]; then
    NEWS_COUNT=$(jq -r '.items | length' "$NEWS_FILE")
    [[ "$NEWS_COUNT" == "5" ]] && pass "5 news items saved" || fail "news count wrong: $NEWS_COUNT"

    FIRST_TITLE=$(jq -r '.items[0].title' "$NEWS_FILE")
    [[ "$FIRST_TITLE" == "GPT-5 Released with Major Improvements" ]] && pass "first title correct" || fail "first title wrong: $FIRST_TITLE"

    FIRST_URL=$(jq -r '.items[0].url' "$NEWS_FILE")
    [[ "$FIRST_URL" == "https://techcrunch.com/gpt5" ]] && pass "first url correct" || fail "first url wrong: $FIRST_URL"

    FIRST_DESC=$(jq -r '.items[0].description' "$NEWS_FILE")
    [[ "$FIRST_DESC" == *"GPT-5"* ]] && pass "description contains content" || fail "description wrong: $FIRST_DESC"

    # Verify HTML tags with quotes are stripped and JSON remains valid
    CHIP_DESC=$(jq -r '.items[3].description' "$NEWS_FILE")
    [[ "$CHIP_DESC" != *"<a "* ]] && pass "HTML tags stripped from description" || fail "HTML tags remain: $CHIP_DESC"
    jq '.' "$NEWS_FILE" > /dev/null 2>&1 && pass "JSON is valid after HTML stripping" || fail "JSON is invalid"

    # Verify newlines in CDATA are replaced with spaces
    SAFETY_DESC=$(jq -r '.items[4].description' "$NEWS_FILE")
    [[ "$SAFETY_DESC" != *$'\n'* ]] && pass "newlines removed from description" || fail "newlines remain in description"

    # Verify URL with query params is preserved and JSON is valid
    LLM_URL=$(jq -r '.items[2].url' "$NEWS_FILE")
    [[ "$LLM_URL" == *"ref=rss"* ]] && pass "URL with query params preserved" || fail "URL wrong: $LLM_URL"
fi

# ============================================================
section "18. fetch-news.sh (skips if today's file exists)"
# ============================================================

# Modify existing file to detect re-fetch
if [[ -f "$NEWS_FILE" ]]; then
    jq '.items[0].title = "CACHED"' "$NEWS_FILE" > "${NEWS_FILE}.tmp"
    mv "${NEWS_FILE}.tmp" "$NEWS_FILE"

    bash "$HOME/.claude-conductor/scripts/fetch-news.sh"

    CACHED_TITLE=$(jq -r '.items[0].title' "$NEWS_FILE")
    [[ "$CACHED_TITLE" == "CACHED" ]] && pass "skipped fetch when today's file exists" || fail "re-fetched despite existing file: $CACHED_TITLE"
else
    fail "news file missing from previous test"
fi

# ============================================================
section "19. fetch-news.sh (handles API failure gracefully)"
# ============================================================

# Replace curl mock with one that fails
cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
exit 1
MOCKCURL
chmod +x "$MOCK_BIN/curl"

# Remove existing file to force fetch
rm -f "$NEWS_FILE"

bash "$HOME/.claude-conductor/scripts/fetch-news.sh"
EXIT_CODE=$?

[[ $EXIT_CODE -eq 0 ]] && pass "fetch-news.sh exits 0 on API failure" || fail "fetch-news.sh exits non-zero: $EXIT_CODE"
[[ ! -f "$NEWS_FILE" ]] && pass "no news file on API failure" || fail "news file created despite failure"

# Test that invalid XML does not create empty/broken file
cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
echo "not valid xml at all"
MOCKCURL
chmod +x "$MOCK_BIN/curl"

rm -f "$NEWS_FILE"
bash "$HOME/.claude-conductor/scripts/fetch-news.sh"

if [[ -f "$NEWS_FILE" ]]; then
    FILE_SIZE=$(wc -c < "$NEWS_FILE" | tr -d ' ')
    [[ "$FILE_SIZE" -gt 2 ]] && pass "no empty file on invalid XML" || fail "empty/tiny file created: ${FILE_SIZE} bytes"
    rm -f "$NEWS_FILE"
else
    pass "no file on invalid XML"
fi

# Restore working curl mock for cleanup test
cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
cat << 'RSS'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>TC</title>
<item><title><![CDATA[Test]]></title><link>https://example.com</link><description><![CDATA[desc]]></description></item>
</channel></rss>
RSS
MOCKCURL
chmod +x "$MOCK_BIN/curl"

# Create an old news file (simulate 10 days ago)
OLD_FILE="$NEWS_DIR/2026-01-01.json"
echo '{"items":[]}' > "$OLD_FILE"
touch -t 202601010000 "$OLD_FILE"

# Run fetch (today's file missing, triggers fetch + cleanup)
rm -f "$NEWS_FILE"
bash "$HOME/.claude-conductor/scripts/fetch-news.sh"

[[ ! -f "$OLD_FILE" ]] && pass "old news file cleaned up" || fail "old news file still exists"

# ============================================================
section "20. news-loop.sh (displays news from file)"
# ============================================================

# Create news file for display test
mkdir -p "$NEWS_DIR"
cat > "$NEWS_FILE" << 'NEWSJSON'
{
  "items": [
    {
      "title": "GPT-5 Released with Major Improvements",
      "url": "https://techcrunch.com/gpt5",
      "description": "OpenAI has released GPT-5 with significant gains."
    },
    {
      "title": "Claude 4.6 Beats All Benchmarks",
      "url": "https://techcrunch.com/claude",
      "description": "Anthropic Claude 4.6 sets new records."
    }
  ]
}
NEWSJSON

# Run news-loop.sh in single-pass mode for testing
OUTPUT=$(CONDUCTOR_NEWS_ONCE=1 bash "$HOME/.claude-conductor/scripts/news-loop.sh" 2>/dev/null)

echo "$OUTPUT" | grep -q "GPT-5 Released" && pass "news title displayed" || fail "news title not displayed"
echo "$OUTPUT" | grep -q "OpenAI has released" && pass "description displayed" || fail "description not displayed"
echo "$OUTPUT" | grep -q "Claude 4.6" && pass "second item displayed" || fail "second item not displayed"

# ============================================================
section "21. news-loop.sh (handles missing news file)"
# ============================================================

rm -f "$NEWS_FILE"

OUTPUT=$(CONDUCTOR_NEWS_ONCE=1 bash "$HOME/.claude-conductor/scripts/news-loop.sh" 2>/dev/null)

echo "$OUTPUT" | grep -qi "no news\|fetch" && pass "shows message when no news file" || fail "no fallback message: $OUTPUT"

# ============================================================
section "22. Uninstall"
# ============================================================

bash "$REPO_DIR/uninstall.sh" 2>/dev/null

[[ ! -d "$HOME/.claude-conductor" ]] && pass "~/.claude-conductor removed" || fail "~/.claude-conductor still exists"
[[ ! -d "$HOME/.claude-pending" ]] && pass "~/.claude-pending removed" || fail "~/.claude-pending still exists"

# Check hooks were removed from settings.json
NOTIF_AFTER=$(jq -r '.hooks.Notification // "removed"' "$HOME/.claude/settings.json")
[[ "$NOTIF_AFTER" == "removed" ]] && pass "Notification hook removed" || fail "Notification hook still present"

# Check non-conductor hooks are preserved
PRE_AFTER=$(jq -r '.hooks.PreToolUse' "$HOME/.claude/settings.json")
[[ "$PRE_AFTER" != "null" ]] && pass "PreToolUse hook preserved after uninstall" || fail "PreToolUse hook lost"

# Check settings.json backup exists
[[ -f "$HOME/.claude/settings.json.backup" ]] && pass "settings.json backup created" || fail "no backup created"
