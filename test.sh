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
# Emit a fake `list-tabs` output when MOCK_TABS is set (3rd column is the tab name)
if [[ "$1" == "action" && "$2" == "list-tabs" && -n "$MOCK_TABS" ]]; then
    echo "ID X NAME"
    for t in $MOCK_TABS; do
        echo "1 x $t"
    done
fi
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
[[ -f "$HOME/.claude-conductor/scripts/task-lib.sh" ]] && pass "task-lib.sh installed" || fail "task-lib.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/lock-lib.sh" ]] && pass "lock-lib.sh installed" || fail "lock-lib.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/waiting-toggle.sh" ]] && pass "waiting-toggle.sh installed" || fail "waiting-toggle.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/waiting-loop.sh" ]] && pass "waiting-loop.sh installed" || fail "waiting-loop.sh missing"
[[ -f "$HOME/.claude-conductor/layouts/multi.kdl" ]] && pass "multi.kdl installed" || fail "multi.kdl missing"
grep -q 'name "Waiting"' "$HOME/.claude-conductor/layouts/multi.kdl" && pass "multi.kdl defines Waiting pane" || fail "multi.kdl missing Waiting pane"
grep -q 'waiting-loop.sh' "$HOME/.claude-conductor/layouts/multi.kdl" && pass "multi.kdl launches waiting-loop.sh" || fail "multi.kdl missing waiting-loop.sh"
MULTI_KDL="$HOME/.claude-conductor/layouts/multi.kdl"
OPEN_BRACES=$(tr -cd '{' < "$MULTI_KDL" | wc -c | tr -d ' ')
CLOSE_BRACES=$(tr -cd '}' < "$MULTI_KDL" | wc -c | tr -d ' ')
[[ "$OPEN_BRACES" == "$CLOSE_BRACES" ]] && pass "multi.kdl braces balanced" || fail "multi.kdl braces unbalanced: $OPEN_BRACES open / $CLOSE_BRACES close"
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
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature TASK_TYPE=dev \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

[[ -f "$PENDING_DIR/sess-aaa.json" ]] && pass "pending file created" || fail "pending file not created"

TAB=$(jq -r '.tab' "$PENDING_DIR/sess-aaa.json")
[[ "$TAB" == "api-feature" ]] && pass "tab name from TASK_TAB_NAME" || fail "tab name wrong: $TAB"

EVENT=$(jq -r '.event' "$PENDING_DIR/sess-aaa.json")
[[ "$EVENT" == "Notification" ]] && pass "event is Notification" || fail "event wrong: $EVENT"

DIR=$(jq -r '.dir' "$PENDING_DIR/sess-aaa.json")
[[ "$DIR" == "/tmp/myapp" ]] && pass "dir recorded from cwd" || fail "dir wrong: $DIR"

PTYPE=$(jq -r '.task_type' "$PENDING_DIR/sess-aaa.json")
[[ "$PTYPE" == "dev" ]] && pass "task_type recorded from TASK_TYPE" || fail "task_type wrong: $PTYPE"

# ============================================================
section "4. pending-notify.sh (Stop does not overwrite Notification)"
# ============================================================

echo '{"session_id":"sess-aaa","message":"Task done","hook_event_name":"Stop","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

EVENT_AFTER=$(jq -r '.event' "$PENDING_DIR/sess-aaa.json")
[[ "$EVENT_AFTER" == "Notification" ]] && pass "Stop did not overwrite Notification" || fail "Stop overwrote Notification: $EVENT_AFTER"

# A Waiting pending must also survive a later Stop event
echo '{"tab":"api-feature","session":"test-session","message":"waiting for review","event":"Waiting","time":"10:00:00"}' > "$PENDING_DIR/sess-wait.json"
echo '{"session_id":"sess-wait","message":"Task done","hook_event_name":"Stop","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"

EVENT_WAIT=$(jq -r '.event' "$PENDING_DIR/sess-wait.json")
[[ "$EVENT_WAIT" == "Waiting" ]] && pass "Stop did not overwrite Waiting" || fail "Stop overwrote Waiting: $EVENT_WAIT"
rm -f "$PENDING_DIR/sess-wait.json"

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
section "17b. task-lib.sh create_task passes TASK_TYPE"
# ============================================================

# task-lib.sh should be sourceable and define the shared functions
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && declare -F create_task >/dev/null && declare -F apply_layout >/dev/null ) \
  && pass "task-lib.sh defines create_task/apply_layout" || fail "task-lib.sh functions missing"

# create_task should launch the claude tab with TASK_TYPE env var
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "restore-me" ) >/dev/null 2>&1
grep -q 'action new-tab -n restore-me --cwd /tmp/proj -- env TASK_TAB_NAME=restore-me TASK_TYPE=dev claude' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task passes TASK_TAB_NAME and TASK_TYPE" || fail "create_task missing TASK_TYPE"

# create_task with a resume id should launch claude --resume <id>
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "resume-me" "sess-xyz" ) >/dev/null 2>&1
grep -q 'action new-tab -n resume-me --cwd /tmp/proj -- env TASK_TAB_NAME=resume-me TASK_TYPE=dev claude --resume sess-xyz' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task resumes session with claude --resume" || fail "create_task did not pass --resume"

# ============================================================
section "17c. lock-lib.sh (mkdir-based advisory lock)"
# ============================================================

( source "$HOME/.claude-conductor/scripts/lock-lib.sh" && declare -F acquire_lock >/dev/null && declare -F release_lock >/dev/null ) \
  && pass "lock-lib.sh defines acquire_lock/release_lock" || fail "lock-lib.sh functions missing"

source "$HOME/.claude-conductor/scripts/lock-lib.sh"
LOCKDIR="$SANDBOX/test.lock"

LK_RC=0; acquire_lock "$LOCKDIR" || LK_RC=$?
[[ $LK_RC -eq 0 ]] && pass "acquire_lock succeeds on free lock" || fail "acquire_lock failed: $LK_RC"
[[ -d "$LOCKDIR" ]] && pass "lock directory created" || fail "lock directory missing"

# A held lock blocks a second acquire (short timeout)
LK_RC2=0; acquire_lock "$LOCKDIR" 1 || LK_RC2=$?
[[ $LK_RC2 -eq 1 ]] && pass "held lock blocks second acquire (timeout)" || fail "second acquire wrong: $LK_RC2"

release_lock "$LOCKDIR"
[[ ! -d "$LOCKDIR" ]] && pass "release_lock removes the lock" || fail "release_lock left the lock"

LK_RC3=0; acquire_lock "$LOCKDIR" || LK_RC3=$?
[[ $LK_RC3 -eq 0 ]] && pass "re-acquire after release" || fail "re-acquire failed: $LK_RC3"
release_lock "$LOCKDIR"

# A stale lock (owner PID gone) is reclaimed
mkdir -p "$LOCKDIR"
echo "999999" > "$LOCKDIR/pid"
LK_RC4=0; acquire_lock "$LOCKDIR" 1 || LK_RC4=$?
[[ $LK_RC4 -eq 0 ]] && pass "stale lock reclaimed (dead owner)" || fail "stale lock not reclaimed: $LK_RC4"
release_lock "$LOCKDIR"

# ============================================================
section "17d. record-output.sh waits for the daily-log lock"
# ============================================================

HOLD_SESSION="hold-sess"
HOLD_PENDING="$HOME/.claude-pending/$HOLD_SESSION"
HOLD_DAILY_DIR="$HOME/.claude-conductor/daily/$HOLD_SESSION"
mkdir -p "$HOLD_PENDING" "$HOLD_DAILY_DIR"
HOLD_DAILY="$HOLD_DAILY_DIR/$(date '+%Y-%m-%d').jsonl"
HOLD_LOCK="$HOLD_DAILY.lock"
: > "$HOLD_DAILY"
cat > "$HOLD_PENDING/held.json" << 'EOF'
{"tab":"held-tab","session":"hold-sess","claude_session_id":"held","message":"blocked","event":"Stop","time":"09:00:00"}
EOF

# Hold the lock as a live owner (this shell), then start record-output in the background.
mkdir -p "$HOLD_LOCK"
echo "$$" > "$HOLD_LOCK/pid"
( ZELLIJ_SESSION_NAME="$HOLD_SESSION" bash "$HOME/.claude-conductor/scripts/record-output.sh" "held-tab" ) &
RO_PID=$!
sleep 1
BEFORE=$(wc -l < "$HOLD_DAILY" | tr -d ' ')
[[ "$BEFORE" -eq 0 ]] && pass "record-output blocks while lock is held" || fail "record-output wrote despite held lock: $BEFORE"

# Release and let record-output proceed
release_lock "$HOLD_LOCK"
wait "$RO_PID" 2>/dev/null || true
AFTER=$(wc -l < "$HOLD_DAILY" | tr -d ' ')
[[ "$AFTER" -eq 1 ]] && pass "record-output appends after lock released" || fail "record-output append wrong: $AFTER"
[[ ! -d "$HOLD_LOCK" ]] && pass "record-output releases the lock on exit" || fail "record-output left the lock"

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
  "transcript_path": "$MOCK_TRANSCRIPT",
  "dir": "/tmp/myapp",
  "task_type": "dev"
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

    DIR_REC=$(echo "$RECORD" | jq -r '.dir')
    [[ "$DIR_REC" == "/tmp/myapp" ]] && pass "dir carried into daily log" || fail "dir not carried: $DIR_REC"

    TYPE_REC=$(echo "$RECORD" | jq -r '.task_type')
    [[ "$TYPE_REC" == "dev" ]] && pass "task_type carried into daily log" || fail "task_type not carried: $TYPE_REC"

    SID_REC=$(echo "$RECORD" | jq -r '.claude_session_id')
    [[ "$SID_REC" == "sess-rec" ]] && pass "claude_session_id carried into daily log" || fail "claude_session_id not carried: $SID_REC"

    TP_REC=$(echo "$RECORD" | jq -r '.transcript_path')
    [[ "$TP_REC" == "$MOCK_TRANSCRIPT" ]] && pass "transcript_path carried into daily log" || fail "transcript_path not carried: $TP_REC"
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
{"tab":"restored-task","session":"s1","completed_at":"2026-04-19T08:00:00+0900","message":"done","summary":{"total_turns":2,"total_tool_calls":2,"total_cost_usd":9.99},"markers":{"merged":false,"slack":false,"doc":false},"restored":true}
JSONL

