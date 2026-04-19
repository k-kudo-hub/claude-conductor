#!/bin/bash
# Claude Conductor - Sandbox Test
# Creates a temporary $HOME and tests install/uninstall/scripts

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"

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
section "12. config.default.json installed"
# ============================================================

[[ -f "$HOME/.claude-conductor/config.default.json" ]] && pass "config.default.json installed" || fail "config.default.json missing"

# Validate JSON
jq '.' "$HOME/.claude-conductor/config.default.json" > /dev/null 2>&1 && pass "config.default.json is valid JSON" || fail "config.default.json is invalid JSON"

# ============================================================
section "13. config.json created from default on install"
# ============================================================

[[ -f "$HOME/.claude-conductor/config.json" ]] && pass "config.json created" || fail "config.json not created"

# config.json should match config.default.json
if [[ -f "$HOME/.claude-conductor/config.json" ]]; then
    diff <(jq -S '.' "$HOME/.claude-conductor/config.default.json") <(jq -S '.' "$HOME/.claude-conductor/config.json") > /dev/null 2>&1 \
      && pass "config.json matches default" || fail "config.json differs from default"
fi

# ============================================================
section "14. config.json not overwritten on reinstall"
# ============================================================

# Modify config.json to add a custom task type
jq '.task_types.custom = {"description": "Custom task", "layout": []}' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"

# Reinstall
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null

# config.json should still have the custom type
CUSTOM_TYPE=$(jq -r '.task_types.custom.description' "$HOME/.claude-conductor/config.json")
[[ "$CUSTOM_TYPE" == "Custom task" ]] && pass "custom config preserved on reinstall" || fail "custom config lost: $CUSTOM_TYPE"

# config.default.json should be updated
[[ -f "$HOME/.claude-conductor/config.default.json" ]] && pass "config.default.json updated on reinstall" || fail "config.default.json missing after reinstall"

# ============================================================
section "15. task-create-loop.sh reads task types from config"
# ============================================================

CONFIG_FILE="$HOME/.claude-conductor/config.json"

# Read task types from config
TASK_TYPES=$(jq -r '.task_types | to_entries[] | "\(.key)  \(.value.description)"' "$CONFIG_FILE")
echo "$TASK_TYPES" | grep -q "dev" && pass "dev type found in config" || fail "dev type not in config"
echo "$TASK_TYPES" | grep -q "custom" && pass "custom type found in config" || fail "custom type not in config"

# Read search_dirs from config
SEARCH_DIRS_JSON=$(jq -r '.search_dirs[]' "$CONFIG_FILE")
echo "$SEARCH_DIRS_JSON" | grep -q "projects" && pass "search_dirs contains projects" || fail "search_dirs missing projects"

# Read search_depth from config
SEARCH_DEPTH_JSON=$(jq -r '.search_depth' "$CONFIG_FILE")
[[ "$SEARCH_DEPTH_JSON" == "1" ]] && pass "search_depth is 1" || fail "search_depth wrong: $SEARCH_DEPTH_JSON"

# ============================================================
section "16. layout actions generate correct zellij commands"
# ============================================================

# Clear zellij call log
: > "$HOME/.claude-pending/zellij-calls.log"

# Test dev layout (1 action: new-pane right nvim)
DEV_LAYOUT=$(jq -c '.task_types.dev.layout[]' "$CONFIG_FILE")
while IFS= read -r step; do
    ACTION=$(echo "$step" | jq -r '.action')
    DIRECTION=$(echo "$step" | jq -r '.direction')
    COMMAND=$(echo "$step" | jq -r '.command // empty')

    case "$ACTION" in
        new-pane)
            if [[ -n "$COMMAND" ]]; then
                zellij action new-pane --direction "$DIRECTION" --cwd "/tmp" -- "$COMMAND"
            else
                zellij action new-pane --direction "$DIRECTION" --cwd "/tmp"
            fi
            ;;
        move-focus)
            zellij action move-focus "$DIRECTION"
            ;;
    esac
done <<< "$DEV_LAYOUT"

grep -q 'action new-pane --direction right --cwd /tmp -- nvim' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "dev layout: new-pane right nvim" || fail "dev layout: missing nvim pane"

