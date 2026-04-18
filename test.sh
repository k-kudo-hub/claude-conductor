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
section "9. pending-resolve.sh (no-op when no pending file)"
# ============================================================

echo '{"session_id":"sess-nonexistent"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-resolve.sh"

pass "no error on missing pending file"

# ============================================================
section "10. pending-notify.sh (no-op without session_id)"
# ============================================================

echo '{"message":"no session id"}' \
  | ZELLIJ_SESSION_NAME=test-session \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

FILE_COUNT=$(ls "$PENDING_DIR" 2>/dev/null | wc -l | tr -d ' ')
[[ "$FILE_COUNT" -eq 1 ]] && pass "no file created without session_id" || fail "unexpected file count: $FILE_COUNT"

# ============================================================
section "11. init.zsh loads without errors"
# ============================================================

OUTPUT=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && echo loaded" 2>&1)
[[ "$OUTPUT" == "loaded" ]] && pass "init.zsh sourced successfully" || fail "init.zsh failed: $OUTPUT"

# Check functions are defined
FUNCS=$(zsh -c "source '$HOME/.claude-conductor/init.zsh' && whence -w mdev dev task pdev zs pending-clear" 2>&1)
echo "$FUNCS" | grep -q "mdev: function" && pass "mdev function defined" || fail "mdev not defined"
echo "$FUNCS" | grep -q "task: function" && pass "task function defined" || fail "task not defined"

# ============================================================
section "12. Zellij calls were made correctly"
# ============================================================

CALLS="$HOME/.claude-pending/zellij-calls.log"
if [[ -f "$CALLS" ]]; then
    grep -q 'go-to-tab-name Main' "$CALLS" && pass "go-to-tab-name Main was called" || fail "go-to-tab-name Main not called"
    pass "all zellij calls completed (no hangs)"
else
    fail "no zellij calls recorded"
fi

# ============================================================
section "13. Uninstall"
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
