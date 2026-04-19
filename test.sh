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
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME= \
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
        focus-previous-pane)
            zellij action focus-previous-pane
            ;;
    esac
done <<< "$DEV_LAYOUT"

grep -q 'action new-pane --direction right --cwd /tmp -- nvim' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "dev layout: new-pane right nvim" || fail "dev layout: missing nvim pane"
grep -q 'action focus-previous-pane' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "dev layout: focus-previous-pane" || fail "dev layout: missing focus-previous-pane"

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
FUNCS=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && whence -w mdev dev zs pending-clear" 2>&1)
echo "$FUNCS" | grep -q "mdev: function" && pass "mdev function defined" || fail "mdev not defined"
echo "$FUNCS" | grep -q "dev: function" && pass "dev function defined" || fail "dev not defined"

# ============================================================
section "19. Zellij calls were made correctly"
# ============================================================

CALLS="$HOME/.claude-pending/zellij-calls.log"
: > "$CALLS"

# Re-run pending-resolve to generate a fresh go-to-tab-name Main call
echo '{"session_id":"sess-verify"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-resolve.sh"

grep -q 'go-to-tab-name Main' "$CALLS" && pass "go-to-tab-name Main was called" || fail "go-to-tab-name Main not called"
pass "all zellij calls completed (no hangs)"

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
section "23. record-output.sh (merge detected via MCP tool)"
# ============================================================

# Clean daily file for fresh test
rm -f "$DAILY_FILE"

MOCK_TRANSCRIPT_MERGE_MCP="$SANDBOX/mock-transcript-merge-mcp.jsonl"
cat > "$MOCK_TRANSCRIPT_MERGE_MCP" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"merge the PR"},"cwd":"/tmp/myapp","sessionId":"sess-merge-mcp","uuid":"u1","timestamp":"2026-04-18T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"mcp__github__merge_pull_request","input":{"owner":"org","repo":"app","pullNumber":42}}],"usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-04-18T10:00:01Z"}
TRANSCRIPT

cat > "$PENDING_DIR/sess-merge-mcp.json" << EOF
{
  "tab": "merge-mcp-test",
  "session": "test-session",
  "claude_session_id": "sess-merge-mcp",
  "message": "PR merged",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$MOCK_TRANSCRIPT_MERGE_MCP"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "merge-mcp-test"

if [[ -f "$DAILY_FILE" ]]; then
    MERGED_MCP=$(jq -r '.markers.merged' "$DAILY_FILE")
    [[ "$MERGED_MCP" == "true" ]] && pass "merged marker via MCP tool" || fail "merged marker not set via MCP: $MERGED_MCP"
else
    fail "daily file not created for MCP merge test"
fi

# ============================================================
section "24. record-output.sh (merge detected via gh pr merge)"
# ============================================================

MOCK_TRANSCRIPT_MERGE_BASH="$SANDBOX/mock-transcript-merge-bash.jsonl"
cat > "$MOCK_TRANSCRIPT_MERGE_BASH" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"merge it"},"cwd":"/tmp/myapp","sessionId":"sess-merge-bash","uuid":"u1","timestamp":"2026-04-18T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr merge 42 --squash"}}],"usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-04-18T10:00:01Z"}
TRANSCRIPT

cat > "$PENDING_DIR/sess-merge-bash.json" << EOF
{
  "tab": "merge-bash-test",
  "session": "test-session",
  "claude_session_id": "sess-merge-bash",
  "message": "PR merged via CLI",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$MOCK_TRANSCRIPT_MERGE_BASH"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "merge-bash-test"

MERGED_BASH=$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')
[[ "$MERGED_BASH" == "true" ]] && pass "merged marker via gh pr merge" || fail "merged marker not set via Bash: $MERGED_BASH"

# ============================================================
section "25. record-output.sh (no merge markers)"
# ============================================================

MOCK_TRANSCRIPT_NO_MERGE="$SANDBOX/mock-transcript-no-merge.jsonl"
cat > "$MOCK_TRANSCRIPT_NO_MERGE" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"fix bug"},"cwd":"/tmp/myapp","sessionId":"sess-no-merge","uuid":"u1","timestamp":"2026-04-18T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/app.ts"}}],"usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-04-18T10:00:01Z"}
TRANSCRIPT