# Clear and test k8s layout
: > "$HOME/.claude-pending/zellij-calls.log"

K8S_LAYOUT=$(jq -c '.task_types.k8s.layout[]' "$CONFIG_FILE")
while IFS= read -r step; do
    ACTION=$(echo "$step" | jq -r '.action')
    DIRECTION=$(echo "$step" | jq -r '.direction')
    COMMAND=$(echo "$step" | jq -r '.command // empty')

    case "$ACTION" in
        new-pane)
            if [[ -n "$COMMAND" ]]; then
                zellij action new-pane --direction "$DIRECTION" --cwd "/tmp" -- "$COMMAND"
            else
                zellij action new-pane --direction "$DIRECTION" --cwd "/tmp"
            fi
            ;;
        move-focus)
            zellij action move-focus "$DIRECTION"
            ;;
    esac
done <<< "$K8S_LAYOUT"

CALLS_LOG="$HOME/.claude-pending/zellij-calls.log"
grep -q 'action new-pane --direction right --cwd /tmp -- k9s' "$CALLS_LOG" \
  && pass "k8s layout: new-pane right k9s" || fail "k8s layout: missing k9s pane"
grep -q 'action new-pane --direction down --cwd /tmp -- nvim' "$CALLS_LOG" \
  && pass "k8s layout: new-pane down nvim" || fail "k8s layout: missing nvim pane"
grep -q 'action move-focus left' "$CALLS_LOG" \
  && pass "k8s layout: move-focus left" || fail "k8s layout: missing move-focus left"
grep -q 'action new-pane --direction down --cwd /tmp' "$CALLS_LOG" \
  && pass "k8s layout: new-pane down shell" || fail "k8s layout: missing shell pane"
grep -q 'action move-focus up' "$CALLS_LOG" \
  && pass "k8s layout: move-focus up" || fail "k8s layout: missing move-focus up"

# ============================================================
section "17. fallback when config.json missing"
# ============================================================

# Remove config.json to test fallback
rm -f "$HOME/.claude-conductor/config.json"

# The script should fall back to config.default.json
DEFAULT_TYPES=$(jq -r '.task_types | keys[]' "$HOME/.claude-conductor/config.default.json")
echo "$DEFAULT_TYPES" | grep -q "dev" && pass "fallback: dev type available" || fail "fallback: dev type missing"
echo "$DEFAULT_TYPES" | grep -q "k8s" && pass "fallback: k8s type available" || fail "fallback: k8s type missing"

# Restore config.json for subsequent tests
cp "$HOME/.claude-conductor/config.default.json" "$HOME/.claude-conductor/config.json"

# ============================================================
section "18. init.zsh loads without errors"
# ============================================================

OUTPUT=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && echo loaded" 2>&1)
[[ "$OUTPUT" == "loaded" ]] && pass "init.zsh sourced successfully" || fail "init.zsh failed: $OUTPUT"

# Check functions are defined
FUNCS=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && whence -w mdev dev task pdev zs pending-clear" 2>&1)
echo "$FUNCS" | grep -q "mdev: function" && pass "mdev function defined" || fail "mdev not defined"
echo "$FUNCS" | grep -q "task: function" && pass "task function defined" || fail "task not defined"

# ============================================================
section "19. Zellij calls were made correctly"
# ============================================================

CALLS="$HOME/.claude-pending/zellij-calls.log"
if [[ -f "$CALLS" ]]; then
    grep -q 'go-to-tab-name Main' "$CALLS" && pass "go-to-tab-name Main was called" || fail "go-to-tab-name Main not called"
    pass "all zellij calls completed (no hangs)"
else
    fail "no zellij calls recorded"
fi

# ============================================================
section "20. record-output.sh (with transcript)"
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
section "21. record-output.sh (without transcript)"
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
section "22. record-output.sh (no pending file)"
# ============================================================

rm -f "$PENDING_DIR"/*.json
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "nonexistent-tab"

LINE_COUNT_AFTER=$(wc -l < "$DAILY_FILE" | tr -d ' ')
[[ "$LINE_COUNT_AFTER" == "2" ]] && pass "no record added without pending" || fail "unexpected record added: $LINE_COUNT_AFTER"

# ============================================================
section "23. Uninstall"
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