# Test summary stats (restored entries are excluded, as done-loop.sh does)
STATS=$(cat "$TEST_DAILY_FILE" | jq -s 'map(select((.restored // false) != true)) | {
    count: length,
    cost: ([.[].summary.total_cost_usd // 0] | add)
}' 2>/dev/null)
STAT_COUNT=$(echo "$STATS" | jq -r '.count')
STAT_COST=$(echo "$STATS" | jq -r '.cost')
[[ "$STAT_COUNT" == "3" ]] && pass "stats count=3 (restored excluded)" || fail "stats count wrong: $STAT_COUNT"
[[ "$STAT_COST" == "4.52" ]] && pass "stats total cost=4.52 (restored excluded)" || fail "stats total cost wrong: $STAT_COST"

# Restored entries must not appear in the displayed list
LIST_TABS=$(cat "$TEST_DAILY_FILE" | jq -s -r 'map(select((.restored // false) != true)) | sort_by(.completed_at) | .[].tab')
echo "$LIST_TABS" | grep -q "restored-task" && fail "restored task wrongly listed" || pass "restored task excluded from list"
echo "$LIST_TABS" | grep -q "task-a" && pass "active task listed" || fail "active task missing from list"

# Test per-task cost formatting
COST_A=$(head -1 "$TEST_DAILY_FILE" | jq -r '.summary.total_cost_usd // null | if . != null then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "-" end')
[[ "$COST_A" == "\$1.85" ]] && pass "task-a cost formatted as \$1.85" || fail "task-a cost format wrong: $COST_A"

COST_OLD=$(sed -n '3p' "$TEST_DAILY_FILE" | jq -r '.summary.total_cost_usd // null | if . != null then (. * 100 | round | . / 100 | tostring | if test("\\.") then . else . + ".00" end | if test("\\.[0-9]$") then . + "0" else . end | "$" + .) else "-" end')
[[ "$COST_OLD" == "-" ]] && pass "old task without cost shows -" || fail "old task cost wrong: $COST_OLD"

# ============================================================
section "26e. restore-task.sh (restore Done task to dashboard)"
# ============================================================

RESTORE_SESSION="restore-sess"
RESTORE_DAILY_DIR="$HOME/.claude-conductor/daily/$RESTORE_SESSION"
mkdir -p "$RESTORE_DAILY_DIR"
RESTORE_TODAY=$(date '+%Y-%m-%d')
RESTORE_DAILY_FILE="$RESTORE_DAILY_DIR/$RESTORE_TODAY.jsonl"
RESTORE_AT="${RESTORE_TODAY}T10:00:00+0900"
OLD_AT="${RESTORE_TODAY}T09:00:00+0900"
STALE_AT="${RESTORE_TODAY}T08:00:00+0900"
GONE_AT="${RESTORE_TODAY}T07:00:00+0900"
NT_AT="${RESTORE_TODAY}T06:00:00+0900"

# Working directories that still exist (restore requires the dir to be present)
PROJ_DIR="$SANDBOX/proj"
PROJ2_DIR="$SANDBOX/proj2"
mkdir -p "$PROJ_DIR" "$PROJ2_DIR"

# A transcript file that still exists (session resumable)
RESTORE_TRANSCRIPT="$SANDBOX/restore-transcript.jsonl"
echo '{}' > "$RESTORE_TRANSCRIPT"

# Entries:
#  - restore-me : dir + resumable session (transcript exists)     -> claude --resume
#  - legacy-task: no dir                                          -> not restorable (exit 2)
#  - stale-task : dir + session id but transcript is gone         -> fresh claude
#  - gone-task  : dir no longer exists on disk                    -> not restorable (exit 3)
#  - notrans    : dir + session id but no transcript_path field   -> fresh claude
cat > "$RESTORE_DAILY_FILE" << JSONL
{"tab":"restore-me","session":"$RESTORE_SESSION","completed_at":"$RESTORE_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$PROJ_DIR","task_type":"dev","claude_session_id":"sess-restore","transcript_path":"$RESTORE_TRANSCRIPT"}
{"tab":"legacy-task","session":"$RESTORE_SESSION","completed_at":"$OLD_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false}}
{"tab":"stale-task","session":"$RESTORE_SESSION","completed_at":"$STALE_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$PROJ2_DIR","task_type":"dev","claude_session_id":"sess-stale","transcript_path":"$SANDBOX/gone.jsonl"}
{"tab":"gone-task","session":"$RESTORE_SESSION","completed_at":"$GONE_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$SANDBOX/removed","task_type":"dev","claude_session_id":"sess-gone","transcript_path":"$RESTORE_TRANSCRIPT"}
{"tab":"notrans","session":"$RESTORE_SESSION","completed_at":"$NT_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$PROJ2_DIR","task_type":"dev","claude_session_id":"sess-notrans"}
JSONL

# Restore the entry that has dir and a resumable session
: > "$HOME/.claude-pending/zellij-calls.log"
RESTORE_RC=0
ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "restore-me" "$RESTORE_SESSION" "$RESTORE_AT" || RESTORE_RC=$?
[[ $RESTORE_RC -eq 0 ]] && pass "restore-task.sh exits 0 on restorable entry" || fail "restore-task.sh exit wrong: $RESTORE_RC"

grep -q "action new-tab -n restore-me --cwd $PROJ_DIR -- env TASK_TAB_NAME=restore-me TASK_TYPE=dev claude --resume sess-restore" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "restore recreates tab and resumes session" || fail "restore did not resume session correctly"

RESTORED_FLAG=$(jq -r 'select(.tab=="restore-me") | .restored' "$RESTORE_DAILY_FILE")
[[ "$RESTORED_FLAG" == "true" ]] && pass "restored entry marked restored:true" || fail "restored flag wrong: $RESTORED_FLAG"

# The other entries must stay untouched
LEGACY_FLAG=$(jq -r 'select(.tab=="legacy-task") | .restored // "absent"' "$RESTORE_DAILY_FILE")
[[ "$LEGACY_FLAG" == "absent" ]] && pass "unrelated entry untouched" || fail "unrelated entry changed: $LEGACY_FLAG"

# Legacy entry without dir cannot be restored
: > "$HOME/.claude-pending/zellij-calls.log"
LEGACY_RC=0
ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "legacy-task" "$RESTORE_SESSION" "$OLD_AT" || LEGACY_RC=$?
[[ $LEGACY_RC -eq 2 ]] && pass "restore-task.sh exits 2 when dir missing" || fail "legacy exit wrong: $LEGACY_RC"
[[ ! -s "$HOME/.claude-pending/zellij-calls.log" ]] && pass "no tab created for legacy entry" || fail "tab wrongly created for legacy entry"
LEGACY_FLAG2=$(jq -r 'select(.tab=="legacy-task") | .restored // "absent"' "$RESTORE_DAILY_FILE")
[[ "$LEGACY_FLAG2" == "absent" ]] && pass "legacy entry not marked restored" || fail "legacy entry wrongly marked: $LEGACY_FLAG2"

# Stale session (transcript gone): still restorable, but falls back to a fresh claude
: > "$HOME/.claude-pending/zellij-calls.log"
STALE_RC=0
ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "stale-task" "$RESTORE_SESSION" "$STALE_AT" || STALE_RC=$?
[[ $STALE_RC -eq 0 ]] && pass "stale-session entry still restores" || fail "stale restore exit wrong: $STALE_RC"
grep -q "action new-tab -n stale-task --cwd $PROJ2_DIR -- env TASK_TAB_NAME=stale-task TASK_TYPE=dev claude\$" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "stale session falls back to fresh claude (no --resume)" || fail "stale session did not fall back correctly"

# Session id but no transcript_path recorded: falls back to a fresh claude
: > "$HOME/.claude-pending/zellij-calls.log"
NT_RC=0
ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "notrans" "$RESTORE_SESSION" "$NT_AT" || NT_RC=$?
[[ $NT_RC -eq 0 ]] && pass "no-transcript entry still restores" || fail "no-transcript exit wrong: $NT_RC"
grep -q "action new-tab -n notrans --cwd $PROJ2_DIR -- env TASK_TAB_NAME=notrans TASK_TYPE=dev claude\$" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "no-transcript entry starts a fresh claude (no --resume)" || fail "no-transcript did not fall back correctly"

# Recorded dir no longer exists: not restorable, entry left in Done
: > "$HOME/.claude-pending/zellij-calls.log"
GONE_RC=0
ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "gone-task" "$RESTORE_SESSION" "$GONE_AT" || GONE_RC=$?
[[ $GONE_RC -eq 3 ]] && pass "restore-task.sh exits 3 when dir is gone" || fail "gone-dir exit wrong: $GONE_RC"
[[ ! -s "$HOME/.claude-pending/zellij-calls.log" ]] && pass "no tab created for gone-dir entry" || fail "tab wrongly created for gone-dir entry"
GONE_FLAG=$(jq -r 'select(.tab=="gone-task") | .restored // "absent"' "$RESTORE_DAILY_FILE")
[[ "$GONE_FLAG" == "absent" ]] && pass "gone-dir entry left in Done (not marked)" || fail "gone-dir entry wrongly marked: $GONE_FLAG"

# ============================================================
section "26f. done-loop.sh (r+number triggers restore)"
# ============================================================

# Isolate today's daily log to a single restorable entry so [1] is deterministic
rm -rf "$HOME/.claude-conductor/daily"
INT_SESSION="int-restore"
INT_DIR="$HOME/.claude-conductor/daily/$INT_SESSION"
mkdir -p "$INT_DIR"
INT_PROJ="$SANDBOX/intproj"
mkdir -p "$INT_PROJ"
INT_TODAY=$(date '+%Y-%m-%d')
INT_FILE="$INT_DIR/$INT_TODAY.jsonl"
INT_AT="${INT_TODAY}T10:00:00+0900"
cat > "$INT_FILE" << JSONL
{"tab":"int-task","session":"$INT_SESSION","completed_at":"$INT_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$INT_PROJ","task_type":"dev"}
JSONL

# Drive the interactive loop: feed 'r' then '1', keep stdin open briefly, then kill it.
: > "$HOME/.claude-pending/zellij-calls.log"
( printf 'r1'; sleep 3 ) | ZELLIJ_SESSION_NAME="$INT_SESSION" bash "$HOME/.claude-conductor/scripts/done-loop.sh" >/dev/null 2>&1 &
DL_PID=$!
sleep 2
kill "$DL_PID" 2>/dev/null || true
wait "$DL_PID" 2>/dev/null || true

grep -q "action new-tab -n int-task --cwd $INT_PROJ -- env TASK_TAB_NAME=int-task TASK_TYPE=dev claude" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "done-loop r+num recreates the tab" || fail "done-loop r+num did not recreate tab"

INT_FLAG=$(jq -r 'select(.tab=="int-task") | .restored' "$INT_FILE")
[[ "$INT_FLAG" == "true" ]] && pass "done-loop r+num marks entry restored" || fail "done-loop restored flag wrong: $INT_FLAG"

# ============================================================
section "26g. restore-task.sh (duplicate tab+completed_at marks only one)"
# ============================================================

# Two entries sharing the same tab AND completed_at: restoring must flip exactly
# one of them, leaving the sibling available in the Done pane.
DUP_SESSION="dup-sess"
DUP_DIR_DAILY="$HOME/.claude-conductor/daily/$DUP_SESSION"
mkdir -p "$DUP_DIR_DAILY"
DUP_TODAY=$(date '+%Y-%m-%d')
DUP_FILE="$DUP_DIR_DAILY/$DUP_TODAY.jsonl"
DUP_AT="${DUP_TODAY}T12:00:00+0900"
DUP_PROJ="$SANDBOX/dupproj"
mkdir -p "$DUP_PROJ"
cat > "$DUP_FILE" << JSONL
{"tab":"dup-task","session":"$DUP_SESSION","completed_at":"$DUP_AT","message":"first","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$DUP_PROJ","task_type":"dev"}
{"tab":"dup-task","session":"$DUP_SESSION","completed_at":"$DUP_AT","message":"second","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$DUP_PROJ","task_type":"dev"}
JSONL

DUP_RC=0
ZELLIJ_SESSION_NAME="$DUP_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "dup-task" "$DUP_SESSION" "$DUP_AT" || DUP_RC=$?
[[ $DUP_RC -eq 0 ]] && pass "duplicate restore exits 0" || fail "duplicate restore exit wrong: $DUP_RC"

DUP_RESTORED=$(jq -s '[.[] | select(.restored == true)] | length' "$DUP_FILE")
[[ "$DUP_RESTORED" == "1" ]] && pass "exactly one duplicate marked restored" || fail "wrong restored count: $DUP_RESTORED"
DUP_REMAIN=$(jq -s '[.[] | select((.restored // false) != true)] | length' "$DUP_FILE")
[[ "$DUP_REMAIN" == "1" ]] && pass "sibling entry still available in Done" || fail "sibling count wrong: $DUP_REMAIN"

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
section "28. fetch-news.sh (--force re-fetches even if today's file exists)"
# ============================================================

# File currently has title "CACHED" from previous section
if [[ -f "$NEWS_FILE" ]]; then
    bash "$HOME/.claude-conductor/scripts/fetch-news.sh" --force

    FORCED_TITLE=$(jq -r '.items[0].title' "$NEWS_FILE")
    [[ "$FORCED_TITLE" == "GPT-5 Released with Major Improvements" ]] && pass "--force re-fetches despite existing file" || fail "--force did not re-fetch: $FORCED_TITLE"
else
    fail "news file missing from previous test"
fi

# ============================================================
section "29. fetch-news.sh (handles API failure gracefully)"
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
section "30. news-loop.sh (displays news from file)"
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
echo "$OUTPUT" | grep -qi "reload" && pass "reload key hint displayed" || fail "reload hint not displayed"

# ============================================================
section "31. news-loop.sh (handles missing news file)"
# ============================================================

rm -f "$NEWS_FILE"

OUTPUT=$(CONDUCTOR_NEWS_ONCE=1 bash "$HOME/.claude-conductor/scripts/news-loop.sh" 2>/dev/null)

echo "$OUTPUT" | grep -qi "no news\|fetch" && pass "shows message when no news file" || fail "no fallback message: $OUTPUT"

# ============================================================
section "30. scripts are executable (mdev-test runs them directly)"
# ============================================================

# Layout panes run their script directly (bash -c "<path>/x.sh"), which needs the
# execute bit. mdev-test runs the worktree copy in place (install.sh's chmod does
# not apply), so those scripts must carry the bit in the repo itself. (Libraries
# that are sourced, and scripts invoked via `bash <script>`, do not need it.)
LAYOUT_SCRIPTS=$(grep -ohE 'scripts/[a-z0-9-]+\.sh' "$REPO_DIR"/layouts/*.kdl | sort -u)
NON_EXEC=""
for s in $LAYOUT_SCRIPTS; do
    f="$REPO_DIR/$s"
    [[ -f "$f" && ! -x "$f" ]] && NON_EXEC="$NON_EXEC $(basename "$f")"
done
[[ -z "$NON_EXEC" ]] && pass "layout pane scripts are executable" || fail "non-executable pane scripts:$NON_EXEC"

# ============================================================
section "30a. multi.kdl honors CONDUCTOR_HOME"
# ============================================================

MULTI_KDL="$HOME/.claude-conductor/layouts/multi.kdl"
grep -q '\${CONDUCTOR_HOME' "$MULTI_KDL" \
  && pass "multi.kdl references CONDUCTOR_HOME" || fail "multi.kdl does not reference CONDUCTOR_HOME"
grep -q '"\$HOME/.claude-conductor/scripts' "$MULTI_KDL" \
  && fail "multi.kdl still hardcodes \$HOME/.claude-conductor" || pass "multi.kdl has no hardcoded conductor path"

# ============================================================
section "30b. done-loop.sh honors CONDUCTOR_HOME for daily"
# ============================================================

DONE_LOOP="$HOME/.claude-conductor/scripts/done-loop.sh"
grep -q 'CONDUCTOR_HOME' "$DONE_LOOP" \
  && pass "done-loop.sh references CONDUCTOR_HOME" || fail "done-loop.sh does not reference CONDUCTOR_HOME"

# Verify done-loop reads daily under CONDUCTOR_HOME by pointing it at an alternate home
ALT_DAILY_HOME="$SANDBOX/alt-daily-home"
mkdir -p "$ALT_DAILY_HOME/daily/alt-session"
TODAY=$(date '+%Y-%m-%d')
cat > "$ALT_DAILY_HOME/daily/alt-session/${TODAY}.jsonl" << 'DONEJSON'
{"tab":"alt-task","status":"done","summary":{"total_turns":3,"total_tool_calls":5,"total_cost_usd":0.42},"completed_at":"2026-07-04T10:00:00Z"}
DONEJSON

OUTPUT=$(CONDUCTOR_HOME="$ALT_DAILY_HOME" CONDUCTOR_DONE_ONCE=1 bash "$HOME/.claude-conductor/scripts/done-loop.sh" 2>/dev/null)
echo "$OUTPUT" | grep -q "alt-task" \
  && pass "done-loop reads daily under CONDUCTOR_HOME" || fail "done-loop did not read CONDUCTOR_HOME daily: $OUTPUT"

# ============================================================
section "30c. init.zsh defines mdev-test"
# ============================================================

INIT_FILE="$HOME/.claude-conductor/init.zsh"
FUNCS=$(zsh -c "source '$INIT_FILE' && whence -w mdev-test" 2>&1)
echo "$FUNCS" | grep -q "mdev-test: function" && pass "mdev-test function defined" || fail "mdev-test not defined: $FUNCS"

# ============================================================
section "30d. mdev-test resolves worktree (dry-run)"
# ============================================================

FAKE_WT="$SANDBOX/fake-worktrees/my-feature"
mkdir -p "$FAKE_WT/scripts" "$FAKE_WT/layouts"
touch "$FAKE_WT/scripts/fetch-news.sh" "$FAKE_WT/layouts/multi.kdl"

OUTPUT=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$FAKE_WT'" 2>&1)
echo "$OUTPUT" | grep -q "CONDUCTOR_HOME=$FAKE_WT" \
  && pass "dry-run exports CONDUCTOR_HOME to worktree path" || fail "wrong CONDUCTOR_HOME: $OUTPUT"
echo "$OUTPUT" | grep -q "SESSION=test-my-feature" \
  && pass "dry-run derives test-<basename> session name" || fail "wrong session name: $OUTPUT"
echo "$OUTPUT" | grep -q "$FAKE_WT/layouts/multi.kdl" \
  && pass "dry-run launch command uses worktree layout" || fail "wrong layout in command: $OUTPUT"
echo "$OUTPUT" | grep -q "zellij delete-session '.*' --force" \
  && pass "launch command deletes stale session before recreating (re-run fresh)" || fail "no delete-session in command: $OUTPUT"
echo "$OUTPUT" | grep -q "zellij --new-session-with-layout" \
  && pass "launch command creates a new session" || fail "no new-session in command: $OUTPUT"

# Distinct long worktrees sharing a name prefix must get distinct session names
WT_A="$SANDBOX/fake-worktrees/dashboard-redesign-alpha"
WT_B="$SANDBOX/fake-worktrees/dashboard-redesign-beta"
for d in "$WT_A" "$WT_B"; do
  mkdir -p "$d/scripts" "$d/layouts"
  touch "$d/scripts/fetch-news.sh" "$d/layouts/multi.kdl"
done
SESS_A=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$WT_A'" 2>/dev/null | grep '^SESSION=' | cut -d= -f2)
SESS_B=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$WT_B'" 2>/dev/null | grep '^SESSION=' | cut -d= -f2)
[[ -n "$SESS_A" && "$SESS_A" != "$SESS_B" && "${#SESS_A}" -le 24 && "${#SESS_B}" -le 24 ]] \
  && pass "prefix-sharing worktrees get distinct sessions ($SESS_A / $SESS_B)" \
  || fail "session name collision: '$SESS_A' vs '$SESS_B'"

# Long worktree names must be truncated to zellij's 24-char session-name limit
LONG_WT="$SANDBOX/fake-worktrees/add-isolated-test-launcher"
mkdir -p "$LONG_WT/scripts" "$LONG_WT/layouts"
touch "$LONG_WT/scripts/fetch-news.sh" "$LONG_WT/layouts/multi.kdl"
OUTPUT=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$LONG_WT'" 2>/dev/null)
SESSION_LINE=$(echo "$OUTPUT" | grep '^SESSION=' | cut -d= -f2)
[[ "${#SESSION_LINE}" -le 24 && -n "$SESSION_LINE" ]] \
  && pass "long worktree name truncated to <=24 chars ($SESSION_LINE)" \
  || fail "session name not truncated: '$SESSION_LINE' (${#SESSION_LINE} chars)"

# A worktree with an env-aware multi.kdl must NOT warn about partial isolation
echo 'layout { pane { command "bash"; args "-c" "${CONDUCTOR_HOME:-x}/scripts/dashboard-loop.sh" } }' > "$FAKE_WT/layouts/multi.kdl"
STDERR=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$FAKE_WT'" 2>&1 >/dev/null)
echo "$STDERR" | grep -q "partial isolation" \
  && fail "unexpected partial-isolation warning for env-aware layout" \
  || pass "no warning when layout references CONDUCTOR_HOME"

# A worktree whose multi.kdl hardcodes the install path must warn
echo 'layout { pane { command "bash"; args "-c" "$HOME/.claude-conductor/scripts/dashboard-loop.sh" } }' > "$FAKE_WT/layouts/multi.kdl"
STDERR=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$FAKE_WT'" 2>&1 >/dev/null)
echo "$STDERR" | grep -q "partial isolation" \
  && pass "warns about partial isolation for legacy hardcoded layout" \
  || fail "missing partial-isolation warning: $STDERR"

# ============================================================
section "30e. mdev-test errors on invalid worktree"
# ============================================================

set +e
OUTPUT=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$SANDBOX/does-not-exist'" 2>&1)
RC=$?
set -e
[[ "$RC" -ne 0 ]] && pass "mdev-test returns non-zero on missing worktree" || fail "mdev-test did not fail on missing worktree"

# A directory that exists but is not a conductor worktree must also error
NON_WT="$SANDBOX/not-a-worktree"
mkdir -p "$NON_WT"
set +e
OUTPUT=$(zsh -c "source '$INIT_FILE' && CONDUCTOR_MDEV_TEST_DRYRUN=1 mdev-test '$NON_WT'" 2>&1)
RC=$?
set -e
[[ "$RC" -ne 0 ]] && pass "mdev-test rejects non-conductor directory" || fail "mdev-test accepted non-conductor directory"

# ============================================================
section "30f. mdev-test Warp launch (Launch Configuration)"
# ============================================================

# Mock `open` to record invocations without opening anything
mkdir -p "$HOME/.claude-pending"
cat > "$MOCK_BIN/open" << 'MOCKOPEN'
#!/bin/bash
echo "mock-open: $*" >> "$HOME/.claude-pending/open-calls.log"
MOCKOPEN
chmod +x "$MOCK_BIN/open"
: > "$HOME/.claude-pending/open-calls.log"

WARP_WT="$SANDBOX/fake-worktrees/warp-feature"
mkdir -p "$WARP_WT/scripts" "$WARP_WT/layouts"
touch "$WARP_WT/scripts/fetch-news.sh"
echo 'layout { pane { command "bash"; args "-c" "${CONDUCTOR_HOME:-x}/scripts/dashboard-loop.sh" } }' > "$WARP_WT/layouts/multi.kdl"

TERM_PROGRAM=WarpTerminal zsh -c "source '$INIT_FILE' && mdev-test '$WARP_WT'" >/dev/null 2>&1

LC_YAML=$(ls "$HOME/.warp/launch_configurations/"mdev-test-*.yaml 2>/dev/null | head -1)
[[ -f "$LC_YAML" ]] && pass "Warp launch config written" || fail "no launch config created"
grep -q "cwd:.*warp-feature" "$LC_YAML" 2>/dev/null \
  && pass "launch config cwd is the worktree" || fail "wrong cwd in launch config"
grep -q "exec:.*CONDUCTOR_HOME=" "$LC_YAML" 2>/dev/null \
  && pass "launch config exec exports CONDUCTOR_HOME" || fail "exec missing CONDUCTOR_HOME: $(cat "$LC_YAML" 2>/dev/null)"
grep -q "warp://launch/mdev-test-" "$HOME/.claude-pending/open-calls.log" \
  && pass "open invoked with warp://launch URI" || fail "open not called with warp URI: $(cat "$HOME/.claude-pending/open-calls.log")"

# Re-running cleans up the previous run's config (only one mdev-test-*.yaml remains)
WARP_WT2="$SANDBOX/fake-worktrees/warp-other"
mkdir -p "$WARP_WT2/scripts" "$WARP_WT2/layouts"
touch "$WARP_WT2/scripts/fetch-news.sh"
echo 'layout { pane { args "-c" "${CONDUCTOR_HOME:-x}/scripts/x.sh" } }' > "$WARP_WT2/layouts/multi.kdl"
TERM_PROGRAM=WarpTerminal zsh -c "source '$INIT_FILE' && mdev-test '$WARP_WT2'" >/dev/null 2>&1
YAML_COUNT=$(ls "$HOME/.warp/launch_configurations/"mdev-test-*.yaml 2>/dev/null | wc -l | tr -d ' ')
[[ "$YAML_COUNT" -eq 1 ]] && pass "previous launch config cleaned up on re-run" || fail "stale configs remain: $YAML_COUNT"

# Restore real `open` for any later sections
rm -f "$MOCK_BIN/open"

# ============================================================
section "32. task-create-loop.sh default name generation"
# ============================================================

CREATE_LOOP="$HOME/.claude-conductor/scripts/task-create-loop.sh"

# sourceしてもメインループが起動せず関数のみ提供されること
if source "$CREATE_LOOP" 2>/dev/null; then
    pass "task-create-loop.sh sourced without launching main loop"
else
    fail "task-create-loop.sh failed to source"
fi

# generate_default_name は {dirname}-{type} を返す
GEN_NAME=$(generate_default_name "/home/user/myapp" "dev")
[[ "$GEN_NAME" == "myapp-dev" ]] && pass "generate_default_name returns dirname-type" || fail "generate_default_name wrong: $GEN_NAME"

# 末尾スラッシュ付きディレクトリでも basename が取れる
GEN_NAME2=$(generate_default_name "/home/user/api-server/" "k8s")
[[ "$GEN_NAME2" == "api-server-k8s" ]] && pass "generate_default_name handles trailing slash" || fail "generate_default_name trailing slash wrong: $GEN_NAME2"

# ============================================================
section "33. task-create-loop.sh skip name input mode"
# ============================================================

SKIP_CONFIG="$HOME/.claude-conductor/config.json"

# デフォルト（config.default.json）では skip_task_name_input は false
DEFAULT_SKIP=$(jq -r '.skip_task_name_input // false' "$HOME/.claude-conductor/config.default.json")
[[ "$DEFAULT_SKIP" == "false" ]] && pass "config.default.json skip_task_name_input defaults to false" || fail "default skip flag wrong: $DEFAULT_SKIP"

# skip_task_name_input=true のとき skip_name_input_enabled が真
BACKUP_CONFIG=$(cat "$SKIP_CONFIG")
jq '.skip_task_name_input = true' "$SKIP_CONFIG" > "$SKIP_CONFIG.tmp" && mv "$SKIP_CONFIG.tmp" "$SKIP_CONFIG"
if skip_name_input_enabled; then pass "skip_name_input_enabled true when flag on"; else fail "skip_name_input_enabled should be true"; fi

# skip_task_name_input=false のとき skip_name_input_enabled が偽
jq '.skip_task_name_input = false' "$SKIP_CONFIG" > "$SKIP_CONFIG.tmp" && mv "$SKIP_CONFIG.tmp" "$SKIP_CONFIG"
if skip_name_input_enabled; then fail "skip_name_input_enabled should be false"; else pass "skip_name_input_enabled false when flag off"; fi

# フラグ未定義でもデフォルトで偽
jq 'del(.skip_task_name_input)' "$SKIP_CONFIG" > "$SKIP_CONFIG.tmp" && mv "$SKIP_CONFIG.tmp" "$SKIP_CONFIG"
if skip_name_input_enabled; then fail "skip_name_input_enabled should default to false"; else pass "skip_name_input_enabled defaults to false when unset"; fi

# configを元に戻す
echo "$BACKUP_CONFIG" > "$SKIP_CONFIG"

# ============================================================
section "34. task-create-loop.sh name input resolution"
# ============================================================

# 実コードの resolve_name を直接検証する（テスト用の再実装ではなく本体関数を呼ぶ）

# 空入力（Enterのみ）はデフォルト候補に解決される
RESOLVED_EMPTY=$(resolve_name "myapp-dev" "")
[[ "$RESOLVED_EMPTY" == "myapp-dev" ]] && pass "empty input resolves to default name" || fail "empty input wrong: $RESOLVED_EMPTY"

# 空入力がタイムスタンプ名（type-HHMMSS）にならない（リグレッション防止）
[[ ! "$RESOLVED_EMPTY" =~ ^dev-[0-9]{6}$ ]] && pass "empty input does not fall back to timestamp name" || fail "empty input regressed to timestamp: $RESOLVED_EMPTY"

# 手入力は入力値がそのまま採用される
RESOLVED_TYPED=$(resolve_name "myapp-dev" "custom-name")
[[ "$RESOLVED_TYPED" == "custom-name" ]] && pass "typed input overrides default" || fail "typed input wrong: $RESOLVED_TYPED"

# ============================================================
section "35. task-create-loop.sh unique tab name"
# ============================================================

# 既存タブ名を返すよう zellij をシャドウしてテストする
zellij() {
    if [[ "$1" == "action" && "$2" == "query-tab-names" ]]; then
        printf '%s\n' "Main" "myapp-dev" "myapp-dev-2"
        return 0
    fi
    return 0
}

# 重複しない名前はそのまま返る
UNIQ_NEW=$(ensure_unique_tab_name "other-dev")
[[ "$UNIQ_NEW" == "other-dev" ]] && pass "non-colliding name returned as-is" || fail "non-colliding wrong: $UNIQ_NEW"

# 既存名と重複する場合は空いている連番まで進む（-2 も埋まっているので -3）
UNIQ_DUP=$(ensure_unique_tab_name "myapp-dev")
[[ "$UNIQ_DUP" == "myapp-dev-3" ]] && pass "colliding name gets next free suffix" || fail "colliding wrong: $UNIQ_DUP"

# 部分一致は重複扱いしない（完全一致のみ）
UNIQ_PARTIAL=$(ensure_unique_tab_name "myapp")
[[ "$UNIQ_PARTIAL" == "myapp" ]] && pass "partial match is not treated as collision" || fail "partial match wrong: $UNIQ_PARTIAL"

unset -f zellij

# query-tab-names が失敗する場合は元の名前をそのまま返す
zellij() { return 1; }
UNIQ_FAIL=$(ensure_unique_tab_name "myapp-dev")
[[ "$UNIQ_FAIL" == "myapp-dev" ]] && pass "returns base name when query fails" || fail "query-fail wrong: $UNIQ_FAIL"
unset -f zellij

# ============================================================
section "36. waiting-toggle.sh (toggles Waiting state)"
# ============================================================

WAIT_DIR="$HOME/.claude-pending/wait-session"
mkdir -p "$WAIT_DIR"

# Existing Notification pending -> toggle to Waiting
echo '{"tab":"pr-review","session":"wait-session","message":"review","event":"Notification","time":"10:00:00"}' > "$WAIT_DIR/sess-w1.json"

ZELLIJ_SESSION_NAME=wait-session \
  bash "$HOME/.claude-conductor/scripts/waiting-toggle.sh" "pr-review"

EVENT_W=$(jq -r '.event' "$WAIT_DIR/sess-w1.json")
[[ "$EVENT_W" == "Waiting" ]] && pass "Notification toggled to Waiting" || fail "toggle to Waiting failed: $EVENT_W"

# Toggle again -> back to Notification (prev_event restored, field removed)
ZELLIJ_SESSION_NAME=wait-session \
  bash "$HOME/.claude-conductor/scripts/waiting-toggle.sh" "pr-review"

EVENT_W2=$(jq -r '.event' "$WAIT_DIR/sess-w1.json")
[[ "$EVENT_W2" == "Notification" ]] && pass "Waiting toggled back to Notification" || fail "toggle back failed: $EVENT_W2"
PREV_W2=$(jq -r '.prev_event // "absent"' "$WAIT_DIR/sess-w1.json")
[[ "$PREV_W2" == "absent" ]] && pass "prev_event removed after resume" || fail "prev_event lingering: $PREV_W2"

# A completed (Stop/done) task must return to Stop after Waiting -> resume
echo '{"tab":"done-task","session":"wait-session","message":"review completed","event":"Stop","time":"10:00:00"}' > "$WAIT_DIR/sess-done.json"

ZELLIJ_SESSION_NAME=wait-session \
  bash "$HOME/.claude-conductor/scripts/waiting-toggle.sh" "done-task"
EVENT_D1=$(jq -r '.event' "$WAIT_DIR/sess-done.json")
PREV_D1=$(jq -r '.prev_event' "$WAIT_DIR/sess-done.json")
[[ "$EVENT_D1" == "Waiting" && "$PREV_D1" == "Stop" ]] && pass "Stop task remembers prev_event on Waiting" || fail "prev_event not saved: event=$EVENT_D1 prev=$PREV_D1"

ZELLIJ_SESSION_NAME=wait-session \
  bash "$HOME/.claude-conductor/scripts/waiting-toggle.sh" "done-task"
EVENT_D2=$(jq -r '.event' "$WAIT_DIR/sess-done.json")
[[ "$EVENT_D2" == "Stop" ]] && pass "Stop task restored to Stop on resume" || fail "Stop not restored: $EVENT_D2"

# No existing pending for this tab -> no-op (Waiting only applies to tasks with a pending entry)
ZELLIJ_SESSION_NAME=wait-session \
  bash "$HOME/.claude-conductor/scripts/waiting-toggle.sh" "fresh-task"

FRESH_FOUND=""
for f in "$WAIT_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "fresh-task" ]]; then
        FRESH_FOUND="$f"
        break
    fi
done
[[ -z "$FRESH_FOUND" ]] && pass "no entry created when no pending exists" || fail "unexpected entry created: $FRESH_FOUND"

# ============================================================
section "37. dashboard-loop.sh (excludes Waiting tasks)"
# ============================================================

DASH_DIR="$HOME/.claude-pending/dash-session"
mkdir -p "$DASH_DIR"
echo '{"tab":"active-task","session":"dash-session","message":"needs permission","event":"Notification","time":"10:00:00"}' > "$DASH_DIR/d1.json"
echo '{"tab":"waiting-task","session":"dash-session","message":"pr review","event":"Waiting","time":"10:01:00"}' > "$DASH_DIR/d2.json"

DASH_OUT=$(CONDUCTOR_DASHBOARD_ONCE=1 MOCK_TABS="active-task waiting-task" ZELLIJ_SESSION_NAME=dash-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" 2>/dev/null)

echo "$DASH_OUT" | grep -q "active-task" && pass "Notification task shown in dashboard" || fail "Notification task not shown"
echo "$DASH_OUT" | grep -q "waiting-task" && fail "Waiting task incorrectly shown in dashboard" || pass "Waiting task excluded from dashboard"
echo "$DASH_OUT" | grep -q "Pending: 1" && pass "dashboard count excludes Waiting" || fail "dashboard count wrong: $(echo "$DASH_OUT" | grep Pending)"

# ============================================================
section "38. waiting-loop.sh (shows only Waiting tasks)"
# ============================================================

WL_DIR="$HOME/.claude-pending/wl-session"
mkdir -p "$WL_DIR"
echo '{"tab":"active-task","session":"wl-session","message":"needs permission","event":"Notification","time":"11:00:00"}' > "$WL_DIR/w1.json"
echo '{"tab":"review-task","session":"wl-session","message":"waiting for pr review","event":"Waiting","time":"11:01:00"}' > "$WL_DIR/w2.json"

WL_OUT=$(CONDUCTOR_WAITING_ONCE=1 ZELLIJ_SESSION_NAME=wl-session \
    bash "$HOME/.claude-conductor/scripts/waiting-loop.sh" 2>/dev/null)

echo "$WL_OUT" | grep -q "review-task" && pass "Waiting task shown in waiting pane" || fail "Waiting task not shown"
echo "$WL_OUT" | grep -q "active-task" && fail "Non-Waiting task incorrectly shown in waiting pane" || pass "Non-Waiting task excluded from waiting pane"
echo "$WL_OUT" | grep -q "Waiting: 1" && pass "waiting count correct" || fail "waiting count wrong: $(echo "$WL_OUT" | grep Waiting)"

# Empty case
WL_EMPTY_DIR="$HOME/.claude-pending/wl-empty-session"
mkdir -p "$WL_EMPTY_DIR"
WL_EMPTY_OUT=$(CONDUCTOR_WAITING_ONCE=1 ZELLIJ_SESSION_NAME=wl-empty-session \
    bash "$HOME/.claude-conductor/scripts/waiting-loop.sh" 2>/dev/null)
echo "$WL_EMPTY_OUT" | grep -q "No waiting tasks" && pass "shows message when no waiting tasks" || fail "no empty message"

# ============================================================
section "39. task-control.sh (shows Waiting indicator)"
# ============================================================

TC_DIR="$HOME/.claude-pending/tc-session"
mkdir -p "$TC_DIR"

# Not waiting -> normal bar, no indicator
echo '{"tab":"my-task","session":"tc-session","message":"needs permission","event":"Notification","time":"12:00:00"}' > "$TC_DIR/tc1.json"
TC_OUT=$(CONDUCTOR_TASKCTL_ONCE=1 ZELLIJ_SESSION_NAME=tc-session \
    bash "$HOME/.claude-conductor/scripts/task-control.sh" "my-task" 2>/dev/null)
echo "$TC_OUT" | grep -q "w: Waiting" && pass "normal bar offers Waiting" || fail "normal bar wrong: $TC_OUT"
echo "$TC_OUT" | grep -q "● WAITING" && fail "indicator shown when not waiting" || pass "no indicator when not waiting"

# Waiting -> indicator + Resume label
jq '.event = "Waiting"' "$TC_DIR/tc1.json" > "$TC_DIR/tc1.tmp" && mv "$TC_DIR/tc1.tmp" "$TC_DIR/tc1.json"
TC_OUT2=$(CONDUCTOR_TASKCTL_ONCE=1 ZELLIJ_SESSION_NAME=tc-session \
    bash "$HOME/.claude-conductor/scripts/task-control.sh" "my-task" 2>/dev/null)
echo "$TC_OUT2" | grep -q "● WAITING" && pass "WAITING indicator shown when waiting" || fail "no indicator when waiting: $TC_OUT2"
echo "$TC_OUT2" | grep -q "w: Resume" && pass "bar offers Resume when waiting" || fail "no Resume label: $TC_OUT2"

# ============================================================
section "40. upload-log.sh (skipped when upload disabled)"
# ============================================================

UPLOAD_SCRIPT="$HOME/.claude-conductor/scripts/upload-log.sh"
UPLOAD_CONFIG="$HOME/.claude-conductor/config.json"

[[ -f "$UPLOAD_SCRIPT" ]] && pass "upload-log.sh installed" || fail "upload-log.sh not installed"

# Default config ships with upload.enabled=false -> must exit 0 and do nothing
ZELLIJ_SESSION_NAME=test-session bash "$UPLOAD_SCRIPT" "some-tab" \
    && pass "exits 0 when upload disabled" || fail "non-zero exit when upload disabled"

# enabled=true but repo empty -> still skipped (exit 0)
jq '.upload.enabled = true | .upload.repo = ""' "$HOME/.claude-conductor/config.default.json" > "$UPLOAD_CONFIG"
ZELLIJ_SESSION_NAME=test-session bash "$UPLOAD_SCRIPT" "some-tab" \
    && pass "exits 0 when repo unset" || fail "non-zero exit when repo unset"
rm -f "$UPLOAD_CONFIG"

# ============================================================
section "41. upload-log.sh filter_secrets (masks known tokens)"
# ============================================================

# Run filter_secrets from the installed lib against a single line of input.
# These helpers feed bare `X=$(...)` assignments, so force exit 0 to keep a
# future helper failure from aborting the whole suite under `set -e`
# (correctness is still checked by the content assertions on the output).
run_filter() {
    printf '%s' "$1" | ( UPLOAD_LOG_LIB=1 source "$UPLOAD_SCRIPT"; filter_secrets )
    return 0
}

OUT=$(run_filter "auth key=sk-ant-api03-abcDEF123456789ghijklmnop_qrstuvwxyz")
echo "$OUT" | grep -q "REDACTED" && ! echo "$OUT" | grep -q "abcDEF123456789" \
    && pass "anthropic API key masked" || fail "anthropic key not masked: $OUT"

OUT=$(run_filter "token ghp_abcdefghijklmnopqrstuvwxyz0123456789")
echo "$OUT" | grep -q "REDACTED" && ! echo "$OUT" | grep -q "ghp_abcdef" \
    && pass "github token masked" || fail "github token not masked: $OUT"

OUT=$(run_filter "aws AKIAIOSFODNN7EXAMPLE here")
echo "$OUT" | grep -q "REDACTED" && ! echo "$OUT" | grep -q "AKIAIOSFODNN7EXAMPLE" \
    && pass "aws access key masked" || fail "aws key not masked: $OUT"

OUT=$(run_filter "slack xoxb-EXAMPLESLACKtokenplaceholder")
echo "$OUT" | grep -q "REDACTED" && ! echo "$OUT" | grep -q "xoxb-EXAMPLESLACK" \
    && pass "slack token masked" || fail "slack token not masked: $OUT"

OUT=$(run_filter "Authorization: Bearer aBcDeF1234567890xyzTOKEN")
echo "$OUT" | grep -q "Bearer ..REDACTED\|Bearer \*" && ! echo "$OUT" | grep -q "aBcDeF1234567890" \
    && pass "bearer token masked" || fail "bearer token not masked: $OUT"

# Non-secret text must pass through untouched
OUT=$(run_filter "just a normal log line about task completion")
[[ "$OUT" == "just a normal log line about task completion" ]] \
    && pass "normal text unchanged" || fail "normal text altered: $OUT"

# Multi-line PEM private key block must be masked, INCLUDING a short (<40 char)
# trailing base64 line (the wrapped remainder of the key body).
PEM=$'before\n-----BEGIN PRIVATE KEY-----\nMIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6\nAgEAAoGBAKsecretkeymaterialxyz0123456789\nk7QmShortTailLine24charsZ=\n-----END PRIVATE KEY-----\nafter'
OUT=$(run_filter "$PEM")
! echo "$OUT" | grep -q "MIIBVAIBADANBgkqhkiG" && ! echo "$OUT" | grep -q "secretkeymaterial" \
    && pass "PEM private key block masked" || fail "PEM key leaked: $OUT"
! echo "$OUT" | grep -q "k7QmShortTailLine24charsZ" \
    && pass "PEM short trailing line masked" || fail "PEM tail line leaked: $OUT"
echo "$OUT" | grep -q "REDACTED" && pass "PEM masked with REDACTED marker" || fail "no REDACTED for PEM: $OUT"
echo "$OUT" | grep -q "^before$" && echo "$OUT" | grep -q "^after$" \
    && pass "text around PEM block preserved" || fail "surrounding text lost: $OUT"

# An unterminated BEGIN marker over-masks to end-of-input (security-first):
# it must never leak the following lines as potential key material.
STRAY=$'head line\n-----BEGIN PRIVATE KEY-----\nMIIBstraykeymaterialthatmustnotleak12345\ntail secret line'
OUT=$(run_filter "$STRAY")
echo "$OUT" | grep -q "^head line$" && pass "content before stray marker preserved" || fail "head lost: $OUT"
echo "$OUT" | grep -q "REDACTED PRIVATE KEY" && pass "unterminated PEM emits key marker" || fail "no key marker: $OUT"
! echo "$OUT" | grep -q "MIIBstraykeymaterial" && ! echo "$OUT" | grep -q "tail secret line" \
    && pass "unterminated PEM over-masks following lines (no leak)" || fail "leaked after stray marker: $OUT"

# ============================================================
section "42. upload-log.sh generate_summary (via claude CLI)"
# ============================================================

run_summary() {
    ( UPLOAD_LOG_LIB=1 source "$UPLOAD_SCRIPT"; generate_summary "$1" )
}

# Mock claude CLI that echoes a canned summary
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null   # drain the conversation on stdin
echo "- モックの作業要約1"
echo "- モックの作業要約2"
MOCK
chmod +x "$MOCK_BIN/claude"

if SUM=$(run_summary "$MOCK_TRANSCRIPT"); then
    echo "$SUM" | grep -q "モックの作業要約" \
        && pass "summary generated via claude" || fail "summary content wrong: $SUM"
else
    fail "generate_summary returned non-zero on success path"
fi

# Missing transcript -> failure
if run_summary "/nonexistent/transcript.jsonl" >/dev/null 2>&1; then
    fail "generate_summary should fail on missing transcript"
else
    pass "generate_summary fails on missing transcript"
fi

# claude CLI error -> failure (so caller can abort dd)
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"

if run_summary "$MOCK_TRANSCRIPT" >/dev/null 2>&1; then
    fail "generate_summary should fail when claude errors"
else
    pass "generate_summary fails when claude errors"
fi

# Restore working mock claude for later sections
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
echo "- モックの作業要約1"
echo "- モックの作業要約2"
MOCK
chmod +x "$MOCK_BIN/claude"

# ============================================================
section "43. upload-log.sh build_log_path / build_markdown"
# ============================================================

# Force exit 0 (fed into bare X=$(...) assignments under set -e; see run_filter).
run_path() { ( UPLOAD_LOG_LIB=1 source "$UPLOAD_SCRIPT"; build_log_path "$1" "$2" "$3" ); return 0; }
run_md()   { ( UPLOAD_LOG_LIB=1 source "$UPLOAD_SCRIPT"; build_markdown "$1" "$2" ); return 0; }

# Path: base_dir/YYYY/MM/DD/HHMMSS_taskname.md, with taskname sanitized
P=$(run_path "work-log" "2026-07-04T15:30:12+0900" "my task/name")
[[ "$P" == "work-log/2026/07/04/153012_my-task-name.md" ]] \
    && pass "log path built correctly" || fail "wrong log path: $P"

# Markdown: contains title / summary text / cost; upload is limited to summary +
# conversation summary (the raw record message must NOT be included), and a
# secret echoed by the LLM into the summary must be masked.
REC='{"tab":"demo-task","session":"s1","completed_at":"2026-07-04T15:30:12+0900","message":"RAWMESSAGEMARKER should not appear","summary":{"model":"claude-opus-4-6","total_turns":3,"total_tool_calls":5,"total_cost_usd":0.42,"tools_used":["Edit","Bash"]},"markers":{"merged":true,"slack":false,"doc":true}}'
MD=$(run_md "$REC" "- 要約テスト行 leaked ghp_abcdefghijklmnopqrstuvwxyz0123456789")
echo "$MD" | grep -q "demo-task"     && pass "markdown has task title" || fail "no title: $MD"
echo "$MD" | grep -q "要約テスト行"   && pass "markdown has conversation summary" || fail "no summary: $MD"
echo "$MD" | grep -q "0.42"          && pass "markdown has cost" || fail "no cost: $MD"
! echo "$MD" | grep -q "RAWMESSAGEMARKER" && pass "raw record message excluded from upload" || fail "raw message leaked: $MD"
! echo "$MD" | grep -q "ghp_abcdef"  && pass "markdown masks secret echoed in summary" || fail "secret leaked: $MD"

# ============================================================
section "44. upload-log.sh (end-to-end push to log repo)"
# ============================================================

# Local bare repo acts as the remote log repository
REMOTE="$SANDBOX/remote-log.git"
git init --bare -q "$REMOTE"
SEED="$SANDBOX/seed-log"
git clone -q "$REMOTE" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b main
echo "# work logs" > "$SEED/README.md"
git -C "$SEED" add .
git -C "$SEED" -c user.email=seed@local -c user.name=seed commit -q -m init
git -C "$SEED" push -q origin main 2>/dev/null

# Enable upload, pointing at the local bare repo
jq --arg repo "$REMOTE" '.upload.enabled=true | .upload.repo=$repo | .upload.base_dir="work-log" | .upload.branch="main"' \
    "$HOME/.claude-conductor/config.default.json" > "$UPLOAD_CONFIG"

E2E_TRANSCRIPT="$SANDBOX/e2e-transcript.jsonl"
cat > "$E2E_TRANSCRIPT" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"do the thing"},"uuid":"u1","timestamp":"2026-07-04T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":100,"output_tokens":50}},"uuid":"a1","timestamp":"2026-07-04T10:00:01Z"}
TRANSCRIPT

# Pending message uses a marker to verify it is NOT included in the upload
cat > "$PENDING_DIR/e2e.json" << EOF
{
  "tab": "upload-e2e",
  "session": "test-session",
  "message": "RAWMESSAGEMARKER should not appear",
  "event": "Stop",
  "time": "10:00:01",
  "transcript_path": "$E2E_TRANSCRIPT"
}
EOF

# Mock claude echoes a secret in its summary to verify the final filter masks it
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
echo "- 作業を実施。誤って ghp_abcdefghijklmnopqrstuvwxyz0123456789 を含む要約"
MOCK
chmod +x "$MOCK_BIN/claude"

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "upload-e2e"
ZELLIJ_SESSION_NAME=test-session bash "$UPLOAD_SCRIPT" "upload-e2e" >/dev/null 2>&1 \
    && pass "upload-log.sh exits 0 on success" || fail "upload-log.sh failed on success path"

# Verify the log file landed in the remote
VERIFY="$SANDBOX/verify-log"
git clone -q "$REMOTE" "$VERIFY" 2>/dev/null
LOGFILE=$(find "$VERIFY/work-log" -name '*_upload-e2e.md' 2>/dev/null | head -1)
[[ -n "$LOGFILE" ]] && pass "log file pushed to repo" || fail "log file not found in repo"
if [[ -n "$LOGFILE" ]]; then
    grep -q "upload-e2e" "$LOGFILE" && pass "pushed log has task title" || fail "pushed log missing title"
    grep -q "2026/07/04" <<< "$LOGFILE" && pass "log stored under YYYY/MM/DD" || fail "wrong date path: $LOGFILE"
    ! grep -q "ghp_abcdef" "$LOGFILE" && pass "pushed log masks LLM-echoed secret" || fail "secret leaked in pushed log"
    ! grep -q "RAWMESSAGEMARKER" "$LOGFILE" && pass "pushed log excludes raw message" || fail "raw message leaked in pushed log"
fi

# Failure path: summary generation fails -> upload aborts (non-zero) so dd is cancelled
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"
cat > "$PENDING_DIR/e2e-fail.json" << EOF
{ "tab":"upload-e2e-fail","session":"test-session","message":"m","event":"Stop","time":"10:00:02","transcript_path":"$E2E_TRANSCRIPT" }
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "upload-e2e-fail"
if ZELLIJ_SESSION_NAME=test-session bash "$UPLOAD_SCRIPT" "upload-e2e-fail" >/dev/null 2>&1; then
    fail "upload-log.sh should exit non-zero when summary fails"
else
    pass "upload-log.sh aborts (non-zero) when summary fails"
fi
# Restore working mock claude
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
echo "- モックの作業要約1"
MOCK
chmod +x "$MOCK_BIN/claude"
rm -f "$UPLOAD_CONFIG" "$PENDING_DIR"/e2e*.json

# ============================================================
section "45. dd deletion integrates upload-log.sh"
# ============================================================

TC="$HOME/.claude-conductor/scripts/task-control.sh"
DL="$HOME/.claude-conductor/scripts/dashboard-loop.sh"

grep -q 'upload-log.sh' "$TC" && pass "task-control.sh calls upload-log.sh" || fail "task-control.sh missing upload call"
grep -q 'Deletion cancelled' "$TC" && pass "task-control.sh cancels dd on upload failure" || fail "task-control.sh missing guard"
grep -q 'upload-log.sh' "$DL" && pass "dashboard-loop.sh calls upload-log.sh" || fail "dashboard-loop.sh missing upload call"
grep -q 'Deletion cancelled' "$DL" && pass "dashboard-loop.sh cancels dd on upload failure" || fail "dashboard-loop.sh missing guard"

# Functional: with upload disabled (default), dd still deletes the tab (no regression)
cat > "$PENDING_DIR/tc-del.json" << 'EOF'
{ "tab":"tc-del","session":"test-session","message":"done","event":"Stop","time":"12:00:00" }
EOF
CALLS="$HOME/.claude-pending/zellij-calls.log"
: > "$CALLS"
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC" "tc-del" >/dev/null 2>&1
[[ ! -f "$PENDING_DIR/tc-del.json" ]] && pass "dd removes pending when upload disabled" || fail "pending not removed"
grep -q 'close-tab' "$CALLS" && pass "dd closes tab when upload disabled" || fail "close-tab not called"

# dd must close ITS OWN tab by id (not the active tab): a mid-upload focus change
# must not let it close the wrong tab. Mock zellij returns list-tabs data here.
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
if [[ "$1 $2" == "action list-tabs" ]]; then
    printf 'TAB_ID  POSITION  NAME\n7  2  tc-del-id\n'
fi
MOCK
chmod +x "$MOCK_BIN/zellij"
cat > "$PENDING_DIR/tc-del-id.json" << 'EOF'
{ "tab":"tc-del-id","session":"test-session","message":"done","event":"Stop","time":"12:00:00" }
EOF
: > "$CALLS"
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC" "tc-del-id" >/dev/null 2>&1
grep -q 'close-tab-by-id 7' "$CALLS" && pass "dd closes its own tab by id" || fail "close-tab-by-id not called with correct id: $(cat "$CALLS")"

# A tab name containing spaces must still resolve to the correct tab id.
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
if [[ "$1 $2" == "action list-tabs" ]]; then
    printf 'TAB_ID  POSITION  NAME\n3  1  My Task dev\n'
fi
MOCK
chmod +x "$MOCK_BIN/zellij"
cat > "$PENDING_DIR/my-space.json" << 'EOF'
{ "tab":"My Task dev","session":"test-session","message":"done","event":"Stop","time":"12:00:00" }
EOF
: > "$CALLS"
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC" "My Task dev" >/dev/null 2>&1
grep -q 'close-tab-by-id 3' "$CALLS" && pass "dd resolves a spaced tab name to its id" || fail "spaced tab name not resolved: $(cat "$CALLS")"

# Restore the plain mock zellij for later sections
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
MOCK
chmod +x "$MOCK_BIN/zellij"

# On a real (non-empty) upload success, the confirmation is shown but the tab
# is still deleted and closed afterwards.
UPLOAD_REAL="$HOME/.claude-conductor/scripts/upload-log.sh"
mv "$UPLOAD_REAL" "$UPLOAD_REAL.real"
cat > "$UPLOAD_REAL" << 'STUB'
#!/bin/bash
echo "upload-log: アップロードしました -> https://example/log.md"
exit 0
STUB
chmod +x "$UPLOAD_REAL"
cat > "$PENDING_DIR/tc-ok.json" << 'EOF'
{ "tab":"tc-ok","session":"test-session","message":"done","event":"Stop","time":"12:00:00" }
EOF
: > "$CALLS"
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC" "tc-ok" >/dev/null 2>&1
[[ ! -f "$PENDING_DIR/tc-ok.json" ]] && pass "dd deletes pending after a confirmed upload" || fail "pending not removed after upload"
grep -q 'close-tab' "$CALLS" && pass "dd closes tab after a confirmed upload" || fail "tab not closed after upload"
mv "$UPLOAD_REAL.real" "$UPLOAD_REAL"

# ============================================================
section "46. upload-log.sh push_log (bootstrap + idempotent)"
# ============================================================

run_push() {
    ( UPLOAD_LOG_LIB=1 source "$UPLOAD_SCRIPT"; push_log "$1" "$2" "$3" "$4" )
}

# A self-contained populated repo (seeded 'main') for this section's C/D cases,
# so it does not depend on state created in the end-to-end push section (44).
POP_REMOTE="$SANDBOX/pop-log.git"
git init --bare -q "$POP_REMOTE"
POP_SEED="$SANDBOX/pop-seed"
git clone -q "$POP_REMOTE" "$POP_SEED" 2>/dev/null
git -C "$POP_SEED" checkout -q -b main
echo "# logs" > "$POP_SEED/README.md"
git -C "$POP_SEED" add .
git -C "$POP_SEED" -c user.email=s@s -c user.name=s commit -q -m init
git -C "$POP_SEED" push -q origin main 2>/dev/null

# A) Bootstrap: push to a brand-new EMPTY bare repo (no branch exists yet)
EMPTY_REMOTE="$SANDBOX/empty-log.git"
git init --bare -q "$EMPTY_REMOTE"
rm -rf "$HOME/.claude-conductor/upload-cache"
if run_push "$EMPTY_REMOTE" "main" "work-log/2026/07/04/120000_boot.md" "hello world" >/dev/null 2>&1; then
    pass "push_log bootstraps an empty repo"
else
    fail "push_log failed to bootstrap empty repo"
fi
BOOT_VERIFY="$SANDBOX/boot-verify"
git clone -q "$EMPTY_REMOTE" "$BOOT_VERIFY" 2>/dev/null
[[ -f "$BOOT_VERIFY/work-log/2026/07/04/120000_boot.md" ]] \
    && pass "bootstrapped log present in remote" || fail "log not found after bootstrap"

# B) Idempotent: pushing identical content to the same path must not fail (nothing-to-commit)
if run_push "$EMPTY_REMOTE" "main" "work-log/2026/07/04/120000_boot.md" "hello world" >/dev/null 2>&1; then
    pass "push_log succeeds on identical re-upload (no nothing-to-commit abort)"
else
    fail "push_log aborted on identical re-upload"
fi

# C) Branch that does not exist yet on a populated repo is created
if run_push "$POP_REMOTE" "logs-2026" "work-log/x.md" "content x" >/dev/null 2>&1; then
    pass "push_log creates a non-existent branch"
else
    fail "push_log failed to create new branch"
fi

# D) Reusing the same cache to push to yet another new branch must still work
#    (regression guard for basing the branch off a stale FETCH_HEAD).
if run_push "$POP_REMOTE" "logs-2027" "work-log/y.md" "content y" >/dev/null 2>&1; then
    pass "push_log switches branch on a reused cache"
else
    fail "push_log failed to switch branch on reused cache"
fi
D_VERIFY="$SANDBOX/d-verify"
git clone -q --branch logs-2027 "$POP_REMOTE" "$D_VERIFY" 2>/dev/null
[[ -f "$D_VERIFY/work-log/y.md" ]] && pass "reused-cache branch pushed correctly" || fail "reused-cache push missing file"

# ============================================================
section "47. upload-log.sh uses record from any daily file (cross-day)"
# ============================================================

# The summary record lives ONLY in a non-today daily file; upload must still use
# its real stats and store the log under the record's date (not today's).
# Self-contained: own transcript, own mock claude, own populated repo ($POP_REMOTE).
OLD_DAILY="$HOME/.claude-conductor/daily/test-session/2020-01-01.jsonl"
cat > "$OLD_DAILY" << 'EOF'
{"tab":"xday-task","session":"test-session","completed_at":"2020-01-01T09:00:00+0900","message":"m","summary":{"model":"claude-opus-4-6","total_turns":7,"total_tool_calls":9,"tools_used":["Bash"],"total_cost_usd":1.23},"markers":{"merged":false,"slack":false,"doc":false}}
EOF

XDAY_TRANSCRIPT="$SANDBOX/xday-transcript.jsonl"
cat > "$XDAY_TRANSCRIPT" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"x"},"uuid":"u1","timestamp":"2020-01-01T09:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"y"}],"usage":{"input_tokens":10,"output_tokens":5}},"uuid":"a1","timestamp":"2020-01-01T09:00:01Z"}
TRANSCRIPT

cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
cat >/dev/null
echo "- 要約"
MOCK
chmod +x "$MOCK_BIN/claude"

jq --arg repo "$POP_REMOTE" '.upload.enabled=true | .upload.repo=$repo | .upload.base_dir="work-log" | .upload.branch="main"' \
    "$HOME/.claude-conductor/config.default.json" > "$UPLOAD_CONFIG"

cat > "$PENDING_DIR/xday.json" << EOF
{ "tab":"xday-task","session":"test-session","message":"m","event":"Stop","time":"09:00:00","transcript_path":"$XDAY_TRANSCRIPT" }
EOF

# record-output.sh is intentionally NOT run, so today's file has no xday-task record
ZELLIJ_SESSION_NAME=test-session bash "$UPLOAD_SCRIPT" "xday-task" >/dev/null 2>&1 \
    && pass "upload succeeds using a cross-day record" || fail "cross-day upload failed"

XV="$SANDBOX/xday-verify"
git clone -q "$POP_REMOTE" "$XV" 2>/dev/null
XLOG=$(find "$XV/work-log" -name '*_xday-task.md' 2>/dev/null | head -1)
[[ -n "$XLOG" ]] && grep -q "1.23" "$XLOG" \
    && pass "cross-day log carries real stats (cost)" || fail "stats missing/zeroed: $XLOG"
grep -q "2020/01/01" <<< "$XLOG" \
    && pass "cross-day log stored under the record's date" || fail "wrong date path: $XLOG"
rm -f "$UPLOAD_CONFIG" "$PENDING_DIR"/xday.json "$OLD_DAILY"

# ============================================================
section "48. bump-version.sh (semver bump calculation)"
# ============================================================

BUMP_SCRIPT="$CONDUCTOR_HOME/scripts/bump-version.sh"

# Runs bump-version.sh and captures stdout; error cases handled separately below.
[[ "$(bash "$BUMP_SCRIPT" patch v0.0.0)" == "v0.0.1" ]] \
    && pass "patch from v0.0.0 -> v0.0.1" || fail "patch from v0.0.0 wrong: $(bash "$BUMP_SCRIPT" patch v0.0.0)"
[[ "$(bash "$BUMP_SCRIPT" minor v0.0.0)" == "v0.1.0" ]] \
    && pass "minor from v0.0.0 -> v0.1.0" || fail "minor from v0.0.0 wrong: $(bash "$BUMP_SCRIPT" minor v0.0.0)"
[[ "$(bash "$BUMP_SCRIPT" major v0.0.0)" == "v1.0.0" ]] \
    && pass "major from v0.0.0 -> v1.0.0" || fail "major from v0.0.0 wrong: $(bash "$BUMP_SCRIPT" major v0.0.0)"
[[ "$(bash "$BUMP_SCRIPT" patch v1.2.3)" == "v1.2.4" ]] \
    && pass "patch from v1.2.3 -> v1.2.4" || fail "patch from v1.2.3 wrong: $(bash "$BUMP_SCRIPT" patch v1.2.3)"
[[ "$(bash "$BUMP_SCRIPT" minor v1.2.3)" == "v1.3.0" ]] \
    && pass "minor from v1.2.3 -> v1.3.0 (resets patch)" || fail "minor from v1.2.3 wrong: $(bash "$BUMP_SCRIPT" minor v1.2.3)"
[[ "$(bash "$BUMP_SCRIPT" major v1.2.3)" == "v2.0.0" ]] \
    && pass "major from v1.2.3 -> v2.0.0 (resets minor+patch)" || fail "major from v1.2.3 wrong: $(bash "$BUMP_SCRIPT" major v1.2.3)"

# Accepts current version without the leading 'v'
[[ "$(bash "$BUMP_SCRIPT" minor 1.2.3)" == "v1.3.0" ]] \
    && pass "accepts version without leading v" || fail "no-v prefix wrong: $(bash "$BUMP_SCRIPT" minor 1.2.3)"

# Empty current version is treated as the 0.0.0 seed base
[[ "$(bash "$BUMP_SCRIPT" minor '')" == "v0.1.0" ]] \
    && pass "empty current version seeds from 0.0.0" || fail "empty current wrong: $(bash "$BUMP_SCRIPT" minor '')"

# Invalid bump type must fail (exit non-zero)
set +e
bash "$BUMP_SCRIPT" bogus v1.2.3 >/dev/null 2>&1; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "invalid bump type exits non-zero" || fail "invalid bump type did not fail"

# Malformed current version must fail (exit non-zero)
set +e
bash "$BUMP_SCRIPT" patch "1.2" >/dev/null 2>&1; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "malformed version exits non-zero" || fail "malformed version did not fail"

# ============================================================
section "49. install.sh embeds VERSION"
# ============================================================

# install.sh (run at the top of this suite) must drop a VERSION file into
# CONDUCTOR_HOME derived from the git tag, or the v0.0.0 fallback when untagged.
[[ -f "$CONDUCTOR_HOME/VERSION" ]] && pass "VERSION file created" || fail "VERSION file missing"
VER=$(cat "$CONDUCTOR_HOME/VERSION" 2>/dev/null)
[[ -n "$VER" ]] && pass "VERSION file is non-empty" || fail "VERSION file empty"
echo "$VER" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    && pass "VERSION matches semver format ($VER)" || fail "VERSION not semver: $VER"

# ============================================================
section "50. update-lib.sh (repo slug + version compare)"
# ============================================================

UPDATE_LIB="$CONDUCTOR_HOME/scripts/update-lib.sh"

slug() { ( source "$UPDATE_LIB"; uc_repo_slug "$1" ); }
[[ "$(slug 'git@github.com:owner/repo.git')" == "owner/repo" ]] \
    && pass "repo_slug parses SSH url" || fail "SSH slug wrong: $(slug 'git@github.com:owner/repo.git')"
[[ "$(slug 'https://github.com/owner/repo.git')" == "owner/repo" ]] \
    && pass "repo_slug parses HTTPS url with .git" || fail "HTTPS .git slug wrong: $(slug 'https://github.com/owner/repo.git')"
[[ "$(slug 'https://github.com/owner/repo')" == "owner/repo" ]] \
    && pass "repo_slug parses HTTPS url without .git" || fail "HTTPS slug wrong: $(slug 'https://github.com/owner/repo')"
[[ "$(slug 'ssh://git@github.com/owner/repo.git')" == "owner/repo" ]] \
    && pass "repo_slug parses ssh:// url" || fail "ssh:// slug wrong: $(slug 'ssh://git@github.com/owner/repo.git')"
set +e
( source "$UPDATE_LIB"; uc_repo_slug "" ) >/dev/null 2>&1; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "repo_slug empty url returns non-zero" || fail "empty url did not fail"

vgt() { ( source "$UPDATE_LIB"; uc_version_gt "$1" "$2" ); }
vgt v1.2.4 v1.2.3 && pass "version_gt patch newer" || fail "v1.2.4 > v1.2.3 wrong"
vgt v1.3.0 v1.2.9 && pass "version_gt minor beats higher patch" || fail "v1.3.0 > v1.2.9 wrong"
vgt v2.0.0 v1.9.9 && pass "version_gt major beats higher minor" || fail "v2.0.0 > v1.9.9 wrong"
vgt v1.2.10 v1.2.9 && pass "version_gt numeric (not lexical) 10>9" || fail "v1.2.10 > v1.2.9 wrong"
vgt 1.2.4 1.2.3 && pass "version_gt accepts no-v prefix" || fail "1.2.4 > 1.2.3 wrong"
set +e
vgt v1.2.3 v1.2.3; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "version_gt equal is not greater" || fail "equal reported as greater"
set +e
vgt v1.2.3 v1.2.4; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "version_gt older is not greater" || fail "older reported as greater"

# ============================================================
section "51. install.sh records REPO_URL and honors overrides"
# ============================================================

# The top-level install ran from a git checkout, so REPO_URL is recorded.
[[ -f "$CONDUCTOR_HOME/REPO_URL" ]] && pass "REPO_URL file created" || fail "REPO_URL file missing"
grep -q "claude-conductor" "$CONDUCTOR_HOME/REPO_URL" \
    && pass "REPO_URL points at the origin repo" || fail "REPO_URL wrong: $(cat "$CONDUCTOR_HOME/REPO_URL" 2>/dev/null)"

# A tarball-based update has no .git, so update.sh injects the version and URL
# via env vars. Verify install.sh honors them (isolated HOME to avoid clobber).
OV_HOME="$SANDBOX/override-home"
mkdir -p "$OV_HOME"
touch "$OV_HOME/.zshrc"
(
    export HOME="$OV_HOME"
    echo n | CONDUCTOR_VERSION="v9.9.9" CONDUCTOR_REPO_URL="https://github.com/o/r.git" \
        bash "$REPO_DIR/install.sh" >/dev/null 2>&1
)
[[ "$(cat "$OV_HOME/.claude-conductor/VERSION" 2>/dev/null)" == "v9.9.9" ]] \
    && pass "install.sh honors CONDUCTOR_VERSION override" || fail "CONDUCTOR_VERSION not honored: $(cat "$OV_HOME/.claude-conductor/VERSION" 2>/dev/null)"
[[ "$(cat "$OV_HOME/.claude-conductor/REPO_URL" 2>/dev/null)" == "https://github.com/o/r.git" ]] \
    && pass "install.sh honors CONDUCTOR_REPO_URL override" || fail "CONDUCTOR_REPO_URL not honored: $(cat "$OV_HOME/.claude-conductor/REPO_URL" 2>/dev/null)"

# ============================================================
section "52. check-update.sh (startup update notice)"
# ============================================================

CHECK="$CONDUCTOR_HOME/scripts/check-update.sh"

# Local bare repo with two semver tags; v0.2.0 is newer than installed v0.1.0.
UPD_REMOTE="$SANDBOX/upd-remote.git"
git init --bare -q "$UPD_REMOTE"
UPD_SEED="$SANDBOX/upd-seed"
git clone -q "$UPD_REMOTE" "$UPD_SEED" 2>/dev/null
git -C "$UPD_SEED" checkout -q -b main
echo x > "$UPD_SEED/f"
git -C "$UPD_SEED" add .
git -C "$UPD_SEED" -c user.email=a@b -c user.name=a commit -q -m init
git -C "$UPD_SEED" tag v0.1.0
git -C "$UPD_SEED" tag v0.2.0
git -C "$UPD_SEED" push -q origin main --tags 2>/dev/null

echo "$UPD_REMOTE" > "$CONDUCTOR_HOME/REPO_URL"
echo "v0.1.0" > "$CONDUCTOR_HOME/VERSION"
rm -f "$CONDUCTOR_HOME/.update-check"

OUT=$(bash "$CHECK" --force 2>&1)
echo "$OUT" | grep -q "v0.2.0" && pass "notice shown when outdated" || fail "no notice when outdated: $OUT"
echo "$OUT" | grep -q "mdev update" && pass "notice suggests mdev update" || fail "notice missing command: $OUT"
[[ -f "$CONDUCTOR_HOME/.update-check" ]] && grep -q "v0.2.0" "$CONDUCTOR_HOME/.update-check" \
    && pass "latest tag cached with date" || fail "cache not written"

# Up to date: installed == latest -> no notice
echo "v0.2.0" > "$CONDUCTOR_HOME/VERSION"
rm -f "$CONDUCTOR_HOME/.update-check"
OUT=$(bash "$CHECK" --force 2>&1)
[[ -z "$OUT" ]] && pass "no notice when up to date" || fail "unexpected notice when current: $OUT"

# Disabled via config -> no notice even when outdated
echo "v0.1.0" > "$CONDUCTOR_HOME/VERSION"
rm -f "$CONDUCTOR_HOME/.update-check"
printf '{"update_check":{"enabled":false}}' > "$CONDUCTOR_HOME/config.json"
OUT=$(bash "$CHECK" --force 2>&1)
[[ -z "$OUT" ]] && pass "no notice when update_check disabled" || fail "notice despite disabled: $OUT"
rm -f "$CONDUCTOR_HOME/config.json"

# Unreachable remote -> silent, exit 0 (never blocks startup)
echo "v0.1.0" > "$CONDUCTOR_HOME/VERSION"
rm -f "$CONDUCTOR_HOME/.update-check"
echo "$SANDBOX/does-not-exist.git" > "$CONDUCTOR_HOME/REPO_URL"
set +e
OUT=$(bash "$CHECK" --force 2>&1); RC=$?
set -e
[[ $RC -eq 0 && -z "$OUT" ]] && pass "silent + exit 0 on network failure" || fail "not silent on failure: rc=$RC out=$OUT"

# Empty REPO_URL -> silent exit 0
: > "$CONDUCTOR_HOME/REPO_URL"
set +e
OUT=$(bash "$CHECK" --force 2>&1); RC=$?
set -e
[[ $RC -eq 0 && -z "$OUT" ]] && pass "silent when REPO_URL empty" || fail "not silent on empty URL"

# Restore installed version for later sections
echo "v0.1.0" > "$CONDUCTOR_HOME/VERSION"

# ============================================================
section "53. update.sh (download tarball + reinstall)"
# ============================================================

UPDATE_SH="$CONDUCTOR_HOME/scripts/update.sh"

# update.sh downloads a real tarball via curl; the fetch-news mock curl would
# hijack that. Disable it for this section (restored before Uninstall).
[ -f "$MOCK_BIN/curl" ] && mv "$MOCK_BIN/curl" "$MOCK_BIN/curl.disabled"

# A real update runs on an already-configured system, so install.sh skips its
# interactive .zshrc prompt. Mirror that here (top-level install answered "n").
grep -qF "claude-conductor/init.zsh" "$HOME/.zshrc" \
    || echo 'source "$HOME/.claude-conductor/init.zsh"' >> "$HOME/.zshrc"

# Reuse the bare repo from section 52 (has tag v0.2.0). Point install at it.
echo "$UPD_REMOTE" > "$CONDUCTOR_HOME/REPO_URL"
echo "v0.1.0" > "$CONDUCTOR_HOME/VERSION"

# Build a release source tarball named like GitHub's: conductor-0.2.0/...
STAGE="$SANDBOX/stage"
SRCDIR="$STAGE/conductor-0.2.0"
mkdir -p "$SRCDIR"
cp -R "$CONDUCTOR_HOME/scripts" "$SRCDIR/scripts"
cp -R "$CONDUCTOR_HOME/layouts" "$SRCDIR/layouts"
cp "$CONDUCTOR_HOME/init.zsh" "$SRCDIR/init.zsh"
cp "$CONDUCTOR_HOME/hooks.json" "$SRCDIR/hooks.json"
cp "$CONDUCTOR_HOME/config.default.json" "$SRCDIR/config.default.json"
cp "$REPO_DIR/install.sh" "$SRCDIR/install.sh"
TARBALL="$SANDBOX/release-0.2.0.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" conductor-0.2.0

# Run update from the local tarball (file:// so no network is needed).
OUT=$(CONDUCTOR_TARBALL_URL="file://$TARBALL" bash "$UPDATE_SH" 2>&1)
echo "$OUT" | grep -q "v0.2.0 に更新しました" && pass "update.sh reports success" || fail "no success message: $OUT"
[[ "$(cat "$CONDUCTOR_HOME/VERSION" 2>/dev/null)" == "v0.2.0" ]] \
    && pass "VERSION updated to latest tag" || fail "VERSION not updated: $(cat "$CONDUCTOR_HOME/VERSION" 2>/dev/null)"

# Already up to date -> no download, exits 0 with a note
echo "v0.2.0" > "$CONDUCTOR_HOME/VERSION"
OUT=$(CONDUCTOR_TARBALL_URL="file://$SANDBOX/nonexistent.tar.gz" bash "$UPDATE_SH" 2>&1)
echo "$OUT" | grep -q "既に最新" && pass "update.sh no-ops when already current" || fail "did not detect current: $OUT"

# Missing REPO_URL -> error, non-zero exit
: > "$CONDUCTOR_HOME/REPO_URL"
set +e
OUT=$(bash "$UPDATE_SH" 2>&1); RC=$?
set -e
[[ $RC -ne 0 ]] && pass "update.sh fails when REPO_URL unknown" || fail "did not fail on missing URL: $OUT"

# Restore the mock curl for any later use
[ -f "$MOCK_BIN/curl.disabled" ] && mv "$MOCK_BIN/curl.disabled" "$MOCK_BIN/curl"

# ============================================================
section "54. Uninstall"
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