cat > "$PENDING_DIR/sess-no-merge.json" << EOF
{
  "tab": "no-merge-test",
  "session": "test-session",
  "claude_session_id": "sess-no-merge",
  "message": "Bug fixed",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$MOCK_TRANSCRIPT_NO_MERGE"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "no-merge-test"

MERGED_NONE=$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')
[[ "$MERGED_NONE" == "false" ]] && pass "merged marker false without merge" || fail "merged marker unexpectedly set: $MERGED_NONE"

# ============================================================
section "26a. record-output.sh (token cost calculation with cache tokens)"
# ============================================================

rm -f "$DAILY_FILE"

MOCK_TRANSCRIPT_COST="$SANDBOX/mock-transcript-cost.jsonl"
cat > "$MOCK_TRANSCRIPT_COST" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp","sessionId":"sess-cost","uuid":"u1","timestamp":"2026-04-19T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":500,"cache_read_input_tokens":10000,"cache_creation_input_tokens":5000,"cache_creation":{"ephemeral_5m_input_tokens":2000,"ephemeral_1h_input_tokens":3000},"speed":"standard"}},"uuid":"a1","timestamp":"2026-04-19T10:00:01Z"}
{"type":"user","message":{"role":"user","content":"more"},"cwd":"/tmp","sessionId":"sess-cost","uuid":"u2","timestamp":"2026-04-19T10:00:02Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":50,"output_tokens":300,"cache_read_input_tokens":15000,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0},"speed":"standard"}},"uuid":"a2","timestamp":"2026-04-19T10:00:03Z"}
TRANSCRIPT

# Expected cost for claude-opus-4-6 (standard speed):
# input:       150 * 5.0 / 1M = 0.000750
# output:      800 * 25.0 / 1M = 0.020000
# cache_5m:   3000 * 6.25 / 1M = 0.018750
# cache_1h:   3000 * 10.0 / 1M = 0.030000
# cache_read: 25000 * 0.5 / 1M = 0.012500
# total = 0.082000

cat > "$PENDING_DIR/sess-cost.json" << EOF
{
  "tab": "cost-test",
  "session": "test-session",
  "claude_session_id": "sess-cost",
  "message": "Cost test",
  "event": "Stop",
  "time": "10:00:03",
  "transcript_path": "$MOCK_TRANSCRIPT_COST"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cost-test"

if [[ -f "$DAILY_FILE" ]]; then
    COST_RECORD=$(cat "$DAILY_FILE")

    MODEL=$(echo "$COST_RECORD" | jq -r '.summary.model')
    [[ "$MODEL" == "claude-opus-4-6" ]] && pass "model detected" || fail "model wrong: $MODEL"

    SPEED=$(echo "$COST_RECORD" | jq -r '.summary.speed')
    [[ "$SPEED" == "standard" ]] && pass "speed detected" || fail "speed wrong: $SPEED"

    CACHE_READ=$(echo "$COST_RECORD" | jq -r '.summary.cache_read_tokens')
    [[ "$CACHE_READ" == "25000" ]] && pass "cache_read_tokens=25000" || fail "cache_read_tokens wrong: $CACHE_READ"

    CACHE_5M=$(echo "$COST_RECORD" | jq -r '.summary.cache_write_5m_tokens')
    [[ "$CACHE_5M" == "3000" ]] && pass "cache_write_5m_tokens=3000" || fail "cache_write_5m_tokens wrong: $CACHE_5M"

    CACHE_1H=$(echo "$COST_RECORD" | jq -r '.summary.cache_write_1h_tokens')
    [[ "$CACHE_1H" == "3000" ]] && pass "cache_write_1h_tokens=3000" || fail "cache_write_1h_tokens wrong: $CACHE_1H"

    COST=$(echo "$COST_RECORD" | jq -r '.summary.total_cost_usd')
    [[ "$COST" == "0.082" ]] && pass "total_cost_usd=0.082" || fail "total_cost_usd wrong: $COST"
else
    fail "daily file not created for cost test"
fi

# ============================================================
section "26b. record-output.sh (fast mode cost multiplier)"
# ============================================================

rm -f "$DAILY_FILE"

MOCK_TRANSCRIPT_FAST="$SANDBOX/mock-transcript-fast.jsonl"
cat > "$MOCK_TRANSCRIPT_FAST" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp","sessionId":"sess-fast","uuid":"u1","timestamp":"2026-04-19T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"speed":"fast"}},"uuid":"a1","timestamp":"2026-04-19T10:00:01Z"}
TRANSCRIPT

# Expected cost for fast mode (6x):
# input:  1000 * 5.0 * 6 / 1M = 0.030000
# output: 1000 * 25.0 * 6 / 1M = 0.150000
# total = 0.180000

cat > "$PENDING_DIR/sess-fast.json" << EOF
{
  "tab": "fast-test",
  "session": "test-session",
  "claude_session_id": "sess-fast",
  "message": "Fast mode test",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$MOCK_TRANSCRIPT_FAST"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "fast-test"

if [[ -f "$DAILY_FILE" ]]; then
    FAST_RECORD=$(cat "$DAILY_FILE")

    FAST_SPEED=$(echo "$FAST_RECORD" | jq -r '.summary.speed')
    [[ "$FAST_SPEED" == "fast" ]] && pass "fast speed detected" || fail "speed wrong: $FAST_SPEED"

    FAST_COST=$(echo "$FAST_RECORD" | jq -r '.summary.total_cost_usd')
    [[ "$FAST_COST" == "0.18" ]] && pass "fast mode cost=0.18 (6x)" || fail "fast mode cost wrong: $FAST_COST"
else
    fail "daily file not created for fast mode test"
fi

# ============================================================
section "26c. record-output.sh (sonnet model pricing)"
# ============================================================

rm -f "$DAILY_FILE"

MOCK_TRANSCRIPT_SONNET="$SANDBOX/mock-transcript-sonnet.jsonl"
cat > "$MOCK_TRANSCRIPT_SONNET" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"hello"},"cwd":"/tmp","sessionId":"sess-sonnet","uuid":"u1","timestamp":"2026-04-19T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"speed":"standard"}},"uuid":"a1","timestamp":"2026-04-19T10:00:01Z"}
TRANSCRIPT

# Expected cost for sonnet-4-6:
# input:  1000 * 3.0 / 1M = 0.003000
# output: 1000 * 15.0 / 1M = 0.015000
# total = 0.018000

cat > "$PENDING_DIR/sess-sonnet.json" << EOF
{
  "tab": "sonnet-test",
  "session": "test-session",
  "claude_session_id": "sess-sonnet",
  "message": "Sonnet test",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$MOCK_TRANSCRIPT_SONNET"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "sonnet-test"

if [[ -f "$DAILY_FILE" ]]; then
    SONNET_COST=$(cat "$DAILY_FILE" | jq -r '.summary.total_cost_usd')
    [[ "$SONNET_COST" == "0.018" ]] && pass "sonnet cost=0.018" || fail "sonnet cost wrong: $SONNET_COST"

    SONNET_MODEL=$(cat "$DAILY_FILE" | jq -r '.summary.model')
    [[ "$SONNET_MODEL" == "claude-sonnet-4-6" ]] && pass "sonnet model detected" || fail "sonnet model wrong: $SONNET_MODEL"
else
    fail "daily file not created for sonnet test"
fi

# ============================================================
section "26d. done-loop.sh (cost display format)"
# ============================================================

# Create a test daily file with known data
TEST_DAILY_DIR="$SANDBOX/test-done-daily/test-session"
mkdir -p "$TEST_DAILY_DIR"
TEST_DAILY_FILE="$TEST_DAILY_DIR/$(date '+%Y-%m-%d').jsonl"

cat > "$TEST_DAILY_FILE" << 'JSONL'
{"tab":"task-a","session":"s1","completed_at":"2026-04-19T10:05:00+0900","message":"done","summary":{"total_turns":3,"total_tool_calls":5,"total_cost_usd":1.85},"markers":{"merged":true,"slack":false,"doc":false}}
{"tab":"task-b","session":"s1","completed_at":"2026-04-19T11:30:00+0900","message":"done","summary":{"total_turns":10,"total_tool_calls":20,"total_cost_usd":2.67},"markers":{"merged":false,"slack":true,"doc":true}}
{"tab":"old-task","session":"s1","completed_at":"2026-04-19T09:00:00+0900","message":"done","summary":{"total_turns":5,"total_tool_calls":3},"markers":{"merged":false,"slack":false,"doc":false}}
JSONL

# Test summary stats
STATS=$(cat "$TEST_DAILY_FILE" | jq -s '{
    count: length,
    cost: ([.[].summary.total_cost_usd // 0] | add)
}' 2>/dev/null)
STAT_COUNT=$(echo "$STATS" | jq -r '.count')
STAT_COST=$(echo "$STATS" | jq -r '.cost')
[[ "$STAT_COUNT" == "3" ]] && pass "stats count=3" || fail "stats count wrong: $STAT_COUNT"
[[ "$STAT_COST" == "4.52" ]] && pass "stats total cost=4.52" || fail "stats total cost wrong: $STAT_COST"

# Test per-task cost formatting
COST_A=$(head -1 "$TEST_DAILY_FILE" | jq -r '.summary.total_cost_usd // null | if . != null then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "-" end')
[[ "$COST_A" == "\$1.85" ]] && pass "task-a cost formatted as \$1.85" || fail "task-a cost format wrong: $COST_A"

COST_OLD=$(sed -n '3p' "$TEST_DAILY_FILE" | jq -r '.summary.total_cost_usd // null | if . != null then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "-" end')
[[ "$COST_OLD" == "-" ]] && pass "old task without cost shows -" || fail "old task cost wrong: $COST_OLD"

# ============================================================
section "26. fetch-news.sh (successful fetch)"
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
section "27. fetch-news.sh (skips if today's file exists)"
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
section "28. fetch-news.sh (handles API failure gracefully)"
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
section "29. news-loop.sh (displays news from file)"
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
section "30. news-loop.sh (handles missing news file)"
# ============================================================

rm -f "$NEWS_FILE"

OUTPUT=$(CONDUCTOR_NEWS_ONCE=1 bash "$HOME/.claude-conductor/scripts/news-loop.sh" 2>/dev/null)

echo "$OUTPUT" | grep -qi "no news\|fetch" && pass "shows message when no news file" || fail "no fallback message: $OUTPUT"

# ============================================================
section "31. Uninstall"
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
