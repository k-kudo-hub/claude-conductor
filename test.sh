#!/bin/bash
# Claude Conductor - Sandbox Test
# Creates a temporary $HOME and tests install/uninstall/scripts

set -e

# Conductorのタスクタブ内から実行しても、create_taskがexportするタブ環境
# （TASK_*）とZellijのセッション変数がテストへ漏れないよう除去する
unset TASK_TAB_NAME TASK_TYPE TASK_AGENT ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID

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

# コマンドを最大 <sec> 秒だけ動かし、超過したら kill する。テスト対象がハングしても
# テスト自体は必ず抜けてくるようにするための番犬（macOS に timeout(1) は無く、
# bash 3.2 に wait -n も無いのでポーリングで代用する）。
# 使い方: run_with_watchdog <sec> <関数名/コマンド...>  超過時は 124 を返す。
run_with_watchdog() {
    local limit="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $waited -ge $((limit * 10)) ]]; then
            { kill -9 "$pid"; wait "$pid"; } 2>/dev/null
            return 124
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
    return $?
}

# Create a mock zellij that records calls but doesn't hang
MOCK_BIN="$SANDBOX/mock-bin"
mkdir -p "$MOCK_BIN"
MOCK_TAB_FILE="$HOME/.claude-pending/mock-tabs.txt"
MOCK_QTN_COUNT="$HOME/.claude-pending/mock-qtn-count"
MOCK_GOTO_COUNT="$HOME/.claude-pending/mock-goto-count"
# 実タブの状態を持たないテストへ戻すためのリセット（各レーステストの先頭で呼ぶ）
mock_zellij_reset() {
    rm -f "$MOCK_TAB_FILE" "$MOCK_QTN_COUNT" "$MOCK_GOTO_COUNT"
    : > "$HOME/.claude-pending/zellij-calls.log"
}
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
MOCK_TAB_FILE="$HOME/.claude-pending/mock-tabs.txt"
MOCK_QTN_COUNT="$HOME/.claude-pending/mock-qtn-count"
MOCK_GOTO_COUNT="$HOME/.claude-pending/mock-goto-count"

# 劣化したzellijサーバの再現: MOCK_HANG_CMD で指定したサブコマンドは戻ってこない。
# exec で自プロセスを置き換えるので、kill ガードが殺すPIDがそのまま眠るプロセスになる
# （実機のハングも zellij 1プロセスが眠る形なので同じ）。
if [[ -n "$MOCK_HANG_CMD" && "$2" == "$MOCK_HANG_CMD" ]]; then
    exec sleep 251
fi

# new-tab は作成したタブ名を記録する。以降の query-tab-names / go-to-tab-name が
# 実サーバと同じように「そのタブが在る」ものとして振る舞う。
if [[ "$1" == "action" && "$2" == "new-tab" ]]; then
    _prev=""; _name=""
    for _a in "$@"; do
        if [[ "$_prev" == "-n" ]]; then _name="$_a"; break; fi
        _prev="$_a"
    done
    [[ -n "$_name" ]] && echo "$_name" >> "$MOCK_TAB_FILE"
fi

# query-tab-names は登録済みタブ名を1行ずつ返す。
# MOCK_TAB_REGISTER_AFTER=N: サーバが重くタブ登録が遅れる状況の再現で、
# N 回目の呼び出しまでは何も返さない（new-tab が rc=0 で戻っても名前は見えない）。
if [[ "$1" == "action" && "$2" == "query-tab-names" ]]; then
    _n=$(cat "$MOCK_QTN_COUNT" 2>/dev/null || echo 0)
    _n=$((_n + 1))
    echo "$_n" > "$MOCK_QTN_COUNT"
    if [[ -z "$MOCK_TAB_REGISTER_AFTER" || "$_n" -ge "$MOCK_TAB_REGISTER_AFTER" ]]; then
        # MOCK_TAB_NAMES は new-tab を経ずに「元から在るタブ」を並べるための入口
        [[ -n "$MOCK_TAB_NAMES" ]] && printf '%s\n' "$MOCK_TAB_NAMES"
        cat "$MOCK_TAB_FILE" 2>/dev/null
    fi
fi

# go-to-tab-name は zellij 0.44.1 実測どおり、存在しないタブ名でも rc=0 で戻り、
# ヒットしたときだけ stdout にタブ index を出す（ミス時は stdout 空）。
# MOCK_FOCUS_EMPTY_UNTIL=K: K 回目までは登録済みタブでも stdout を空にする。
if [[ "$1" == "action" && "$2" == "go-to-tab-name" ]]; then
    _k=$(cat "$MOCK_GOTO_COUNT" 2>/dev/null || echo 0)
    _k=$((_k + 1))
    echo "$_k" > "$MOCK_GOTO_COUNT"
    if [[ -n "$MOCK_FOCUS_EMPTY_UNTIL" && "$_k" -le "$MOCK_FOCUS_EMPTY_UNTIL" ]]; then
        exit 0
    fi
    if grep -Fxq -- "$3" "$MOCK_TAB_FILE" 2>/dev/null; then
        echo 0
    fi
fi
# Emit a fake `list-tabs` output when MOCK_TABS is set (3rd column is the tab name)
if [[ "$1" == "action" && "$2" == "list-tabs" && -n "$MOCK_TABS" ]]; then
    echo "ID X NAME"
    for t in $MOCK_TABS; do
        echo "1 x $t"
    done
fi
# Emit fake `list-sessions` lines when MOCK_SESSIONS_OUTPUT is set
# (real zellij 0.44 format, one session per line)
if [[ "$1" == "list-sessions" && -n "$MOCK_SESSIONS_OUTPUT" ]]; then
    printf '%s\n' "$MOCK_SESSIONS_OUTPUT"
fi
# Emit a fake `list-panes -t -c -j` JSON array when MOCK_PANES_JSON is set
if [[ "$1" == "action" && "$2" == "list-panes" && -n "$MOCK_PANES_JSON" ]]; then
    printf '%s\n' "$MOCK_PANES_JSON"
fi
# Emit a fake `dump-screen -p terminal_N` from $MOCK_SCREEN_DIR/terminal_N.txt
if [[ "$1" == "action" && "$2" == "dump-screen" && -n "$MOCK_SCREEN_DIR" ]]; then
    cat "$MOCK_SCREEN_DIR/$4.txt" 2>/dev/null
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
[[ -f "$HOME/.claude-conductor/scripts/registry-lib.sh" ]] && pass "registry-lib.sh installed" || fail "registry-lib.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/codex-rollout-lib.sh" ]] && pass "codex-rollout-lib.sh installed" || fail "codex-rollout-lib.sh missing"
[[ -f "$HOME/.claude-conductor/scripts/restore-session.sh" ]] && pass "restore-session.sh installed" || fail "restore-session.sh missing"
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
section "2b. Codex notify merge into ~/.codex/config.toml"
# ============================================================

# Mock codex so the merge path runs even where codex is not installed
cat > "$MOCK_BIN/codex" << 'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$MOCK_BIN/codex"

# Existing config with a table: notify must land BEFORE the table header,
# otherwise TOML parses it as a key of that table and codex ignores it.
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" << 'TOML'
[projects."/tmp/foo"]
trust_level = "trusted"
TOML

echo "n" | bash "$REPO_DIR/install.sh" >/dev/null 2>&1

grep -q 'codex-notify.sh' "$HOME/.codex/config.toml" \
  && pass "notify merged into codex config" || fail "notify not merged"
grep -q 'trust_level = "trusted"' "$HOME/.codex/config.toml" \
  && pass "existing codex config preserved" || fail "existing codex config lost"
NOTIFY_LINENO=$(grep -n 'codex-notify.sh' "$HOME/.codex/config.toml" | head -1 | cut -d: -f1)
TABLE_LINENO=$(grep -n '^\[' "$HOME/.codex/config.toml" | head -1 | cut -d: -f1)
[[ -n "$NOTIFY_LINENO" && -n "$TABLE_LINENO" && "$NOTIFY_LINENO" -lt "$TABLE_LINENO" ]] \
  && pass "notify precedes the first TOML table" || fail "notify after table: line $NOTIFY_LINENO vs $TABLE_LINENO"

# Reinstall keeps a single notify line (idempotent)
echo "n" | bash "$REPO_DIR/install.sh" >/dev/null 2>&1
NOTIFY_COUNT=$(grep -c 'codex-notify.sh' "$HOME/.codex/config.toml")
[[ "$NOTIFY_COUNT" -eq 1 ]] && pass "reinstall keeps a single notify line" || fail "notify duplicated: $NOTIFY_COUNT"

# A notify set by another tool is left untouched
cat > "$HOME/.codex/config.toml" << 'TOML'
notify = ["python3", "/somewhere/else.py"]
TOML
echo "n" | bash "$REPO_DIR/install.sh" >/dev/null 2>&1
grep -q '/somewhere/else.py' "$HOME/.codex/config.toml" \
  && pass "foreign notify preserved" || fail "foreign notify overwritten"
grep -q 'codex-notify.sh' "$HOME/.codex/config.toml" \
  && fail "conductor notify added despite foreign notify" || pass "conductor notify not forced over foreign one"

# Missing config.toml is created with the notify line
rm -f "$HOME/.codex/config.toml"
echo "n" | bash "$REPO_DIR/install.sh" >/dev/null 2>&1
grep -q 'codex-notify.sh' "$HOME/.codex/config.toml" \
  && pass "config.toml created with notify" || fail "config.toml not created"

rm -f "$MOCK_BIN/codex"

# ============================================================
section "2c. FLAVOR file selects the go flavor"
# ============================================================

# $CONDUCTOR_HOME/FLAVOR が "go" かつ bin/mdev が実行可能なとき、install.sh は
# layouts を Go 版の `bin/mdev pane <name>` へ向け、hooks も `mdev hooks switch`
# で Go 版にする。これが無いと install.sh / mdev update の再実行が Go 版設定を
# 黙って巻き戻す。ロジックを再現せず install.sh をそのまま走らせて結果を見る。
# 共有 HOME を汚さないよう隔離 HOME を使う。
FLAVOR_HOME="$SANDBOX/flavor-home"
FLAVOR_CH="$FLAVOR_HOME/.claude-conductor"
FLAVOR_KDL="$FLAVOR_CH/layouts/multi.kdl"
FLAVOR_SETTINGS="$FLAVOR_HOME/.claude/settings.json"
FLAVOR_MDEV_LOG="$FLAVOR_HOME/mdev-calls.log"

flavor_reset() {
    rm -rf "$FLAVOR_HOME"
    mkdir -p "$FLAVOR_HOME/.claude" "$FLAVOR_HOME/.codex"
    # init 行を先に置けば install.sh は .zshrc の対話プロンプトに入らない
    echo 'source "$HOME/.claude-conductor/init.zsh"' > "$FLAVOR_HOME/.zshrc"
}

# 引数を記録するだけの bin/mdev。hooks switch が呼ばれたことの検証に使う。
flavor_stub_mdev() {
    mkdir -p "$FLAVOR_CH/bin"
    cat > "$FLAVOR_CH/bin/mdev" << 'STUB'
#!/bin/bash
echo "$*" >> "$HOME/mdev-calls.log"
STUB
    chmod +x "$FLAVOR_CH/bin/mdev"
}

# hooks switch の振る舞いを写した bin/mdev。mdev-go の
# internal/domain/hooksettings.go と同じ 3 規則でコマンド末尾だけを差し替え、
# 実際に変更があったときだけバックアップを作る（変更が無ければ何もしない）。
# バックアップが install のたびに増えないことを確かめるために要る。
flavor_stub_mdev_switch() {
    mkdir -p "$FLAVOR_CH/bin"
    cat > "$FLAVOR_CH/bin/mdev" << 'STUB'
#!/bin/bash
echo "$*" >> "$HOME/mdev-calls.log"
if [[ "$1" == "hooks" && "$2" == "switch" ]]; then
    S="$HOME/.claude/settings.json"
    [[ -f "$S" ]] || exit 0
    sed -e 's|/scripts/pending-notify\.sh|/bin/mdev hook notify|g' \
        -e 's|/scripts/pending-post-tool\.sh|/bin/mdev hook post-tool|g' \
        -e 's|/scripts/pending-resolve\.sh|/bin/mdev hook resolve|g' \
        "$S" > "$S.switched" || exit 1
    if cmp -s "$S" "$S.switched"; then
        rm -f "$S.switched"
        exit 0
    fi
    N=$(ls "$HOME/.claude" 2>/dev/null | grep -c 'settings.json.mdev-backup' || true)
    cp "$S" "$S.mdev-backup.$N"
    mv "$S.switched" "$S"
fi
exit 0
STUB
    chmod +x "$FLAVOR_CH/bin/mdev"
}

# 隔離 HOME で install.sh を実行する（CONDUCTOR_HOME は $HOME から決まる）
flavor_install() {
    (
        export HOME="$FLAVOR_HOME"
        export CODEX_HOME="$FLAVOR_HOME/.codex"
        echo n | bash "$REPO_DIR/install.sh" 2>&1
    )
}

# settings.json の `.hooks` 配下のコマンドを全部並べる。
# 添字を直に書くと hooks.json の並びが変わったとき別のものを見てしまう。
flavor_hook_commands() {
    jq -r '[.hooks // {} | to_entries[] | .value[] | .hooks[] | .command] | .[]' \
        "$FLAVOR_SETTINGS" 2>/dev/null || true
}

flavor_backup_count() {
    ls "$FLAVOR_HOME/.claude" 2>/dev/null | grep -c 'settings.json.mdev-backup' || true
}

# (a) FLAVOR 無し: 従来どおり Shell 版のレイアウトのまま
flavor_reset
flavor_install >/dev/null 2>&1 || fail "install.sh (no FLAVOR) exited non-zero"
cmp -s "$REPO_DIR/layouts/multi.kdl" "$FLAVOR_KDL" \
  && pass "no FLAVOR installs the repo multi.kdl byte for byte" \
  || fail "no FLAVOR altered multi.kdl: $(diff "$REPO_DIR/layouts/multi.kdl" "$FLAVOR_KDL" | head -5)"
grep -q 'bin/mdev pane' "$FLAVOR_KDL" \
  && fail "no FLAVOR yet the layout points at bin/mdev" || pass "no FLAVOR: layout has no bin/mdev"

# (a2) 知らない値: 警告を出したうえで Shell 版として扱う（黙って倒さない）
flavor_reset
mkdir -p "$FLAVOR_CH"
printf 'rust\n' > "$FLAVOR_CH/FLAVOR"
flavor_stub_mdev
if FLAVOR_OUT=$(flavor_install); then FLAVOR_RC=0; else FLAVOR_RC=$?; fi
[[ "$FLAVOR_RC" -eq 0 ]] && pass "unknown flavor still installs" || fail "unknown flavor install exited $FLAVOR_RC"
echo "$FLAVOR_OUT" | grep -q "unknown flavor 'rust'" \
  && pass "unknown flavor is reported" || fail "unknown flavor went unreported"
cmp -s "$REPO_DIR/layouts/multi.kdl" "$FLAVOR_KDL" \
  && pass "unknown flavor keeps the shell layout" || fail "unknown flavor changed the layout"
[[ ! -f "$FLAVOR_MDEV_LOG" ]] \
  && pass "unknown flavor does not call mdev" || fail "mdev called for an unknown flavor"

# (b) FLAVOR=go + bin/mdev あり: 5 ペインすべてが bin/mdev pane 形式（前後空白は許容）
flavor_reset
mkdir -p "$FLAVOR_CH"
printf '  go  \n' > "$FLAVOR_CH/FLAVOR"
flavor_stub_mdev
flavor_install >/dev/null 2>&1 || fail "install.sh (FLAVOR=go) exited non-zero"

FLAVOR_PANES=$(grep -c 'bin/mdev pane' "$FLAVOR_KDL" 2>/dev/null | tr -d ' ' || true)
[[ "$FLAVOR_PANES" == "5" ]] \
  && pass "FLAVOR=go rewrites all 5 panes to bin/mdev pane" \
  || fail "FLAVOR=go rewrote $FLAVOR_PANES panes (want 5)"
for FLAVOR_PANE in dashboard waiting done news task-create; do
    grep -qF "/bin/mdev pane $FLAVOR_PANE\"" "$FLAVOR_KDL" \
      && pass "pane $FLAVOR_PANE points at bin/mdev" \
      || fail "pane $FLAVOR_PANE not switched to bin/mdev"
done
grep -q -- '-loop\.sh' "$FLAVOR_KDL" \
  && fail "shell loop scripts remain in the go layout" || pass "no *-loop.sh left in the go layout"
FLAVOR_PREFIXED=$(grep -cF '"${CONDUCTOR_HOME:-$HOME/.claude-conductor}/bin/mdev pane ' "$FLAVOR_KDL" 2>/dev/null | tr -d ' ' || true)
[[ "$FLAVOR_PREFIXED" == "5" ]] \
  && pass "CONDUCTOR_HOME prefix preserved on all 5 panes" \
  || fail "CONDUCTOR_HOME prefix kept on only $FLAVOR_PREFIXED panes"
FLAVOR_BRACE_OPEN=$(tr -cd '{' < "$FLAVOR_KDL" | wc -c | tr -d ' ')
FLAVOR_BRACE_CLOSE=$(tr -cd '}' < "$FLAVOR_KDL" | wc -c | tr -d ' ')
[[ "$FLAVOR_BRACE_OPEN" == "$FLAVOR_BRACE_CLOSE" ]] \
  && pass "go layout braces balanced" \
  || fail "go layout braces unbalanced: $FLAVOR_BRACE_OPEN open / $FLAVOR_BRACE_CLOSE close"
[[ ! -f "$FLAVOR_CH/layouts/multi.kdl.tmp" ]] \
  && pass "no multi.kdl.tmp left behind" || fail "multi.kdl.tmp left behind"

# (e) hooks switch: install.sh は bin/mdev に切り替えを委ねる（重複実装しない）
grep -q '^hooks switch$' "$FLAVOR_MDEV_LOG" \
  && pass "install.sh calls 'mdev hooks switch'" \
  || fail "mdev hooks switch not called: $(cat "$FLAVOR_MDEV_LOG" 2>/dev/null)"

# bin/ は install.sh の管理外。上書きも削除もされない。
[[ -x "$FLAVOR_CH/bin/mdev" ]] && pass "install.sh leaves bin/mdev untouched" || fail "bin/mdev lost on install"
[[ -f "$FLAVOR_CH/FLAVOR" ]] && pass "FLAVOR file survives install" || fail "FLAVOR file lost on install"

# (d) 再実行しても同じ結果（冪等）
cp "$FLAVOR_KDL" "$SANDBOX/flavor-multi.first"
: > "$FLAVOR_MDEV_LOG"
flavor_install >/dev/null 2>&1 || fail "install.sh (FLAVOR=go, reinstall) exited non-zero"
cmp -s "$SANDBOX/flavor-multi.first" "$FLAVOR_KDL" \
  && pass "reinstall reproduces the same go layout (idempotent)" \
  || fail "reinstall changed the go layout: $(diff "$SANDBOX/flavor-multi.first" "$FLAVOR_KDL" | head -5)"
grep -q '^hooks switch$' "$FLAVOR_MDEV_LOG" \
  && pass "reinstall calls 'mdev hooks switch' again" || fail "reinstall skipped mdev hooks switch"

# (c) FLAVOR=go だが bin/mdev が無い: layouts も hooks も Shell 版のまま。
# レイアウトだけ Go 化すると 5 ペインすべてが即死するので、混ぜない。
flavor_reset
mkdir -p "$FLAVOR_CH"
printf 'go\n' > "$FLAVOR_CH/FLAVOR"
if FLAVOR_OUT=$(flavor_install); then FLAVOR_RC=0; else FLAVOR_RC=$?; fi
[[ "$FLAVOR_RC" -eq 0 ]] \
  && pass "install succeeds when FLAVOR=go but bin/mdev is missing" \
  || fail "install exited $FLAVOR_RC without bin/mdev"
echo "$FLAVOR_OUT" | grep -q 'Layouts and hooks stay on the shell flavor' \
  && pass "warns that layouts and hooks stay on the shell flavor" \
  || fail "no warning about the missing bin/mdev"
cmp -s "$REPO_DIR/layouts/multi.kdl" "$FLAVOR_KDL" \
  && pass "missing bin/mdev keeps the shell layout" \
  || fail "layout switched to bin/mdev without the binary"
flavor_hook_commands | grep -q 'scripts/pending-notify\.sh' \
  && pass "hooks stay on the shell flavor without bin/mdev" \
  || fail "shell hooks missing: $(flavor_hook_commands | tr '\n' ' ')"

# (f) settings.json が無い新規インストールでも Go 版 hooks が作られる。
# `mdev hooks switch` は既存コマンドの末尾を書き換えるだけで hooks を新規に
# 作りはしないため、Go 版でも conductor 側のマージ自体は残す必要がある。
flavor_reset
rm -f "$FLAVOR_SETTINGS"
mkdir -p "$FLAVOR_CH"
printf 'go\n' > "$FLAVOR_CH/FLAVOR"
flavor_stub_mdev_switch
flavor_install >/dev/null 2>&1 || fail "install.sh (fresh, FLAVOR=go) exited non-zero"

[[ -f "$FLAVOR_SETTINGS" ]] && pass "fresh install creates settings.json" || fail "settings.json not created"
FLAVOR_CMDS=$(flavor_hook_commands)
FLAVOR_MISSING=""
for FLAVOR_HOOK in "/bin/mdev hook notify" "/bin/mdev hook post-tool" "/bin/mdev hook resolve"; do
    echo "$FLAVOR_CMDS" | grep -qF "$FLAVOR_HOOK" || FLAVOR_MISSING="$FLAVOR_MISSING $FLAVOR_HOOK"
done
[[ -z "$FLAVOR_MISSING" ]] \
  && pass "fresh go install ends up with the go hooks" \
  || fail "go hooks missing:$FLAVOR_MISSING"
echo "$FLAVOR_CMDS" | grep -q 'scripts/pending-' \
  && fail "shell pending hooks remain after the switch" || pass "no shell pending hooks remain"

# 再実行で settings.json のバックアップが増えない（Shell 版へ戻して毎回
# 切り替え直すと install / update のたびにバックアップが積み上がる）
FLAVOR_BK1=$(flavor_backup_count)
[[ "$FLAVOR_BK1" == "1" ]] \
  && pass "first go install backs settings.json up once" \
  || fail "unexpected backup count after the first install: $FLAVOR_BK1"
FLAVOR_HOOKS_BEFORE=$(jq -S '.hooks' "$FLAVOR_SETTINGS")
flavor_install >/dev/null 2>&1 || fail "install.sh (fresh reinstall, FLAVOR=go) exited non-zero"
[[ "$(flavor_backup_count)" == "$FLAVOR_BK1" ]] \
  && pass "reinstall adds no new settings.json backup" \
  || fail "backups piled up: $FLAVOR_BK1 -> $(flavor_backup_count)"
[[ "$(jq -S '.hooks' "$FLAVOR_SETTINGS")" == "$FLAVOR_HOOKS_BEFORE" ]] \
  && pass "reinstall leaves the go hooks untouched" \
  || fail "reinstall rewrote the hooks"

# 他ツールの hooks と hooks 以外の設定はマージで壊さない
jq '.permissions = {"allow": ["Bash"]} | .hooks.PreToolUse = [{"matcher": "", "hooks": [{"type": "command", "command": "echo pre"}]}]' \
    "$FLAVOR_SETTINGS" > "$FLAVOR_SETTINGS.seed" && mv "$FLAVOR_SETTINGS.seed" "$FLAVOR_SETTINGS"
flavor_install >/dev/null 2>&1 || fail "install.sh (seeded reinstall, FLAVOR=go) exited non-zero"
[[ "$(jq -r '.permissions.allow[0]' "$FLAVOR_SETTINGS")" == "Bash" ]] \
  && pass "go merge preserves non-hook settings" || fail "permissions lost by the go merge"
flavor_hook_commands | grep -qF 'echo pre' \
  && pass "go merge preserves foreign hooks" || fail "foreign PreToolUse hook lost"
[[ "$(flavor_backup_count)" == "$FLAVOR_BK1" ]] \
  && pass "seeded reinstall adds no new backup" || fail "backups piled up on the seeded reinstall"

# uninstall は $CONDUCTOR_HOME ごと消すので Go 版のバイナリとフラグも道連れになる。
# その旨は Go 版が実在するときだけ表示する（Shell 版だけの環境では出さない）。
# config.toml が conductor の notify 行だけの環境（codex 導入済みの実機で
# よく起きる）でも最後まで走り切ることを、ここで併せて確かめる。
printf 'notify = ["bash", "%s/scripts/codex-notify.sh"] # claude-conductor\n' "$FLAVOR_CH" \
    > "$FLAVOR_HOME/.codex/config.toml"
FLAVOR_UNINST_OUT=$(HOME="$FLAVOR_HOME" CODEX_HOME="$FLAVOR_HOME/.codex" bash "$REPO_DIR/uninstall.sh" 2>&1 || true)
[[ ! -d "$FLAVOR_CH" ]] \
  && pass "uninstall removes the conductor home even with a conductor-only codex config" \
  || fail "uninstall left $FLAVOR_CH behind"
echo "$FLAVOR_UNINST_OUT" | grep -qF 'bin/mdev (Go flavor)' \
  && pass "uninstall announces the go flavor binary" || fail "uninstall silent about bin/mdev"
echo "$FLAVOR_UNINST_OUT" | grep -qF '(including bin/ and FLAVOR)' \
  && pass "uninstall notes bin/ and FLAVOR go too" || fail "uninstall omits the bin/FLAVOR note"

flavor_reset
mkdir -p "$FLAVOR_CH/scripts"
FLAVOR_UNINST_OUT=$(HOME="$FLAVOR_HOME" bash "$REPO_DIR/uninstall.sh" 2>&1 || true)
echo "$FLAVOR_UNINST_OUT" | grep -qF '(including bin/ and FLAVOR)' \
  && fail "uninstall mentions bin/FLAVOR on a shell-only install" \
  || pass "uninstall stays quiet about bin/FLAVOR on a shell-only install"

rm -rf "$FLAVOR_HOME" "$SANDBOX/flavor-multi.first"

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

PAGENT=$(jq -r '.agent' "$PENDING_DIR/sess-aaa.json")
[[ "$PAGENT" == "claude" ]] && pass "agent defaults to claude" || fail "agent wrong: $PAGENT"

# TASK_AGENT env (named-agent tabs) is recorded as-is
echo '{"session_id":"sess-agent","message":"x","hook_event_name":"Notification","cwd":"/tmp/myapp"}' \
  | ZELLIJ_SESSION_NAME=test-session TASK_TAB_NAME=api-feature TASK_TYPE=dev TASK_AGENT=myclaude \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"
PAGENT=$(jq -r '.agent' "$PENDING_DIR/sess-agent.json")
[[ "$PAGENT" == "myclaude" ]] && pass "agent recorded from TASK_AGENT" || fail "TASK_AGENT not recorded: $PAGENT"
rm -f "$PENDING_DIR/sess-agent.json"

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
section "11b. codex-notify.sh (agent-turn-complete -> pending Stop)"
# ============================================================

CODEX_NOTIFY="$HOME/.claude-conductor/scripts/codex-notify.sh"
CODEX_PENDING="$HOME/.claude-pending/codex-session"
[[ -f "$CODEX_NOTIFY" ]] && pass "codex-notify.sh installed" || fail "codex-notify.sh missing"

# A fake CODEX_HOME provides the rollout transcript for the thread
FAKE_CODEX_HOME="$SANDBOX/fake-codex"
mkdir -p "$FAKE_CODEX_HOME/sessions/2026/08/07"
ROLLOUT="$FAKE_CODEX_HOME/sessions/2026/08/07/rollout-2026-08-07T10-00-00-thread-0001.jsonl"
echo '{}' > "$ROLLOUT"

PAYLOAD='{"type":"agent-turn-complete","thread-id":"thread-0001","turn-id":"t1","cwd":"/tmp/myapp","input-messages":["do it"],"last-assistant-message":"All done here"}'
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME=codex-task TASK_TYPE=dev TASK_AGENT=codex CODEX_HOME="$FAKE_CODEX_HOME" \
    bash "$CODEX_NOTIFY" "$PAYLOAD"

CODEX_PENDING_FILE="$CODEX_PENDING/thread-0001.json"
[[ -f "$CODEX_PENDING_FILE" ]] && pass "pending file keyed by thread-id" || fail "pending file missing"
[[ "$(jq -r '.event' "$CODEX_PENDING_FILE")" == "Stop" ]] && pass "event recorded as Stop" || fail "event wrong"
[[ "$(jq -r '.agent' "$CODEX_PENDING_FILE")" == "codex" ]] && pass "agent recorded as codex" || fail "agent wrong"
[[ "$(jq -r '.tab' "$CODEX_PENDING_FILE")" == "codex-task" ]] && pass "tab from TASK_TAB_NAME" || fail "tab wrong"
[[ "$(jq -r '.message' "$CODEX_PENDING_FILE")" == "All done here" ]] && pass "message from last-assistant-message" || fail "message wrong"
[[ "$(jq -r '.dir' "$CODEX_PENDING_FILE")" == "/tmp/myapp" ]] && pass "dir from payload cwd" || fail "dir wrong"
[[ "$(jq -r '.task_type' "$CODEX_PENDING_FILE")" == "dev" ]] && pass "task_type from env" || fail "task_type wrong"
[[ "$(jq -r '.claude_session_id' "$CODEX_PENDING_FILE")" == "thread-0001" ]] && pass "session id kept in claude_session_id" || fail "claude_session_id wrong"
[[ "$(jq -r '.transcript_path' "$CODEX_PENDING_FILE")" == "$ROLLOUT" ]] && pass "transcript resolved from CODEX_HOME sessions" || fail "transcript_path wrong: $(jq -r '.transcript_path' "$CODEX_PENDING_FILE")"

# The payload arrives as the LAST argument (notify argv may carry extras first)
rm -f "$CODEX_PENDING_FILE"
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME=codex-task CODEX_HOME="$FAKE_CODEX_HOME" \
    bash "$CODEX_NOTIFY" "ignored-extra-arg" "$PAYLOAD"
[[ -f "$CODEX_PENDING_FILE" ]] && pass "payload read from last argument" || fail "last-argument payload not handled"

# Other event types are ignored
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME=codex-task CODEX_HOME="$FAKE_CODEX_HOME" \
    bash "$CODEX_NOTIFY" '{"type":"something-else","thread-id":"thread-0002"}'
[[ ! -f "$CODEX_PENDING/thread-0002.json" ]] && pass "non-turn-complete event ignored" || fail "unexpected pending for other event"

# Missing thread-id is a no-op
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME=codex-task CODEX_HOME="$FAKE_CODEX_HOME" \
    bash "$CODEX_NOTIFY" '{"type":"agent-turn-complete"}'
CODEX_FILES=$(ls "$CODEX_PENDING" | wc -l | tr -d ' ')
[[ "$CODEX_FILES" -eq 1 ]] && pass "no file without thread-id" || fail "unexpected files: $CODEX_FILES"

# A Waiting entry is not clobbered by a later turn-complete
jq '.event = "Waiting"' "$CODEX_PENDING_FILE" > "$CODEX_PENDING_FILE.tmp" && mv "$CODEX_PENDING_FILE.tmp" "$CODEX_PENDING_FILE"
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME=codex-task CODEX_HOME="$FAKE_CODEX_HOME" \
    bash "$CODEX_NOTIFY" "$PAYLOAD"
[[ "$(jq -r '.event' "$CODEX_PENDING_FILE")" == "Waiting" ]] && pass "Waiting preserved on turn-complete" || fail "Waiting clobbered"

# Missing tab name falls back to the payload cwd basename
rm -rf "$CODEX_PENDING"
ZELLIJ_SESSION_NAME=codex-session TASK_TAB_NAME= TASK_TYPE= CODEX_HOME="$FAKE_CODEX_HOME" bash "$CODEX_NOTIFY" "$PAYLOAD"
[[ "$(jq -r '.tab' "$CODEX_PENDING_FILE")" == "myapp" ]] && pass "tab falls back to cwd basename" || fail "tab fallback wrong"
rm -rf "$CODEX_PENDING" "$FAKE_CODEX_HOME"

# ============================================================
section "11c. registry-lib.sh (task registry upsert/remove)"
# ============================================================

REG_LIB="$HOME/.claude-conductor/scripts/registry-lib.sh"
[[ -f "$REG_LIB" ]] && pass "registry-lib.sh installed" || fail "registry-lib.sh missing"

# upsert が全フィールド入りのJSONエントリを作成する
if source "$REG_LIB" 2>/dev/null; then
    pass "registry-lib.sh sourced (functions only)"
else
    fail "registry-lib.sh failed to source"
fi
registry_upsert "reg-sess" "sid-1" "tab-one" "/tmp/dir1" "dev" "claude" "/tmp/t1.jsonl" 2>/dev/null || true
REG_FILE="$CONDUCTOR_HOME/tasks/reg-sess/sid-1.json"
[[ -f "$REG_FILE" ]] && pass "upsert creates registry entry" || fail "no registry entry created"
[[ "$(jq -r '.tab' "$REG_FILE" 2>/dev/null)" == "tab-one" ]] && pass "entry records tab" || fail "wrong tab: $(cat "$REG_FILE" 2>/dev/null)"
[[ "$(jq -r '.dir' "$REG_FILE" 2>/dev/null)" == "/tmp/dir1" ]] && pass "entry records dir" || fail "wrong dir"
[[ "$(jq -r '.task_type' "$REG_FILE" 2>/dev/null)" == "dev" ]] && pass "entry records task_type" || fail "wrong task_type"
[[ "$(jq -r '.agent' "$REG_FILE" 2>/dev/null)" == "claude" ]] && pass "entry records agent" || fail "wrong agent"
[[ "$(jq -r '.transcript_path' "$REG_FILE" 2>/dev/null)" == "/tmp/t1.jsonl" ]] && pass "entry records transcript_path" || fail "wrong transcript_path"

# 同じsidへのupsertは上書き（タブ名変更が反映される）
registry_upsert "reg-sess" "sid-1" "tab-renamed" "/tmp/dir1" "dev" "claude" "/tmp/t1.jsonl" 2>/dev/null || true
[[ "$(jq -r '.tab' "$REG_FILE" 2>/dev/null)" == "tab-renamed" ]] && pass "upsert overwrites existing entry" || fail "entry not updated"

# セッションごとにディレクトリが分離される
registry_upsert "reg-other" "sid-1" "other-tab" "/tmp/dir2" "" "" "" 2>/dev/null || true
[[ -f "$CONDUCTOR_HOME/tasks/reg-other/sid-1.json" ]] && pass "sessions get separate registry dirs" || fail "no per-session dir"
[[ "$(jq -r '.tab' "$REG_FILE" 2>/dev/null)" == "tab-renamed" ]] && pass "other session upsert does not touch first entry" || fail "cross-session clobber"

# 空フィールドはキー自体が省略される（restore側の // empty 判定を単純に保つ）
[[ "$(jq -r 'has("task_type")' "$CONDUCTOR_HOME/tasks/reg-other/sid-1.json" 2>/dev/null)" == "false" ]] \
  && pass "empty optional fields omitted" || fail "empty field not omitted"

# session/sid が無い呼び出しはno-op
registry_upsert "" "no-sess" "t" "" "" "" "" 2>/dev/null || true
registry_upsert "reg-sess" "" "t" "" "" "" "" 2>/dev/null || true
[[ ! -f "$CONDUCTOR_HOME/tasks/no-sess.json" ]] && pass "upsert without session is a no-op" || fail "created entry without session"

# remove は該当エントリのみ削除
registry_remove "reg-sess" "sid-1" 2>/dev/null || true
[[ ! -f "$REG_FILE" ]] && pass "remove deletes the entry" || fail "entry not removed"
[[ -f "$CONDUCTOR_HOME/tasks/reg-other/sid-1.json" ]] && pass "remove leaves other sessions intact" || fail "other session entry removed"

# remove_by_tab はタブ名一致の全エントリを削除（pendingが無い削除経路用）
registry_upsert "reg-sess" "sid-2" "tab-x" "/tmp/d" "" "" "" 2>/dev/null || true
registry_upsert "reg-sess" "sid-3" "tab-x" "/tmp/d" "" "" "" 2>/dev/null || true
registry_upsert "reg-sess" "sid-4" "tab-keep" "/tmp/d" "" "" "" 2>/dev/null || true
registry_remove_by_tab "reg-sess" "tab-x" 2>/dev/null || true
[[ ! -f "$CONDUCTOR_HOME/tasks/reg-sess/sid-2.json" && ! -f "$CONDUCTOR_HOME/tasks/reg-sess/sid-3.json" ]] \
  && pass "remove_by_tab deletes all matching entries" || fail "tab entries not removed"
[[ -f "$CONDUCTOR_HOME/tasks/reg-sess/sid-4.json" ]] && pass "remove_by_tab keeps other tabs" || fail "unrelated entry removed"

# 後続セクションを汚さないよう掃除
rm -rf "$CONDUCTOR_HOME/tasks"

# ============================================================
section "11d. hooks upsert the task registry"
# ============================================================

# pending-notify.sh (Notification) がレジストリへupsertする
echo '{"session_id":"reg-hook-1","message":"Approval needed","hook_event_name":"Notification","transcript_path":"/tmp/reg-t1.jsonl","cwd":"/tmp/reg-dir1"}' \
  | ZELLIJ_SESSION_NAME=reg-hooks TASK_TAB_NAME=reg-tab TASK_TYPE=dev TASK_AGENT=claude \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"
RH_FILE="$CONDUCTOR_HOME/tasks/reg-hooks/reg-hook-1.json"
[[ -f "$RH_FILE" ]] && pass "pending-notify upserts registry entry" || fail "no registry entry from pending-notify"
[[ "$(jq -r '.tab' "$RH_FILE" 2>/dev/null)" == "reg-tab" ]] && pass "registry entry has tab" || fail "wrong tab: $(cat "$RH_FILE" 2>/dev/null)"
[[ "$(jq -r '.dir' "$RH_FILE" 2>/dev/null)" == "/tmp/reg-dir1" ]] && pass "registry entry has dir" || fail "wrong dir"
[[ "$(jq -r '.agent' "$RH_FILE" 2>/dev/null)" == "claude" ]] && pass "registry entry has agent" || fail "wrong agent"

# 応答後もタスクは生きている: pending-resolve.sh はpendingを消しつつレジストリはupsertする
echo '{"session_id":"reg-hook-1","transcript_path":"/tmp/reg-t1b.jsonl","cwd":"/tmp/reg-dir1"}' \
  | ZELLIJ_SESSION_NAME=reg-hooks TASK_TAB_NAME=reg-tab TASK_TYPE=dev TASK_AGENT=claude \
    bash "$HOME/.claude-conductor/scripts/pending-resolve.sh"
[[ -f "$RH_FILE" ]] && pass "pending-resolve keeps registry entry" || fail "registry entry lost on resolve"
[[ "$(jq -r '.transcript_path' "$RH_FILE" 2>/dev/null)" == "/tmp/reg-t1b.jsonl" ]] \
  && pass "pending-resolve refreshes transcript_path" || fail "transcript not refreshed: $(cat "$RH_FILE" 2>/dev/null)"

# codex-notify.sh もthread-idでレジストリへupsertする
REG_CODEX_HOME="$SANDBOX/reg-codex-home"
mkdir -p "$REG_CODEX_HOME/sessions"
echo '{"x":1}' > "$REG_CODEX_HOME/sessions/rollout-reg-thread-9.jsonl"
ZELLIJ_SESSION_NAME=reg-hooks TASK_TAB_NAME=reg-codex-tab TASK_TYPE=review CODEX_HOME="$REG_CODEX_HOME" \
    bash "$HOME/.claude-conductor/scripts/codex-notify.sh" \
    '{"type":"agent-turn-complete","thread-id":"reg-thread-9","cwd":"/tmp/reg-dir2","last-assistant-message":"done"}'
RC_FILE="$CONDUCTOR_HOME/tasks/reg-hooks/reg-thread-9.json"
[[ -f "$RC_FILE" ]] && pass "codex-notify upserts registry entry" || fail "no registry entry from codex-notify"
[[ "$(jq -r '.agent' "$RC_FILE" 2>/dev/null)" == "codex" ]] && pass "codex entry has agent codex" || fail "wrong agent: $(cat "$RC_FILE" 2>/dev/null)"
[[ "$(jq -r '.transcript_path' "$RC_FILE" 2>/dev/null)" == "$REG_CODEX_HOME/sessions/rollout-reg-thread-9.jsonl" ]] \
  && pass "codex entry has rollout transcript" || fail "wrong transcript"

# TASK_TAB_NAME が無い（conductor外のセッション）は登録しない
echo '{"session_id":"reg-outside","message":"m","hook_event_name":"Stop","cwd":"/tmp/elsewhere"}' \
  | ZELLIJ_SESSION_NAME=reg-hooks TASK_TAB_NAME= \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"
[[ ! -f "$CONDUCTOR_HOME/tasks/reg-hooks/reg-outside.json" ]] \
  && pass "non-conductor session not registered (no TASK_TAB_NAME)" || fail "registered outside task tab"

# ZELLIJ_SESSION_NAME が無い場合も登録しない
echo '{"session_id":"reg-nozellij","message":"m","hook_event_name":"Stop","cwd":"/tmp/x"}' \
  | ZELLIJ_SESSION_NAME= TASK_TAB_NAME=some-tab \
    bash "$HOME/.claude-conductor/scripts/pending-notify.sh"
[[ ! -d "$CONDUCTOR_HOME/tasks/unknown" ]] \
  && pass "no registry outside zellij" || fail "registered under unknown session"

# pendingファイル側の既存挙動が保たれている（レジストリ追加による回帰なし）
[[ -f "$HOME/.claude-pending/reg-hooks/reg-thread-9.json" ]] \
  && pass "codex pending file still written" || fail "codex pending regression"

# 後続セクションを汚さないよう掃除
rm -rf "$CONDUCTOR_HOME/tasks" "$HOME/.claude-pending/reg-hooks"

# ============================================================
section "12. config.default.json installed"
# ============================================================

[[ -f "$HOME/.claude-conductor/config.default.json" ]] && pass "config.default.json installed" || fail "config.default.json missing"

# Validate JSON
jq '.' "$HOME/.claude-conductor/config.default.json" > /dev/null 2>&1 && pass "config.default.json is valid JSON" || fail "config.default.json is invalid JSON"

# update_check.enabled defaults to true (drives the startup update notice)
[[ "$(jq -r '.update_check.enabled' "$HOME/.claude-conductor/config.default.json")" == "true" ]] \
    && pass "update_check.enabled defaults to true" || fail "update_check.enabled default missing/wrong"

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

# 後から追加されたagentキー（detection / patterns, issue #28）は再インストールで
# 既存configへ補完される。ユーザー設定値は上書きしない
jq 'del(.agents.codex.detection) | del(.agents.codex.patterns)
    | .agents.codex.command = "my-codex"
    | .agents.claude.detection = "screen"' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null
[[ "$(jq -r '.agents.codex.detection' "$HOME/.claude-conductor/config.json")" == "screen" ]] \
  && pass "missing detection filled from defaults on reinstall" || fail "detection not migrated"
jq -e '(.agents.codex.patterns.blocked | length) >= 1' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "missing patterns filled from defaults on reinstall" || fail "patterns not migrated"
[[ "$(jq -r '.agents.codex.command' "$HOME/.claude-conductor/config.json")" == "my-codex" ]] \
  && pass "user agent command preserved by migration" || fail "user command overwritten"
[[ "$(jq -r '.agents.claude.detection' "$HOME/.claude-conductor/config.json")" == "screen" ]] \
  && pass "user-set detection not overwritten by migration" || fail "user detection overwritten"

# patterns はキー単位で補完する。後から追加された neutral は、blocked/working を
# カスタムしている既存configにも届かないと検出ルールの更新が永久に届かない
jq '.agents.codex.patterns = {"blocked": ["^ *MY OWN APPROVAL"], "working": ["my-spinner"]}' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null
jq -e '.agents.codex.patterns | has("neutral")' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "new pattern key filled into customized patterns" || fail "neutral key not migrated"
[[ "$(jq -r '.agents.codex.patterns.blocked[0]' "$HOME/.claude-conductor/config.json")" == "^ *MY OWN APPROVAL" ]] \
  && pass "user blocked patterns preserved by key merge" || fail "user blocked patterns overwritten"
[[ "$(jq -r '.agents.codex.patterns.working[0]' "$HOME/.claude-conductor/config.json")" == "my-spinner" ]] \
  && pass "user working patterns preserved by key merge" || fail "user working patterns overwritten"

# patterns を空オブジェクトにして検出を止めているユーザーの意図は壊さない
# （キー単位マージで全パターンが復活すると、検出が黙って再有効化される）
jq '.agents.codex.patterns = {}' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null >/dev/null
jq -e '(.agents.codex.patterns | length) == 0' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "emptied patterns stay empty" || fail "emptied patterns refilled from defaults"

# patterns がオブジェクト以外でもjqを落とさない（型が違うものを足そうとすると
# jqはエラーで終了し、マージ全体が無言でスキップされていた）
jq '.agents.codex.patterns = []' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null >/dev/null
jq -e '(.agents.codex.patterns | type) == "array"' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "non-object patterns survive the merge" || fail "patterns of unexpected type mangled"
jq -e '.agents.codex.detection == "screen"' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "merge still runs for other keys" || fail "merge aborted by non-object patterns"

# config.json自体が壊れている場合はjqが失敗する。無言でスキップせず警告を出し、
# 既存のファイルには手を触れない
cp "$HOME/.claude-conductor/config.json" "$SANDBOX/config.json.bak"
printf '{ "agents": ' > "$HOME/.claude-conductor/config.json"
INSTALL_OUT=$(echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null)
echo "$INSTALL_OUT" | grep -q "config.json のマージをスキップ" \
  && pass "unmergeable config.json warns" || fail "merge failure was silent"
[[ "$(cat "$HOME/.claude-conductor/config.json")" == '{ "agents": ' ]] \
  && pass "broken config.json left intact" || fail "broken config.json was rewritten"
[[ ! -f "$HOME/.claude-conductor/config.json.tmp" ]] \
  && pass "failed merge leaves no tmp file" || fail "config.json.tmp left behind"
cp "$SANDBOX/config.json.bak" "$HOME/.claude-conductor/config.json"
CUSTOM_TYPE=$(jq -r '.task_types.custom.description' "$HOME/.claude-conductor/config.json")
[[ "$CUSTOM_TYPE" == "Custom task" ]] && pass "custom task type survives migration" || fail "custom type lost in migration"

# agents未定義のレガシーconfigは変更されない（agentsキーを生やさない）
jq 'del(.agents)' "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"
echo "n" | bash "$REPO_DIR/install.sh" 2>/dev/null
jq -e 'has("agents") | not' "$HOME/.claude-conductor/config.json" >/dev/null \
  && pass "legacy config without agents untouched" || fail "agents key injected into legacy config"

# 以降のセクションが期待するagent定義を復元（custom task typeは維持）
jq --slurpfile DEF "$HOME/.claude-conductor/config.default.json" '.agents = $DEF[0].agents' \
  "$HOME/.claude-conductor/config.json" > "$HOME/.claude-conductor/config.json.tmp"
mv "$HOME/.claude-conductor/config.json.tmp" "$HOME/.claude-conductor/config.json"

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
section "15b. task-create-loop.sh agent selection (select_agent)"
# ============================================================

CONDUCTOR_CFG="$HOME/.claude-conductor/config.json"
TASK_CREATE="$HOME/.claude-conductor/scripts/task-create-loop.sh"

# select_agent is defined when the script is sourced (main_loop must not start)
( source "$TASK_CREATE" && declare -F select_agent >/dev/null ) \
  && pass "task-create-loop.sh defines select_agent" || fail "select_agent missing"

# No .agents configured -> empty output (legacy single-agent path)
jq 'del(.agents)' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
SA=$( source "$TASK_CREATE" && select_agent )
[[ -z "$SA" ]] && pass "select_agent empty without .agents" || fail "select_agent = '$SA' without .agents"

# A single configured agent is returned without prompting
jq '.agents = {"claude": {"command": "claude", "resume_args": "--resume"}}' \
    "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
SA=$( source "$TASK_CREATE" && select_agent )
[[ "$SA" == "claude" ]] && pass "select_agent auto-picks single agent" || fail "select_agent single = '$SA'"

# Multiple agents go through fzf with all candidates offered
cat > "$MOCK_BIN/fzf" << 'MOCK'
#!/bin/bash
tee "$HOME/.claude-pending/fzf-input.log" | head -1
MOCK
chmod +x "$MOCK_BIN/fzf"
jq '.agents = {"claude": {"command": "claude", "resume_args": "--resume"}, "codex": {"command": "codex", "resume_args": "resume"}}' \
    "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
SA=$( source "$TASK_CREATE" && select_agent )
[[ "$SA" == "claude" ]] && pass "select_agent returns fzf pick" || fail "select_agent fzf = '$SA'"
grep -q "codex" "$HOME/.claude-pending/fzf-input.log" \
  && pass "select_agent offers all agents to fzf" || fail "fzf candidates missing codex"
rm -f "$MOCK_BIN/fzf" "$HOME/.claude-pending/fzf-input.log"

# Restore the default config for subsequent tests
cp "$HOME/.claude-conductor/config.default.json" "$CONDUCTOR_CFG"

# ============================================================
section "16. layout actions generate correct zellij commands"
# ============================================================

# Clear zellij call log
: > "$HOME/.claude-pending/zellij-calls.log"

# Test dev layout (new-pane right nvim, new-pane down lazygit, move-focus left)
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
grep -q 'action new-pane --direction down --cwd /tmp -- lazygit' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "dev layout: new-pane down lazygit" || fail "dev layout: missing lazygit pane"
grep -q 'action move-focus left' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "dev layout: move-focus left" || fail "dev layout: missing move-focus left"

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

# zellij 0.44.1はサーバ劣化時にnew-tabの「暗黙のフォーカス切替」だけを
# 遅延・喪失させる（明示的なgo-to-tab-nameは効く）。create_taskは暗黙
# フォーカスに依存せず、タブ登録を確認してから明示フォーカスを発行する。
mock_zellij_reset
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "focus-me" ) >/dev/null 2>&1
CALLS_SEQ=$(grep -n 'action \(new-tab -n focus-me\|query-tab-names\|go-to-tab-name focus-me\|new-pane\)' \
    "$HOME/.claude-pending/zellij-calls.log" | cut -d: -f2- | sed 's/^mock-zellij: action //' | awk '{print $1}')
[[ "$(printf '%s\n' "$CALLS_SEQ" | head -3 | tr '\n' ' ')" == "new-tab query-tab-names go-to-tab-name " ]] \
  && pass "create_task focuses the new tab after confirming registration" \
  || fail "wrong call order after new-tab: '$(printf '%s' "$CALLS_SEQ" | tr '\n' ' ')'"

# 復元経路（--resume付き）でも同じく明示フォーカスが入る
mock_zellij_reset
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "focus-resume" "sess-xyz" ) >/dev/null 2>&1
CALLS_SEQ=$(grep -n 'action \(new-tab -n focus-resume\|query-tab-names\|go-to-tab-name focus-resume\|new-pane\)' \
    "$HOME/.claude-pending/zellij-calls.log" | cut -d: -f2- | sed 's/^mock-zellij: action //' | awk '{print $1}')
[[ "$(printf '%s\n' "$CALLS_SEQ" | head -3 | tr '\n' ' ')" == "new-tab query-tab-names go-to-tab-name " ]] \
  && pass "create_task focuses the resumed tab after confirming registration" \
  || fail "wrong call order after resume new-tab: '$(printf '%s' "$CALLS_SEQ" | tr '\n' ' ')'"

# new-tab自体が失敗したら非0で返る（restoreがこの戻り値に依存する）。
# 明示フォーカスの追加でタブ作成の成否判定が上書きされないこと。
FAIL_BIN="$SANDBOX/fail-bin"
mkdir -p "$FAIL_BIN"
cat > "$FAIL_BIN/zellij" << 'FAILMOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
if [[ "$1" == "action" && "$2" == "new-tab" ]]; then exit 1; fi
exit 0
FAILMOCK
chmod +x "$FAIL_BIN/zellij"
: > "$HOME/.claude-pending/zellij-calls.log"
CT_RC=0
( PATH="$FAIL_BIN:$PATH"; source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "failed-tab" ) >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -ne 0 ]] && pass "create_task returns non-zero when new-tab fails" \
  || fail "create_task returned 0 despite new-tab failure"
grep -q 'action go-to-tab-name failed-tab' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "focused a tab that was never created" || pass "no focus attempt when new-tab fails"
rm -rf "$FAIL_BIN"

# ============================================================
section "17b2. configurable agent command (.agent.command)"
# ============================================================

CONDUCTOR_CFG="$HOME/.claude-conductor/config.json"

# A custom agent command replaces claude in new tabs
jq '.agent = {"command": "codex", "resume_args": "resume"}' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "codex-task" ) >/dev/null 2>&1
grep -q 'action new-tab -n codex-task --cwd /tmp/proj -- env TASK_TAB_NAME=codex-task TASK_TYPE=dev codex' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task honors .agent.command" || fail "create_task ignored .agent.command"

# Custom resume_args are inserted before the session id
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "codex-resume" "sess-abc" ) >/dev/null 2>&1
grep -q 'TASK_TYPE=dev codex resume sess-abc' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task honors .agent.resume_args" || fail "create_task ignored .agent.resume_args"

# A multi-word command is word-split into separate arguments
jq '.agent.command = "fdev exec wrapper -- claude"' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "wrapped-task" ) >/dev/null 2>&1
grep -q 'TASK_TYPE=dev fdev exec wrapper -- claude' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "multi-word agent command is word-split" || fail "multi-word agent command not split"

# Restore the default config for subsequent tests
cp "$HOME/.claude-conductor/config.default.json" "$CONDUCTOR_CFG"

# ============================================================
section "17b3. named agents (.agents) and per-task selection"
# ============================================================

# config.default.json ships named agent definitions for claude and codex
jq -e '.agents.claude.command == "claude" and .agents.claude.resume_args == "--resume"' \
    "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config defines agents.claude" || fail "agents.claude missing in config.default.json"
jq -e '.agents.codex.command == "codex" and .agents.codex.resume_args == "resume"' \
    "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config defines agents.codex" || fail "agents.codex missing in config.default.json"

# agent_command/agent_resume_args resolve a named agent from .agents
jq '.agents = {"claude": {"command": "claude", "resume_args": "--resume"}, "codex": {"command": "codex", "resume_args": "resume"}}' \
    "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
AC=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_command "codex" )
[[ "$AC" == "codex" ]] && pass "agent_command resolves named agent" || fail "agent_command(codex) = '$AC'"
AR=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_resume_args "codex" )
[[ "$AR" == "resume" ]] && pass "agent_resume_args resolves named agent" || fail "agent_resume_args(codex) = '$AR'"

# Without a name the legacy .agent.command path still wins
jq '.agent = {"command": "legacy-cli", "resume_args": "--continue"}' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
AC=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_command )
[[ "$AC" == "legacy-cli" ]] && pass "agent_command keeps legacy fallback" || fail "agent_command() = '$AC'"

# An agent name missing from .agents falls back to the name as the command
AC=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_command "somecli" )
[[ "$AC" == "somecli" ]] && pass "unknown agent name falls back to itself" || fail "agent_command(somecli) = '$AC'"

# agent_names lists the configured agent keys (one per line)
AN=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_names )
[[ "$AN" == $'claude\ncodex' ]] && pass "agent_names lists configured agents" || fail "agent_names = '$AN'"

# create_task with an agent argument launches that agent and exports TASK_AGENT
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "codex-tab" "" "codex" ) >/dev/null 2>&1
grep -q 'action new-tab -n codex-tab --cwd /tmp/proj -- env TASK_TAB_NAME=codex-tab TASK_TYPE=dev TASK_AGENT=codex codex' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task launches named agent with TASK_AGENT" || fail "create_task ignored agent argument"

# create_task with an agent + resume id uses that agent's resume_args
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$HOME/.claude-conductor/scripts/task-lib.sh" && create_task "/tmp/proj" "dev" "codex-res" "sess-abc" "codex" ) >/dev/null 2>&1
grep -q 'TASK_TYPE=dev TASK_AGENT=codex codex resume sess-abc' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "create_task resumes via named agent resume_args" || fail "create_task agent resume broken"

# Restore the default config for subsequent tests
cp "$HOME/.claude-conductor/config.default.json" "$CONDUCTOR_CFG"

# ============================================================
section "17b4. agent detection method and screen patterns"
# ============================================================

# config.default.json ships detection definitions: claude=hooks, codex=screen
jq -e '.agents.claude.detection == "hooks"' "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config sets agents.claude.detection=hooks" || fail "agents.claude.detection missing"
jq -e '.agents.codex.detection == "screen"' "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config sets agents.codex.detection=screen" || fail "agents.codex.detection missing"
jq -e '(.agents.codex.patterns.blocked | length) >= 1 and (.agents.codex.patterns.working | length) >= 1' \
    "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config ships codex blocked/working patterns" || fail "agents.codex.patterns missing"

# agent_detection resolves the configured method and defaults to hooks
AD=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_detection "codex" )
[[ "$AD" == "screen" ]] && pass "agent_detection resolves screen agent" || fail "agent_detection(codex) = '$AD'"
AD=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_detection "claude" )
[[ "$AD" == "hooks" ]] && pass "agent_detection resolves hooks agent" || fail "agent_detection(claude) = '$AD'"
jq 'del(.agents.codex.detection)' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
AD=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_detection "codex" )
[[ "$AD" == "hooks" ]] && pass "agent_detection defaults to hooks when unset" || fail "agent_detection default = '$AD'"
AD=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_detection "" )
[[ "$AD" == "hooks" ]] && pass "agent_detection treats agent-less as hooks" || fail "agent_detection('') = '$AD'"
AD=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_detection "somecli" )
[[ "$AD" == "hooks" ]] && pass "agent_detection treats unknown agent as hooks" || fail "agent_detection(somecli) = '$AD'"
cp "$HOME/.claude-conductor/config.default.json" "$CONDUCTOR_CFG"

# agent_patterns lists the configured regexes one per line
AP=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_patterns "codex" "blocked" )
echo "$AP" | grep -q 'Would you like to run the following command' \
  && pass "agent_patterns lists blocked patterns" || fail "agent_patterns(codex, blocked) = '$AP'"
AP=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_patterns "codex" "working" )
echo "$AP" | grep -q ' to interrupt' \
  && pass "agent_patterns lists working patterns" || fail "agent_patterns(codex, working) = '$AP'"
AP=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_patterns "claude" "blocked" )
[[ -z "$AP" ]] && pass "agent_patterns empty for pattern-less agent" || fail "agent_patterns(claude) = '$AP'"

# neutral（中立画面）のキーは同梱configに存在する。中身は実画面を採取して
# から足すので既定は空
jq -e '.agents.codex.patterns | has("neutral")' "$HOME/.claude-conductor/config.default.json" >/dev/null \
  && pass "default config ships codex neutral key" || fail "agents.codex.patterns.neutral missing"
AP=$( source "$HOME/.claude-conductor/scripts/task-lib.sh" && agent_patterns "codex" "neutral" )
[[ -z "$AP" ]] && pass "codex neutral patterns empty by default" || fail "agent_patterns(codex, neutral) = '$AP'"

# ============================================================
section "17b5. screen-detect-lib.sh (dump classification)"
# ============================================================

SDL="$HOME/.claude-conductor/scripts/screen-detect-lib.sh"
[[ -f "$SDL" ]] && pass "screen-detect-lib.sh installed" || fail "screen-detect-lib.sh missing"

# 実機のcodex v0.147.0から採取したdump-screen抜粋（末尾はビューポートの
# 空行パディング込み）。分類は空行を除いた末尾バッファに対して行う
SDL_FIX="$SANDBOX/screen-fixtures"
mkdir -p "$SDL_FIX"
cat > "$SDL_FIX/blocked-command.txt" << 'EOF'
• Running touch probe.txt


  Would you like to run the following command?

  Environment: local

  $ touch probe.txt

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `touch probe.txt` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
EOF
cat > "$SDL_FIX/blocked-edit.txt" << 'EOF'
• Edited probe.txt (+1 -0)
    1 +hello


  Would you like to make the following edits?


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for these files (a)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
EOF
cat > "$SDL_FIX/working.txt" << 'EOF'
• Ran touch probe.txt
  └ (no output)

• Working (3s • esc to interrupt)


› Summarize recent commits

  gpt-5.6-sol default · ~/projects/claude-conductor


EOF
cat > "$SDL_FIX/idle.txt" << 'EOF'
• probe.txt をカレントディレクトリに作成しました。

───────────────────────────────────────────


› Summarize recent commits

  gpt-5.6-sol default · ~/projects/claude-conductor



EOF
cat > "$SDL_FIX/unknown-prompt.txt" << 'EOF'
  Some brand-new dialog this version added

› 1. Do the thing
  2. Do not

  Press y to continue or n to abort
EOF
# 20行超の承認ダイアログ: 質問行は末尾窓の外だが承認フッターは見えている
cat > "$SDL_FIX/long-dialog.txt" << 'EOF'
  line01
  line02
  line03
  line04
  line05
  line06
  line07
  line08
  line09
  line10
  line11
  line12
  line13
  line14
  line15
  line16
  line17
  line18
› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
EOF
# エージェント出力がパターン文字列を引用しているだけの画面（誤blocked/working防止）
cat > "$SDL_FIX/transcript-echo.txt" << 'EOF'
• The config lists "Would you like to run the following command?" as a pattern
  and the spinner text mentions esc to interrupt somewhere in prose.

› Summarize recent commits

  gpt-5.6-sol default · ~/projects/claude-conductor
EOF

# 既知の承認プロンプトは blocked（一致行がメッセージとして返る）
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/blocked-command.txt")" )
[[ "$(echo "$CLS" | cut -f1)" == "blocked" ]] && pass "command approval classified blocked" || fail "classify(command) = '$CLS'"
echo "$CLS" | cut -f2 | grep -q "Would you like to run the following command?" \
  && pass "blocked classification returns matched line" || fail "blocked matched line = '$CLS'"
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/blocked-edit.txt")" )
[[ "$(echo "$CLS" | cut -f1)" == "blocked" ]] && pass "edit approval classified blocked" || fail "classify(edit) = '$CLS'"

# 実行中マーカーは working
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/working.txt")" )
[[ "$CLS" == "working" ]] && pass "spinner screen classified working" || fail "classify(working) = '$CLS'"

# マーカーなしは idle
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/idle.txt")" )
[[ "$CLS" == "idle" ]] && pass "composer screen classified idle" || fail "classify(idle) = '$CLS'"

# herdr方式の厳格性: 未知のダイアログは blocked にせず idle に倒す
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/unknown-prompt.txt")" )
[[ "$CLS" == "idle" ]] && pass "unknown dialog falls back to idle" || fail "classify(unknown) = '$CLS'"

# 質問行が末尾窓から押し出された長い承認ダイアログはフッターで blocked
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/long-dialog.txt")" )
[[ "$(echo "$CLS" | cut -f1)" == "blocked" ]] && pass "long dialog blocked via footer" || fail "classify(long) = '$CLS'"

# トランスクリプト中の引用ではblocked/working判定しない（行頭アンカー）
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/transcript-echo.txt")" )
[[ "$CLS" == "idle" ]] && pass "quoted pattern text stays idle" || fail "classify(echo) = '$CLS'"

# パターン未定義のagentは常に idle
CLS=$( source "$SDL" && screen_classify "claude" "$(cat "$SDL_FIX/blocked-command.txt")" )
[[ "$CLS" == "idle" ]] && pass "pattern-less agent always idle" || fail "classify(claude) = '$CLS'"

# neutral: 全画面ビューアやピッカーなど、エージェントの進行状態が読み取れない
# 画面。スピナーが隠れるだけで誤done、承認文言を含むログの表示で誤blockedに
# なるため、状態を更新せず前回状態を維持する（herdr の skip_state_update 相当）
cat > "$SDL_FIX/neutral-viewer.txt" << 'EOF'
  diff --git a/scripts/screen-detect-lib.sh b/scripts/screen-detect-lib.sh

  + Would you like to run the following command?

  ↑↓ scroll · esc to close
EOF
jq '.agents.codex.patterns.neutral = ["esc to close *$", "^ *↑↓ scroll"]' \
  "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/neutral-viewer.txt")" )
[[ "$CLS" == "neutral" ]] && pass "viewer screen classified neutral" || fail "classify(neutral) = '$CLS'"

# neutral は blocked より先に評価する（ビューアが承認文言を映しているだけの
# 画面を承認待ちと誤認しない）
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/blocked-command.txt")
  esc to close" )
[[ "$CLS" == "neutral" ]] && pass "neutral wins over blocked" || fail "classify(neutral+blocked) = '$CLS'"

# neutral 未定義のagentは従来どおり分類される（既存挙動の非回帰）
jq 'del(.agents.codex.patterns.neutral)' "$CONDUCTOR_CFG" > "$CONDUCTOR_CFG.tmp" \
  && mv "$CONDUCTOR_CFG.tmp" "$CONDUCTOR_CFG"
CLS=$( source "$SDL" && screen_classify "codex" "$(cat "$SDL_FIX/neutral-viewer.txt")" )
[[ "$CLS" == "idle" ]] && pass "no neutral patterns means no neutral state" || fail "classify without neutral = '$CLS'"
cp "$HOME/.claude-conductor/config.default.json" "$CONDUCTOR_CFG"

# ============================================================
section "17b6. screen-detect-lib.sh (pending lifecycle)"
# ============================================================

SDL_SESS="sdl-sess"
SDL_DIR="$HOME/.claude-pending/$SDL_SESS"
rm -rf "$SDL_DIR"
mkdir -p "$SDL_DIR"

# idle確定は実時間が1秒以上経ってからなので、テストで実際に待たずに済むよう
# 保留開始時刻を過去へ倒す。state fileが idle_pending でなければ何もしない。
sdl_age_idle_pending() {
    local f="$SDL_DIR/.screen-state/$SDL_SLUG" s
    [[ -f "$f" ]] || return 0
    s=$(cat "$f")
    [[ "${s%% *}" == "idle_pending" ]] || return 0
    echo "idle_pending $(( $(date +%s) - 5 ))" > "$f"
}

# blocked は screen-<slug>.json に Notification を書く
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "Would you like to run the following command?" )
SDL_SLUG=$( source "$SDL" && _screen_tab_slug "cx-task" )
SDL_F="$SDL_DIR/screen-$SDL_SLUG.json"
[[ -f "$SDL_F" ]] && pass "blocked writes screen pending" || fail "screen pending not written"
[[ "$(jq -r '.event' "$SDL_F" 2>/dev/null)" == "Notification" ]] && pass "blocked pending is Notification" || fail "event = $(jq -r '.event' "$SDL_F" 2>/dev/null)"
[[ "$(jq -r '.agent' "$SDL_F" 2>/dev/null)" == "codex" ]] && pass "screen pending carries agent" || fail "agent missing in screen pending"
[[ "$(jq -r '.tab' "$SDL_F" 2>/dev/null)" == "cx-task" ]] && pass "screen pending carries tab" || fail "tab missing in screen pending"

# blocked が続いても既存エントリを保持する（初回検出時刻を維持）
jq '.time = "00:00:00"' "$SDL_F" > "$SDL_F.tmp" && mv "$SDL_F.tmp" "$SDL_F"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "Would you like to run the following command?" )
[[ "$(jq -r '.time' "$SDL_F" 2>/dev/null)" == "00:00:00" ]] && pass "repeated blocked keeps first entry" || fail "blocked entry rewritten"

# working はそのタブのpending（notify由来のStopも含む）を消す
echo '{"tab":"cx-task","session":"sdl-sess","message":"turn done","event":"Stop","time":"10:00:00","agent":"codex"}' > "$SDL_DIR/thread-1.json"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
[[ ! -f "$SDL_F" ]] && pass "working clears screen pending" || fail "screen pending survived working"
[[ ! -f "$SDL_DIR/thread-1.json" ]] && pass "working clears notify Stop pending" || fail "notify pending survived working"

# working直後の idle 1回では Stop を書かない。スピナー行はツール実行の
# 切れ目や再描画の1フレームで消えるため、そこを拾うと偽doneになる
# （herdr の PendingIdleConfirmation 相当）
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "single idle after working writes no Stop" || fail "Stop written on first idle"
SDL_ST=$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)
[[ "${SDL_ST%% *}" == "idle_pending" ]] \
  && pass "first idle after working parks as idle_pending" || fail "state = '$SDL_ST'"
[[ "${SDL_ST#* }" =~ ^[0-9]+$ ]] \
  && pass "idle_pending records the observation time" || fail "no timestamp in state = '$SDL_ST'"

# 実時間が経たないうちの再観測では確定しない。ダッシュボードのポーリングは
# キー入力で早回りしうる（矢印キー1回でreadが3回返る）ため、観測回数だけを
# 条件にすると同じ1フレームを連続で見て偽doneが出る
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "rapid re-observation does not confirm idle" || fail "Stop written without elapsed time"
[[ "$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)" == "idle_pending ${SDL_ST#* }" ]] \
  && pass "rapid re-observation keeps the first timestamp" \
  || fail "timestamp reset = '$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)'"

# 実時間が経過してからの idle で Stop を確定する
sdl_age_idle_pending
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ "$(jq -r '.event' "$SDL_F" 2>/dev/null)" == "Stop" ]] && pass "idle confirms Stop after elapsed time" || fail "no Stop after elapsed idle"
[[ "$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)" == "idle" ]] \
  && pass "confirmed idle clears idle_pending" \
  || fail "state after confirm = '$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)'"

# 確定後は idle が続いても Stop を書き直さない（検出時刻を維持）
jq '.time = "00:00:00"' "$SDL_F" > "$SDL_F.tmp" && mv "$SDL_F.tmp" "$SDL_F"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ "$(jq -r '.time' "$SDL_F" 2>/dev/null)" == "00:00:00" ]] && pass "confirmed idle keeps first Stop entry" || fail "Stop entry rewritten"
rm -f "$SDL_F"

# idle保留中に working へ戻ったらpendingは消すが、Mainへは復帰しない。
# idle_pending は「その idle は信用しない」という内部状態でユーザーには何も
# 見えていないため、スピナーのちらつきでタブから引き剥がしてはいけない
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
echo '{"tab":"cx-task","session":"sdl-sess","message":"stale","event":"Notification","time":"10:01:00","agent":"codex"}' > "$SDL_DIR/thread-p.json"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
[[ ! -f "$SDL_DIR/thread-p.json" ]] && pass "idle_pending->working clears pending" || fail "pending survived idle_pending->working"
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "spinner flicker yanked focus to Main" || pass "idle_pending->working keeps focus in the tab"

# idle保留中に承認ダイアログが出たら即座にNotificationを出す
# （blocked に確定遅延はかけない: 人間を待たせている状態なので即時性が要る）
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
[[ "$(jq -r '.event' "$SDL_F" 2>/dev/null)" == "Notification" ]] \
  && pass "idle_pending->blocked notifies immediately" || fail "blocked delayed from idle_pending"
rm -f "$SDL_F"

# 起動直後など、workingを経ていない idle は何も書かない（新規タブの誤done防止）
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "fresh idle writes nothing" || fail "fresh idle wrote pending"

# notify由来のStopが既にあるタブでは idle でも重複Stopを書かない
# （確定に2回必要になったので、Stop判定まで到達させるため2回観測する）
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
echo '{"tab":"cx-task","session":"sdl-sess","message":"turn done","event":"Stop","time":"10:05:00","agent":"codex"}' > "$SDL_DIR/thread-2.json"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
sdl_age_idle_pending
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "idle defers to existing notify Stop" || fail "duplicate Stop written"
[[ -f "$SDL_DIR/thread-2.json" ]] && pass "notify Stop untouched by idle" || fail "notify Stop removed"
rm -f "$SDL_DIR/thread-2.json"

# blocked解消後の idle は Notification を消す（タブ内で直接回答したケース）
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
echo '{"tab":"cx-task","session":"sdl-sess","message":"turn done","event":"Stop","time":"10:06:00","agent":"codex"}' > "$SDL_DIR/thread-3.json"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ "$(jq -r '.event' "$SDL_F" 2>/dev/null)" != "Notification" ]] && pass "idle clears stale Notification" || fail "stale Notification kept"
rm -f "$SDL_DIR"/*.json

# Waitingで退避中のタブには一切触らない
rm -rf "$SDL_DIR/.screen-state"
echo '{"tab":"cx-task","session":"sdl-sess","message":"parked","event":"Waiting","time":"09:00:00","agent":"codex"}' > "$SDL_DIR/park.json"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
[[ ! -f "$SDL_F" ]] && pass "Waiting tab blocks new Notification" || fail "Notification written over Waiting"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
[[ -f "$SDL_DIR/park.json" ]] && pass "Waiting entry survives working" || fail "Waiting entry deleted"

# Waiting中も内部の状態遷移だけは進める（復帰後に整合させるため）が、
# 確定した idle でも Stop は書かない
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
sdl_age_idle_pending
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "Waiting tab gets no Stop from confirmed idle" || fail "Stop written over Waiting"
[[ "$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)" == "idle" ]] \
  && pass "Waiting tab keeps tracking state" \
  || fail "state under Waiting = '$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)'"
[[ -f "$SDL_DIR/park.json" ]] && pass "Waiting entry survives idle confirmation" || fail "Waiting entry deleted by idle"
rm -f "$SDL_DIR/park.json"

# blocked から降りた idle は working を経ていないので、何回観測しても done に
# ならない（承認をタブ内で答えただけでターンが終わったわけではない）
rm -rf "$SDL_DIR/.screen-state"
rm -f "$SDL_DIR"/*.json
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "blocked->idle never becomes done" || fail "Stop written without a working turn"

# blocked→working遷移はMainへ自動復帰する（Claudeの権限承認後の
# PostToolUse復帰に相当。タブ内で回答した合図なので引き戻す）
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "blocked->working returns to Main" || fail "no auto-return after approval"

# idle→working遷移（新しいプロンプト送信）もMainへ自動復帰する
echo "idle" > "$SDL_DIR/.screen-state/$SDL_SLUG"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "idle->working returns to Main" || fail "no auto-return after prompt submit"

# working継続では発火しない（毎ポーリングで引き戻さない）
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "working->working re-triggered auto-return" || pass "no auto-return while working continues"

# 初回観測がworking（ターン中のconductor再起動など）では復帰しない
rm -rf "$SDL_DIR/.screen-state"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "first observation triggered auto-return" || pass "no auto-return on first observation"

# neutral は state file も pending も一切変えない（前回状態を維持する）
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
echo '{"tab":"cx-task","session":"sdl-sess","message":"keep me","event":"Notification","time":"11:00:00","agent":"codex"}' > "$SDL_DIR/thread-n.json"
: > "$HOME/.claude-pending/zellij-calls.log"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "neutral" "" )
[[ "$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)" == "working" ]] \
  && pass "neutral keeps previous state" \
  || fail "state after neutral = '$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)'"
[[ -f "$SDL_DIR/thread-n.json" ]] && pass "neutral keeps existing pending" || fail "pending cleared by neutral"
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "neutral triggered auto-return" || pass "neutral does not auto-return"

# neutral を挟んでも working -> idle の確定手順は途切れない
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
SDL_ST=$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "neutral" "" )
[[ "$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)" == "$SDL_ST" ]] \
  && pass "neutral preserves idle_pending with its timestamp" \
  || fail "idle_pending lost = '$(cat "$SDL_DIR/.screen-state/$SDL_SLUG" 2>/dev/null)'"
rm -f "$SDL_DIR"/*.json
rm -rf "$SDL_DIR/.screen-state"

# タブ名はファイル名向けにサニタイズされる
( source "$SDL" && screen_update_pending "$SDL_SESS" "#28 fix" "codex" "blocked" "approval" )
SDL_S=$(ls "$SDL_DIR"/screen-*.json 2>/dev/null | head -1)
[[ -n "$SDL_S" ]] && pass "special-char tab name sanitized" || fail "no pending for special-char tab"
[[ "$(jq -r '.tab' "$SDL_S" 2>/dev/null)" == "#28 fix" ]] && pass "sanitized pending keeps original tab" || fail "tab mangled in pending"
rm -rf "$SDL_DIR"
mkdir -p "$SDL_DIR"

# マルチバイトの同文字数タブ名（tr -c では全バイトが_化して衝突する）が
# 別ファイルになる（cksumサフィックスで区別）
SLUG_A=$( source "$SDL" && _screen_tab_slug "設計" )
SLUG_B=$( source "$SDL" && _screen_tab_slug "実装" )
[[ "$SLUG_A" != "$SLUG_B" ]] && pass "multibyte tab names get distinct slugs" || fail "slug collision: $SLUG_A"
SLUG_A=$( source "$SDL" && _screen_tab_slug "a b" )
SLUG_B=$( source "$SDL" && _screen_tab_slug "a_b" )
[[ "$SLUG_A" != "$SLUG_B" ]] && pass "'a b' and 'a_b' get distinct slugs" || fail "slug collision: $SLUG_A"

# registryにエントリがあるタブのscreen由来pendingは dir / task_type /
# transcript_path を引き継ぐ（dd時のupload-logやDone復元が壊れないように）
SDL_TR="$SANDBOX/sdl-transcript.jsonl"
echo '{"x":1}' > "$SDL_TR"
( source "$HOME/.claude-conductor/scripts/registry-lib.sh" \
    && registry_upsert "$SDL_SESS" "sdl-sid-1" "cx-task" "/tmp/proj" "dev" "codex" "$SDL_TR" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "blocked" "approval" )
[[ "$(jq -r '.dir' "$SDL_F" 2>/dev/null)" == "/tmp/proj" ]] && pass "screen pending carries dir from registry" || fail "dir missing: $(cat "$SDL_F" 2>/dev/null)"
[[ "$(jq -r '.task_type' "$SDL_F" 2>/dev/null)" == "dev" ]] && pass "screen pending carries task_type" || fail "task_type missing"
[[ "$(jq -r '.transcript_path' "$SDL_F" 2>/dev/null)" == "$SDL_TR" ]] && pass "screen pending carries transcript_path" || fail "transcript_path missing"
rm -rf "$CONDUCTOR_HOME/tasks/$SDL_SESS"
rm -f "$SDL_F"

# screen由来Stopの後からnotify由来Stopが届いたら、次のidle観測で自ら消えて
# 二重done表示に収束する
rm -rf "$SDL_DIR/.screen-state"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "working" "" )
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
sdl_age_idle_pending
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ "$(jq -r '.event' "$SDL_F" 2>/dev/null)" == "Stop" ]] || fail "precondition: screen Stop not written"
echo '{"tab":"cx-task","session":"sdl-sess","message":"turn done","event":"Stop","time":"10:07:00","agent":"codex"}' > "$SDL_DIR/thread-4.json"
( source "$SDL" && screen_update_pending "$SDL_SESS" "cx-task" "codex" "idle" "" )
[[ ! -f "$SDL_F" ]] && pass "late notify Stop absorbs screen Stop" || fail "duplicate Stop persisted"
[[ -f "$SDL_DIR/thread-4.json" ]] && pass "notify Stop survives convergence" || fail "notify Stop removed"
rm -f "$SDL_DIR"/*.json

# create_task は同名タブの残留 .screen-state を消してから作る
# （削除済みタスクの working を新タブが引き継ぐと偽の Task complete が付く）
mkdir -p "$SDL_DIR/.screen-state"
echo "working" > "$SDL_DIR/.screen-state/$SDL_SLUG"
( export ZELLIJ_SESSION_NAME="$SDL_SESS"
  source "$HOME/.claude-conductor/scripts/task-lib.sh" \
    && create_task "/tmp/proj" "dev" "cx-task" "" "codex" ) >/dev/null 2>&1
[[ ! -f "$SDL_DIR/.screen-state/$SDL_SLUG" ]] && pass "create_task clears stale screen state" || fail "stale screen state survived recreation"
rm -rf "$SDL_DIR"

# ============================================================
section "17b7. screen-detect-lib.sh (tick over live panes)"
# ============================================================

SDL_SESS2="sdl-tick"
SDL_DIR2="$HOME/.claude-pending/$SDL_SESS2"
rm -rf "$SDL_DIR2"
mkdir -p "$SDL_DIR2"
SDL_PANES='[
  {"id":0,"is_plugin":true,"tab_name":"cx-task","title":"tab-bar"},
  {"id":5,"is_plugin":false,"tab_name":"cx-task","terminal_command":"env TASK_TAB_NAME=cx-task TASK_TYPE=dev TASK_AGENT=codex codex","title":"codex"},
  {"id":6,"is_plugin":false,"tab_name":"cx-task","terminal_command":"bash task-control.sh cx-task","title":"bar"},
  {"id":7,"is_plugin":false,"tab_name":"cl-task","terminal_command":"env TASK_TAB_NAME=cl-task TASK_TYPE=dev TASK_AGENT=claude claude","title":"claude"}
]'
mkdir -p "$SDL_FIX/tick"
cp "$SDL_FIX/blocked-command.txt" "$SDL_FIX/tick/terminal_5.txt"
cp "$SDL_FIX/idle.txt" "$SDL_FIX/tick/terminal_7.txt"

: > "$HOME/.claude-pending/zellij-calls.log"
( export MOCK_PANES_JSON="$SDL_PANES" MOCK_SCREEN_DIR="$SDL_FIX/tick"
  source "$SDL" && screen_detect_tick "$SDL_SESS2" )

[[ "$(jq -r '.event' "$SDL_DIR2/screen-$SDL_SLUG.json" 2>/dev/null)" == "Notification" ]] \
  && pass "tick surfaces codex approval as Notification" || fail "tick wrote no Notification"
grep -q 'dump-screen -p terminal_5' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "tick dumps the codex agent pane" || fail "codex pane not dumped"
grep -q 'dump-screen -p terminal_7' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "hooks agent pane dumped (must skip claude)" || pass "hooks agent pane skipped"
grep -q 'dump-screen -p terminal_6' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "non-agent pane dumped" || pass "non-agent pane skipped"
rm -rf "$SDL_DIR2"

# ============================================================
section "17b8. create_task guards the tab-creation race"
# ============================================================

TL="$HOME/.claude-conductor/scripts/task-lib.sh"
CALLS_LOG="$HOME/.claude-pending/zellij-calls.log"

# zellij 0.44.1の `zellij action` はサーバ応答を約1秒しか待たないため、new-tab の
# rc=0 は「受理」であって「タブが在る」ではない。登録が遅れてもポーリングが待ち、
# 名前が見えてからフォーカスとペイン構築へ進む。
mock_zellij_reset
CT_RC=0
( export MOCK_TAB_REGISTER_AFTER=3
  source "$TL" && create_task "/tmp/proj" "dev" "slow-tab" ) >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -eq 0 ]] && pass "create_task succeeds when tab registration is delayed" \
  || fail "create_task failed on delayed registration: $CT_RC"
QTN_CALLS=$(grep -c 'action query-tab-names' "$CALLS_LOG" | tr -d ' ')
[[ "$QTN_CALLS" -ge 3 ]] && pass "polls query-tab-names until the tab appears ($QTN_CALLS calls)" \
  || fail "did not poll query-tab-names: $QTN_CALLS calls"
GOTO_LINE=$(grep -n 'action go-to-tab-name slow-tab' "$CALLS_LOG" | head -1 | cut -d: -f1)
QTN3_LINE=$(grep -n 'action query-tab-names' "$CALLS_LOG" | sed -n '3p' | cut -d: -f1)
[[ -n "$GOTO_LINE" && -n "$QTN3_LINE" && "$GOTO_LINE" -gt "$QTN3_LINE" ]] \
  && pass "focus is issued only after the tab is listed" \
  || fail "focus issued before registration was confirmed (goto=$GOTO_LINE qtn3=$QTN3_LINE)"
grep -q 'action new-pane --direction down --cwd /tmp/proj -- bash .*task-control.sh slow-tab' "$CALLS_LOG" \
  && pass "task-control pane is built once the tab is confirmed" || fail "task-control pane missing"

# go-to-tab-name は存在しないタブ名でも rc=0 で戻る無言 no-op で、成否は stdout の
# 有無でしか判定できない（zellij 0.44.1 実測: ヒット時のみタブ index を出力）。
# stdout が空のうちはフォーカス未確立としてリトライする。
mock_zellij_reset
CT_RC=0
( export MOCK_FOCUS_EMPTY_UNTIL=2
  source "$TL" && create_task "/tmp/proj" "dev" "retry-focus" ) >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -eq 0 ]] && pass "create_task retries focus until stdout confirms it" \
  || fail "create_task failed despite a later successful focus: $CT_RC"
GOTO_CALLS=$(grep -c 'action go-to-tab-name retry-focus' "$CALLS_LOG" | tr -d ' ')
[[ "$GOTO_CALLS" -ge 3 ]] && pass "go-to-tab-name retried on empty stdout ($GOTO_CALLS calls)" \
  || fail "no retry on empty go-to-tab-name stdout: $GOTO_CALLS calls"
grep -q 'action new-pane --direction down --cwd /tmp/proj -- bash .*task-control.sh retry-focus' "$CALLS_LOG" \
  && pass "panes built after focus is confirmed" || fail "panes not built after confirmed focus"

# タブが登録されないままデッドラインを超えたら、ペインは1枚も作らずに非0で返す。
# （フォーカスが Main のままなら new-pane は Main を壊す。Main保護が最優先）
mock_zellij_reset
CT_RC=0
( export MOCK_TAB_REGISTER_AFTER=99999 CONDUCTOR_TAB_READY_MS=300
  source "$TL" && create_task "/tmp/proj" "dev" "never-tab" ) >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -ne 0 ]] && pass "create_task returns non-zero when the tab never registers" \
  || fail "create_task returned 0 though the tab never registered"
grep -q 'action new-pane' "$CALLS_LOG" \
  && fail "built panes without a registered tab (would hit Main)" || pass "no pane built without a registered tab"
grep -q 'action resize' "$CALLS_LOG" \
  && fail "resized without a registered tab (would resize Main)" || pass "no resize without a registered tab"

# タブは登録されたがフォーカスが確認できない（go-to-tab-name の stdout が空のまま）
# 場合も同様にペイン構築へ進まない。
mock_zellij_reset
CT_RC=0
( export MOCK_FOCUS_EMPTY_UNTIL=99999 CONDUCTOR_TAB_READY_MS=300
  source "$TL" && create_task "/tmp/proj" "dev" "unfocusable" ) >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -ne 0 ]] && pass "create_task returns non-zero when focus cannot be confirmed" \
  || fail "create_task returned 0 with unconfirmed focus"
grep -q 'action new-pane' "$CALLS_LOG" \
  && fail "built panes with unconfirmed focus (would hit Main)" || pass "no pane built with unconfirmed focus"

# 正常系のポーリングは1往復で終わる（健全なサーバでの追加往復ゼロ）
mock_zellij_reset
( source "$TL" && create_task "/tmp/proj" "dev" "fast-tab" ) >/dev/null 2>&1
QTN_CALLS=$(grep -c 'action query-tab-names' "$CALLS_LOG" | tr -d ' ')
GOTO_CALLS=$(grep -c 'action go-to-tab-name fast-tab' "$CALLS_LOG" | tr -d ' ')
[[ "$QTN_CALLS" -eq 1 && "$GOTO_CALLS" -eq 1 ]] \
  && pass "healthy server costs exactly one query + one focus" \
  || fail "extra round trips on a healthy server: qtn=$QTN_CALLS goto=$GOTO_CALLS"

# ============================================================
section "17b9. zellij kill guard (hung server)"
# ============================================================

# 劣化サーバでは `zellij action` 自体が戻ってこない。macOS に timeout(1) は無いので
# bash 3.2 互換の kill ガードで打ち切り、ハングプロセスを溜めない。
mock_zellij_reset
create_task_hang_probe() {
    export MOCK_HANG_CMD=new-tab CONDUCTOR_ZELLIJ_TIMEOUT=1
    source "$TL"
    # 戻り値は 0 / 42 に畳む（番犬の 124 = ハングしたまま、と区別するため）
    create_task "/tmp/proj" "dev" "hang-tab" && return 0
    return 42
}
CT_RC=0
run_with_watchdog 20 create_task_hang_probe >/dev/null 2>&1 || CT_RC=$?
[[ $CT_RC -eq 42 ]] && pass "hung new-tab is killed and reported as failure" \
  || fail "create_task did not survive a hung new-tab (rc=$CT_RC)"
grep -q 'action new-pane' "$CALLS_LOG" \
  && fail "built panes after a hung new-tab" || pass "no pane built after a hung new-tab"

# screen_detect_tick の list-panes がハングしても、その tick は空扱いで抜けてくる
# （既存の `2>/dev/null || true` と同じ「何も検出しなかった」挙動に揃える）
SDL_SESS3="sdl-hang"
SDL_DIR3="$HOME/.claude-pending/$SDL_SESS3"
rm -rf "$SDL_DIR3"; mkdir -p "$SDL_DIR3"
mock_zellij_reset
tick_hang_probe() {
    export MOCK_PANES_JSON="$SDL_PANES" MOCK_SCREEN_DIR="$SDL_FIX/tick" \
           MOCK_HANG_CMD=list-panes CONDUCTOR_ZELLIJ_TIMEOUT=1
    source "$SDL"
    screen_detect_tick "$SDL_SESS3"
}
TICK_RC=0
run_with_watchdog 20 tick_hang_probe >/dev/null 2>&1 || TICK_RC=$?
[[ $TICK_RC -eq 0 ]] && pass "screen tick returns when list-panes hangs" \
  || fail "screen tick hung on list-panes (rc=$TICK_RC)"
[[ -z "$(ls -A "$SDL_DIR3" 2>/dev/null)" ]] && pass "hung tick writes no pending (treated as empty)" \
  || fail "hung tick wrote pending files"
grep -q 'action dump-screen' "$CALLS_LOG" \
  && fail "dumped screens despite a hung list-panes" || pass "no dump-screen after a hung list-panes"
pkill -f '^sleep 251$' 2>/dev/null || true
rm -rf "$SDL_DIR3"

# ============================================================
section "17b10. guard timeout accuracy, setup budget, guarded call sites"
# ============================================================

# ミリ秒計測（perl があれば高精度、無ければ秒精度にフォールバック）
now_ms() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time * 1000)'
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

# 既定の perl alarm 方式: 打ち切り時刻が指定秒数からほとんどずれない
mock_zellij_reset
G_T0=$(now_ms)
G_RC=0
( export MOCK_HANG_CMD=list-tabs
  source "$TL" && _zellij_guarded 2 action list-tabs ) >/dev/null 2>&1 || G_RC=$?
G_MS=$(( $(now_ms) - G_T0 ))
[[ $G_RC -eq 124 ]] && pass "guard returns 124 on timeout" || fail "guard rc wrong: $G_RC"
[[ $G_MS -ge 1800 && $G_MS -le 2600 ]] \
  && pass "timeout fires close to the limit (${G_MS}ms for 2s)" \
  || fail "timeout drifted: ${G_MS}ms for a 2s limit"

# perl が無い環境向けフォールバック（ポーリング）。時刻精度の保証は上の本経路が
# 持つので、ここでは「期限より早く殺さない」「実時間で必ず打ち切る」の両端を見る。
# 早切りは実際に踏んだバグで、SECONDS（1秒単位）を -ge で比較すると start の位相
# 次第で最大1秒早くコマンドを殺してしまう。
mock_zellij_reset
G_T0=$(now_ms)
G_RC=0
( export MOCK_HANG_CMD=list-tabs CONDUCTOR_GUARD_NO_PERL=1
  source "$TL" && _zellij_guarded 3 action list-tabs ) >/dev/null 2>&1 || G_RC=$?
G_MS=$(( $(now_ms) - G_T0 ))
[[ $G_RC -eq 124 ]] && pass "fallback guard returns 124 on timeout" || fail "fallback rc wrong: $G_RC"
[[ $G_MS -ge 2900 ]] && pass "fallback never kills before the limit (${G_MS}ms for 3s)" \
  || fail "fallback killed early: ${G_MS}ms for a 3s limit"
[[ $G_MS -le 4500 ]] \
  && pass "fallback timeout bounded by real time (${G_MS}ms for 3s)" \
  || fail "fallback timeout drifted: ${G_MS}ms for a 3s limit"

# 正常系では両方式とも zellij の終了ステータスをそのまま返す
( source "$TL" && _zellij_guarded 5 action list-tabs ) >/dev/null 2>&1 \
  && pass "guard passes through success" || fail "guard broke a successful call"
( export CONDUCTOR_GUARD_NO_PERL=1; source "$TL" && _zellij_guarded 5 action list-tabs ) >/dev/null 2>&1 \
  && pass "fallback guard passes through success" || fail "fallback guard broke a successful call"

# 全体予算: ハングするコマンドが並んでも create_task は予算内で切り上げ、
# タブとペインは機能しているので rc=0 で返る（1コマンドずつ 10 秒待つと数分かかる）
mock_zellij_reset
B_T0=$(now_ms)
CT_RC=0
( export MOCK_HANG_CMD=resize CONDUCTOR_ZELLIJ_TIMEOUT=1 CONDUCTOR_TASK_SETUP_BUDGET=3
  source "$TL" && create_task "/tmp/proj" "dev" "budget-tab" ) >/dev/null 2>&1 || CT_RC=$?
B_MS=$(( $(now_ms) - B_T0 ))
[[ $CT_RC -eq 0 ]] && pass "budget exhaustion still reports success (tab is usable)" \
  || fail "create_task failed on budget exhaustion: $CT_RC"
B_RESIZES=$(grep -c 'action resize' "$CALLS_LOG" | tr -d ' ')
[[ "$B_RESIZES" -lt 30 ]] && pass "resize loop stops when the budget runs out ($B_RESIZES/30)" \
  || fail "ran the whole resize loop despite the budget: $B_RESIZES"
[[ $B_MS -le 8000 ]] && pass "create_task stays within its setup budget (${B_MS}ms)" \
  || fail "setup budget not enforced: ${B_MS}ms"
grep -q 'action new-pane --direction down --cwd /tmp/proj -- bash .*task-control.sh budget-tab' "$CALLS_LOG" \
  && pass "task-control pane is still built under a tight budget" || fail "task-control pane skipped"

# ダッシュボードの render は毎秒回る。list-tabs が固まっても抜けてくること
mock_zellij_reset
dash_hang_probe() {
    export MOCK_HANG_CMD=list-tabs CONDUCTOR_ZELLIJ_TIMEOUT=1 CONDUCTOR_DASHBOARD_ONCE=1 \
           ZELLIJ_SESSION_NAME=dash-hang
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh"
}
D_RC=0
run_with_watchdog 20 dash_hang_probe >/dev/null 2>&1 || D_RC=$?
[[ $D_RC -ne 124 ]] && pass "dashboard render survives a hung list-tabs" \
  || fail "dashboard render hung on list-tabs"
pkill -f '^sleep 251$' 2>/dev/null || true

# ダッシュボード経路の zellij 呼び出しは全てガード経由であること（素の呼び出しが
# 1本でも残ると、そこだけ劣化サーバで無限に固まる）
raw_zellij_calls() {
    grep -n 'zellij action' "$1" \
      | sed -e 's/^[0-9]*://' -e 's/^[[:space:]]*//' \
      | grep -v '^#' \
      | grep -v '_zellij_guarded' || true
}
for GF in task-lib.sh screen-detect-lib.sh dashboard-loop.sh; do
    RAW=$(raw_zellij_calls "$HOME/.claude-conductor/scripts/$GF")
    [[ -z "$RAW" ]] && pass "$GF has no unguarded zellij action call" \
      || fail "$GF still calls zellij directly: $RAW"
done

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
section "22b. task deletion removes registry entries (dd-commit only)"
# ============================================================

source "$HOME/.claude-conductor/scripts/registry-lib.sh"
TC22="$HOME/.claude-conductor/scripts/task-control.sh"
registry_upsert "test-session" "del-sid-1" "del-tab" "/tmp/d" "dev" "claude" ""
registry_upsert "test-session" "del-sid-2" "del-tab" "/tmp/d" "dev" "claude" ""
registry_upsert "test-session" "keep-sid" "keep-tab" "/tmp/d" "dev" "claude" ""
cat > "$PENDING_DIR/del-sid-2.json" << 'EOF'
{ "tab":"del-tab","session":"test-session","message":"done","event":"Stop","time":"10:00:00","claude_session_id":"del-sid-2" }
EOF

# record-output.sh 単体ではレジストリを消さない
# （アップロード失敗で削除がキャンセルされるとタブは生き続けるため）
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "del-tab"
[[ -f "$CONDUCTOR_HOME/tasks/test-session/del-sid-1.json" && -f "$CONDUCTOR_HOME/tasks/test-session/del-sid-2.json" ]] \
  && pass "record-output alone keeps registry entries" || fail "record-output removed registry prematurely"

# dd確定（task-control.sh）でタブの全レジストリエントリが除去される
# （--resume再開でsidが変わり同一タブに複数エントリが残るケースも一掃）
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC22" "del-tab" >/dev/null 2>&1
[[ ! -f "$CONDUCTOR_HOME/tasks/test-session/del-sid-1.json" && ! -f "$CONDUCTOR_HOME/tasks/test-session/del-sid-2.json" ]] \
  && pass "dd-commit removes all registry entries for the tab" || fail "registry entries remain after dd"
[[ -f "$CONDUCTOR_HOME/tasks/test-session/keep-sid.json" ]] \
  && pass "other tab's registry entry kept" || fail "unrelated registry entry removed"

# pendingファイルが無いタブのddでもレジストリは除去される
registry_upsert "test-session" "orphan-sid" "orphan-tab" "/tmp/d" "" "" ""
rm -f "$PENDING_DIR"/*.json
printf 'dd' | ZELLIJ_SESSION_NAME=test-session bash "$TC22" "orphan-tab" >/dev/null 2>&1
[[ ! -f "$CONDUCTOR_HOME/tasks/test-session/orphan-sid.json" ]] \
  && pass "registry removed even without a pending file" || fail "orphan registry entry remains"

# dashboard-loop.sh の d+数字 削除経路にも除去が組み込まれている
grep -q 'registry_remove_by_tab' "$HOME/.claude-conductor/scripts/dashboard-loop.sh" \
  && pass "dashboard-loop deletion path removes registry" || fail "dashboard-loop missing registry removal"

rm -rf "$CONDUCTOR_HOME/tasks"

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
section "25b. record-output.sh (agent carried into daily log)"
# ============================================================

cat > "$PENDING_DIR/sess-agent-rec.json" << EOF
{
  "tab": "agent-rec-test",
  "session": "test-session",
  "claude_session_id": "sess-agent-rec",
  "message": "done",
  "event": "Stop",
  "time": "10:00:01",
  "agent": "codex"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "agent-rec-test"

AGENT_REC=$(tail -1 "$DAILY_FILE" | jq -r '.agent')
[[ "$AGENT_REC" == "codex" ]] && pass "agent carried into daily log" || fail "agent not carried: $AGENT_REC"
rm -f "$PENDING_DIR/sess-agent-rec.json"

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

# create_task の rc=3（タブは出来たがフォーカス未確認でペイン未構築）は復元成功扱い。
# Done に残すと再試行のたびに同名タブが増えるだけで、タブ自体は機能している。
HB_AT="${RESTORE_TODAY}T05:00:00+0900"
cat >> "$RESTORE_DAILY_FILE" << JSONL
{"tab":"halfbuilt","session":"$RESTORE_SESSION","completed_at":"$HB_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$PROJ_DIR","task_type":"dev"}
JSONL
mock_zellij_reset
HB_RC=0
MOCK_FOCUS_EMPTY_UNTIL=99999 CONDUCTOR_TAB_READY_MS=300 \
  ZELLIJ_SESSION_NAME="$RESTORE_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" \
  "halfbuilt" "$RESTORE_SESSION" "$HB_AT" 2>/dev/null || HB_RC=$?
[[ $HB_RC -eq 0 ]] && pass "restore-task exits 0 when the tab is created but not focus-confirmed" \
  || fail "half-built restore exit wrong: $HB_RC"
grep -q "action new-tab -n halfbuilt" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "half-built restore did create the tab" || fail "half-built restore created no tab"
grep -q 'action new-pane' "$HOME/.claude-pending/zellij-calls.log" \
  && fail "half-built restore built panes without confirmed focus" || pass "half-built restore built no panes"
HB_FLAG=$(jq -r 'select(.tab=="halfbuilt") | .restored' "$RESTORE_DAILY_FILE")
[[ "$HB_FLAG" == "true" ]] && pass "half-built restore marks the entry restored (no duplicate on retry)" \
  || fail "half-built entry left in Done: $HB_FLAG"

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
section "26h. restore-task.sh (codex agent resume)"
# ============================================================

CXR_SESSION="codex-restore"
CXR_DIR="$HOME/.claude-conductor/daily/$CXR_SESSION"
mkdir -p "$CXR_DIR"
CXR_TODAY=$(date '+%Y-%m-%d')
CXR_FILE="$CXR_DIR/$CXR_TODAY.jsonl"
CXR_AT="${CXR_TODAY}T12:00:00+0900"
CXR_PROJ="$SANDBOX/cxproj"
mkdir -p "$CXR_PROJ"
CXR_ROLLOUT="$SANDBOX/cx-rollout.jsonl"
echo '{}' > "$CXR_ROLLOUT"

cat > "$CXR_FILE" << JSONL
{"tab":"cx-task","session":"$CXR_SESSION","completed_at":"$CXR_AT","message":"done","summary":null,"markers":{"merged":false,"slack":false,"doc":false},"dir":"$CXR_PROJ","task_type":"dev","claude_session_id":"thread-cx1","transcript_path":"$CXR_ROLLOUT","agent":"codex"}
JSONL

: > "$HOME/.claude-pending/zellij-calls.log"
CXR_RC=0
ZELLIJ_SESSION_NAME="$CXR_SESSION" bash "$HOME/.claude-conductor/scripts/restore-task.sh" "cx-task" "$CXR_SESSION" "$CXR_AT" || CXR_RC=$?
[[ $CXR_RC -eq 0 ]] && pass "codex restore exits 0" || fail "codex restore exit wrong: $CXR_RC"
grep -q "action new-tab -n cx-task --cwd $CXR_PROJ -- env TASK_TAB_NAME=cx-task TASK_TYPE=dev TASK_AGENT=codex codex resume thread-cx1" "$HOME/.claude-pending/zellij-calls.log" \
  && pass "codex restore resumes via codex resume <id>" || fail "codex restore command wrong"

# ============================================================
section "26i. record-output.sh (codex rollout parsing)"
# ============================================================

CXP_TRANSCRIPT="$SANDBOX/codex-rollout.jsonl"
cat > "$CXP_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-07T20:44:09.850Z","type":"session_meta","payload":{"id":"thread-cx2","cwd":"/tmp/myapp","cli_version":"0.147.0","source":"exec"}}
{"timestamp":"2026-08-07T20:44:09.851Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-07T20:44:09.900Z","type":"event_msg","payload":{"type":"user_message","message":"fix the bug"}}
{"timestamp":"2026-08-07T20:44:10.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"c1","status":"completed","call_id":"call1","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"npm test\"});"}}
{"timestamp":"2026-08-07T20:44:10.100Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call1","output":"ok"}}
{"timestamp":"2026-08-07T20:44:10.200Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
{"timestamp":"2026-08-07T20:44:11.000Z","type":"event_msg","payload":{"type":"user_message","message":"now merge it"}}
{"timestamp":"2026-08-07T20:44:12.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"c2","status":"completed","call_id":"call2","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"gh pr merge 12 --squash\"});"}}
{"timestamp":"2026-08-07T20:44:13.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500000,"cached_input_tokens":500000,"cache_write_input_tokens":200000,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1600000}}}}
{"timestamp":"2026-08-07T20:44:13.100Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"merged"}}
ROLLOUT

cat > "$PENDING_DIR/thread-cx2.json" << EOF
{
  "tab": "cx-parse-test",
  "session": "test-session",
  "claude_session_id": "thread-cx2",
  "message": "merged",
  "event": "Stop",
  "time": "20:44:13",
  "transcript_path": "$CXP_TRANSCRIPT",
  "dir": "/tmp/myapp",
  "task_type": "dev",
  "agent": "codex"
}
EOF

ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cx-parse-test"

CXP_REC=$(tail -1 "$DAILY_FILE")
[[ "$(echo "$CXP_REC" | jq -r '.summary.total_turns')" == "2" ]] && pass "codex turns counted from user_message" || fail "codex turns wrong: $(echo "$CXP_REC" | jq -r '.summary.total_turns')"
[[ "$(echo "$CXP_REC" | jq -r '.summary.total_tool_calls')" == "2" ]] && pass "codex tool calls counted (outputs excluded)" || fail "codex tool calls wrong: $(echo "$CXP_REC" | jq -r '.summary.total_tool_calls')"
[[ "$(echo "$CXP_REC" | jq -r '.summary.tools_used[0]')" == "exec" ]] && pass "codex tool names recorded" || fail "codex tools_used wrong"
[[ "$(echo "$CXP_REC" | jq -r '.summary.model')" == "gpt-5.6-sol" ]] && pass "codex model from turn_context" || fail "codex model wrong: $(echo "$CXP_REC" | jq -r '.summary.model')"
[[ "$(echo "$CXP_REC" | jq -r '.summary.total_input_tokens')" == "1000000" ]] && pass "codex non-cached input tokens" || fail "codex input tokens wrong: $(echo "$CXP_REC" | jq -r '.summary.total_input_tokens')"
[[ "$(echo "$CXP_REC" | jq -r '.summary.cache_read_tokens')" == "500000" ]] && pass "codex cached tokens recorded" || fail "codex cache tokens wrong"
# 1M*$5 + 0.1M*$30 + 0.5M*$0.5 + 0.2M*$6.25 = 5 + 3 + 0.25 + 1.25 = 9.5
[[ "$(echo "$CXP_REC" | jq -r '.summary.total_cost_usd')" == "9.5" ]] && pass "codex cost from gpt-5.6-sol pricing" || fail "codex cost wrong: $(echo "$CXP_REC" | jq -r '.summary.total_cost_usd')"
[[ "$(echo "$CXP_REC" | jq -r '.markers.merged')" == "true" ]] && pass "codex merged marker from gh pr merge" || fail "codex merged marker wrong"
[[ "$(echo "$CXP_REC" | jq -r '.agent')" == "codex" ]] && pass "codex agent in daily entry" || fail "codex agent missing"

# An unknown model yields a null cost instead of borrowing claude pricing
CXP2_TRANSCRIPT="$SANDBOX/codex-rollout-unknown.jsonl"
sed 's/gpt-5.6-sol/gpt-unknown-model/' "$CXP_TRANSCRIPT" > "$CXP2_TRANSCRIPT"
cat > "$PENDING_DIR/thread-cx3.json" << EOF
{"tab":"cx-unknown-test","session":"test-session","claude_session_id":"thread-cx3","message":"done","event":"Stop","time":"20:45:00","transcript_path":"$CXP2_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cx-unknown-test"
CXP2_COST=$(tail -1 "$DAILY_FILE" | jq -r '.summary.total_cost_usd')
[[ "$CXP2_COST" == "null" ]] && pass "unknown codex model -> null cost" || fail "unknown model cost wrong: $CXP2_COST"
rm -f "$PENDING_DIR/thread-cx2.json" "$PENDING_DIR/thread-cx3.json"

# ============================================================
section "26i1b. record-output.sh (codex rollout v2: item_completed)"
# ============================================================

# 新しい codex は会話とツール実行を event_msg/item_completed の item として
# 記録し、旧 user_message / agent_message イベントを出さない（実機の
# ~/.codex/sessions を調査して確認、cli_version では判別できない）。
# content 要素の type は UserMessage が "text"、AgentMessage が "Text" と
# 大文字小文字が揺れるため、fixture でも実データどおりに揺らしておく。
CXV2_TRANSCRIPT="$SANDBOX/codex-rollout-v2.jsonl"
cat > "$CXV2_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T16:24:48.000Z","type":"session_meta","payload":{"id":"thread-cxv2","cwd":"/tmp/myapp","cli_version":"0.147.0","source":"exec"}}
{"timestamp":"2026-08-10T16:24:48.100Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T16:24:49.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"timestamp":"2026-08-10T16:24:50.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"V2USERMARKER fix the bug","text_elements":[]}]}}}
{"timestamp":"2026-08-10T16:24:51.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","content":[{"type":"Text","text":"V2REASONMARKER internal deliberation"}]}}}
{"timestamp":"2026-08-10T16:24:52.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1","process_id":"111","command":["/bin/zsh","-lc","npm test"],"cwd":"file:///tmp/myapp","status":"completed"}}}
{"timestamp":"2026-08-10T16:24:53.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"exec-2","server":"node_repl","tool":"js","arguments":{"code":"console.log(1)"}}}}
{"timestamp":"2026-08-10T16:24:53.200Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"exec-4","changes":{"/tmp/myapp/app.ts":{"type":"update","unified_diff":"@@ -0,0 +1 @@\n+fixed\n","move_path":null}},"status":"completed"}}}
{"timestamp":"2026-08-10T16:24:53.400Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"web.search","id":"exec-5","query":"how to fix","action":{"type":"search","query":null,"queries":["how to fix"]},"results":[]}}}
{"timestamp":"2026-08-10T16:24:54.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"V2AGENTMARKER tests pass"}],"phase":"commentary"}}}
{"timestamp":"2026-08-10T16:24:55.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u2","content":[{"type":"text","text":"now merge it","text_elements":[]}]}}}
{"timestamp":"2026-08-10T16:24:56.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-3","process_id":"112","command":["/bin/zsh","-lc","gh pr merge 12 --squash"],"cwd":"file:///tmp/myapp","status":"completed"}}}
{"timestamp":"2026-08-10T16:24:57.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500000,"cached_input_tokens":500000,"cache_write_input_tokens":200000,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1600000}}}}
{"timestamp":"2026-08-10T16:24:58.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m2","content":[{"type":"Text","text":"merged"}],"phase":"final_answer"}}}
{"timestamp":"2026-08-10T16:24:58.100Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"merged","turn_id":"t1"}}
ROLLOUT

cat > "$PENDING_DIR/thread-cxv2.json" << EOF
{"tab":"cxv2-test","session":"test-session","claude_session_id":"thread-cxv2","message":"merged","event":"Stop","time":"16:24:58","transcript_path":"$CXV2_TRANSCRIPT","dir":"/tmp/myapp","task_type":"dev","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-test"

CXV2_REC=$(tail -1 "$DAILY_FILE")
[[ "$(echo "$CXV2_REC" | jq -r '.summary.total_turns')" == "2" ]] \
  && pass "v2 turns counted from UserMessage items" || fail "v2 turns wrong: $(echo "$CXV2_REC" | jq -r '.summary.total_turns')"
# response_item が無い rollout では item_completed のツール系 item で数える
# （Reasoning / メッセージ item は対象外）
[[ "$(echo "$CXV2_REC" | jq -r '.summary.total_tool_calls')" == "5" ]] \
  && pass "v2 tool calls counted from item_completed" || fail "v2 tool calls wrong: $(echo "$CXV2_REC" | jq -r '.summary.total_tool_calls')"
# 名前は .name // .tool // .kind // .type（McpToolCall は .tool、Extension は .kind）
[[ "$(echo "$CXV2_REC" | jq -c '.summary.tools_used')" == '["CommandExecution","FileChange","js","web.search"]' ]] \
  && pass "v2 tools_used from tool/kind/type fields" || fail "v2 tools_used wrong: $(echo "$CXV2_REC" | jq -c '.summary.tools_used')"
[[ "$(echo "$CXV2_REC" | jq -r '.summary.model')" == "gpt-5.6-sol" ]] \
  && pass "v2 model still from turn_context" || fail "v2 model wrong"
[[ "$(echo "$CXV2_REC" | jq -r '.summary.total_cost_usd')" == "9.5" ]] \
  && pass "v2 cost still from token_count" || fail "v2 cost wrong: $(echo "$CXV2_REC" | jq -r '.summary.total_cost_usd')"
[[ "$(echo "$CXV2_REC" | jq -r '.markers.merged')" == "true" ]] \
  && pass "v2 merged marker from CommandExecution command" || fail "v2 merged marker wrong"

# response_item のツール呼び出しがある rollout では従来どおりそちらで数える。
# 実機の rollout では custom_tool_call(name="exec") の input が
# tools.web__run / tools.exec_command / tools.mcp__* と多岐にわたり、それぞれが
# Extension / CommandExecution / McpToolCall item として描画される。つまり両者は
# 同一活動の別ビューであり、合算やカテゴリ別 union は二重計上になる。
CXV2M_TRANSCRIPT="$SANDBOX/codex-rollout-v2-mixed.jsonl"
cp "$CXV2_TRANSCRIPT" "$CXV2M_TRANSCRIPT"
cat >> "$CXV2M_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T16:24:59.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"c1","status":"completed","call_id":"call1","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"ls\"});"}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2m.json" << EOF
{"tab":"cxv2-mixed-test","session":"test-session","claude_session_id":"thread-cxv2m","message":"done","event":"Stop","time":"16:25:00","transcript_path":"$CXV2M_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-mixed-test"
CXV2M_REC=$(tail -1 "$DAILY_FILE")
[[ "$(echo "$CXV2M_REC" | jq -r '.summary.total_tool_calls')" == "1" ]] \
  && pass "response_item view wins over item view (no double count)" || fail "mixed tool count wrong: $(echo "$CXV2M_REC" | jq -r '.summary.total_tool_calls')"
[[ "$(echo "$CXV2M_REC" | jq -c '.summary.tools_used')" == '["exec"]' ]] \
  && pass "mixed rollout uses response_item tool names" || fail "mixed tools_used wrong: $(echo "$CXV2M_REC" | jq -c '.summary.tools_used')"
[[ "$(echo "$CXV2M_REC" | jq -r '.markers.merged')" == "true" ]] \
  && pass "merged marker scans both views" || fail "mixed merged marker wrong"

# CommandExecution item は stdout / aggregated_output も持つ。実機の rollout
# には「gh pr merge を含むファイルを cat しただけ」の item があり、item 全体を
# 走査すると merged マーカーが誤検知する。走査対象は実行したコマンドに限る。
CXV2S_TRANSCRIPT="$SANDBOX/codex-rollout-v2-stdout.jsonl"
cat > "$CXV2S_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T17:00:00.000Z","type":"session_meta","payload":{"id":"thread-cxv2s","cwd":"/tmp/myapp","cli_version":"0.147.0","source":"exec"}}
{"timestamp":"2026-08-10T17:00:00.100Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T17:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"read the docs","text_elements":[]}]}}}
{"timestamp":"2026-08-10T17:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1","process_id":"1","command":["/bin/zsh","-lc","cat NOTES.md"],"cwd":"file:///tmp/myapp","status":"completed","exit_code":0,"stdout":"To land a PR run: gh pr merge 12 --squash\n","aggregated_output":"To land a PR run: gh pr merge 12 --squash\n"}}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2s.json" << EOF
{"tab":"cxv2-stdout-test","session":"test-session","claude_session_id":"thread-cxv2s","message":"done","event":"Stop","time":"17:00:03","transcript_path":"$CXV2S_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-stdout-test"
[[ "$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')" == "false" ]] \
  && pass "merged marker ignores command output" || fail "merged marker false-positive from stdout"
rm -f "$PENDING_DIR/thread-cxv2s.json"

# .command の型が揺れても jq を落とさない。落とすとレコードが丸ごと
# summary:null に退避してしまうため、string や配列内 object も許容する。
CXV2T_TRANSCRIPT="$SANDBOX/codex-rollout-v2-cmdtype.jsonl"
cat > "$CXV2T_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T17:10:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T17:10:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"go"}]}}}
{"timestamp":"2026-08-10T17:10:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e1","command":"gh pr merge 12 --squash","status":"completed"}}}
{"timestamp":"2026-08-10T17:10:03.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e2","command":["/bin/zsh",{"arg":"weird"},"ls"],"status":"completed"}}}
{"timestamp":"2026-08-10T17:10:04.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e3","status":"completed"}}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2t.json" << EOF
{"tab":"cxv2-cmdtype-test","session":"test-session","claude_session_id":"thread-cxv2t","message":"done","event":"Stop","time":"17:10:05","transcript_path":"$CXV2T_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-cmdtype-test"
CXV2T_REC=$(tail -1 "$DAILY_FILE")
[[ "$(echo "$CXV2T_REC" | jq -r '.summary')" != "null" ]] \
  && pass "odd .command types do not abort the parse" || fail "record fell back to summary:null on odd .command"
[[ "$(echo "$CXV2T_REC" | jq -r '.summary.total_tool_calls')" == "3" ]] \
  && pass "odd .command items are still counted" || fail "cmdtype tool count wrong: $(echo "$CXV2T_REC" | jq -r '.summary.total_tool_calls')"
[[ "$(echo "$CXV2T_REC" | jq -r '.markers.merged')" == "true" ]] \
  && pass "merged detected from a string .command" || fail "string .command merge not detected"
rm -f "$PENDING_DIR/thread-cxv2t.json"

# MCP 経由のマージはツール名で判定する。引数テキストは走査しない
# （Slack 投稿などが gh pr merge を含むだけで誤検知するため）。
CXV2P_TRANSCRIPT="$SANDBOX/codex-rollout-v2-mcp.jsonl"
cat > "$CXV2P_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T17:20:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T17:20:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"merge it"}]}}}
{"timestamp":"2026-08-10T17:20:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"m1","server":"github","tool":"merge_pull_request","arguments":{"pullNumber":12}}}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2p.json" << EOF
{"tab":"cxv2-mcp-test","session":"test-session","claude_session_id":"thread-cxv2p","message":"done","event":"Stop","time":"17:20:03","transcript_path":"$CXV2P_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-mcp-test"
[[ "$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')" == "true" ]] \
  && pass "merged detected from an MCP merge_pull_request call" || fail "MCP merge not detected"

CXV2N_TRANSCRIPT="$SANDBOX/codex-rollout-v2-mcp-noise.jsonl"
cat > "$CXV2N_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T17:30:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T17:30:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"tell the team"}]}}}
{"timestamp":"2026-08-10T17:30:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"m1","server":"slack","tool":"send_message","arguments":{"text":"次は gh pr merge 12 をお願いします"}}}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2n.json" << EOF
{"tab":"cxv2-noise-test","session":"test-session","claude_session_id":"thread-cxv2n","message":"done","event":"Stop","time":"17:30:03","transcript_path":"$CXV2N_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-noise-test"
[[ "$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')" == "false" ]] \
  && pass "merged ignores gh pr merge quoted in MCP arguments" || fail "MCP argument text false-positive"

# 旧ビュー側の MCP マージ（ツール名一致）も拾う
CXV1P_TRANSCRIPT="$SANDBOX/codex-rollout-v1-mcp.jsonl"
cat > "$CXV1P_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T17:40:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T17:40:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"merge it"}}
{"timestamp":"2026-08-10T17:40:02.000Z","type":"response_item","payload":{"type":"function_call","id":"f1","call_id":"c1","name":"mcp__github__merge_pull_request","arguments":"{\"pullNumber\":12}"}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv1p.json" << EOF
{"tab":"cxv1-mcp-test","session":"test-session","claude_session_id":"thread-cxv1p","message":"done","event":"Stop","time":"17:40:03","transcript_path":"$CXV1P_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv1-mcp-test"
[[ "$(tail -1 "$DAILY_FILE" | jq -r '.markers.merged')" == "true" ]] \
  && pass "merged detected from a v1 MCP merge call name" || fail "v1 MCP merge not detected"
rm -f "$PENDING_DIR/thread-cxv2p.json" "$PENDING_DIR/thread-cxv2n.json" "$PENDING_DIR/thread-cxv1p.json"

# 旧形式イベントと新形式 item が同居しても turns を二重に数えない
CXV2D_TRANSCRIPT="$SANDBOX/codex-rollout-v2-dual.jsonl"
cp "$CXV2_TRANSCRIPT" "$CXV2D_TRANSCRIPT"
cat >> "$CXV2D_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T16:25:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"legacy duplicate of the same turn"}}
ROLLOUT
cat > "$PENDING_DIR/thread-cxv2d.json" << EOF
{"tab":"cxv2-dual-test","session":"test-session","claude_session_id":"thread-cxv2d","message":"done","event":"Stop","time":"16:25:01","transcript_path":"$CXV2D_TRANSCRIPT","agent":"codex"}
EOF
ZELLIJ_SESSION_NAME=test-session bash "$HOME/.claude-conductor/scripts/record-output.sh" "cxv2-dual-test"
[[ "$(tail -1 "$DAILY_FILE" | jq -r '.summary.total_turns')" == "2" ]] \
  && pass "legacy and item turns are not double counted" || fail "dual turns wrong: $(tail -1 "$DAILY_FILE" | jq -r '.summary.total_turns')"
rm -f "$PENDING_DIR/thread-cxv2.json" "$PENDING_DIR/thread-cxv2m.json" "$PENDING_DIR/thread-cxv2d.json"

# ============================================================
section "26i2. record-output.sh (retry replaces the daily entry)"
# ============================================================

# アップロード失敗で dd が中止されると record-output は同じ pending に対して
# 何度も走る。(tab, claude_session_id) が同じ未 restore 行は置換されて Done に
# エントリが増殖しないことを確認する。専用セッションを使い、他セクションが
# 参照する $DAILY_FILE には触れない。
DDS_SESSION="dedupe-session"
DDS_PENDING="$HOME/.claude-pending/$DDS_SESSION"
DDS_DAILY="$HOME/.claude-conductor/daily/$DDS_SESSION/$(date '+%Y-%m-%d').jsonl"
mkdir -p "$DDS_PENDING"
rm -rf "$HOME/.claude-conductor/daily/$DDS_SESSION"

DDS_TRANSCRIPT="$SANDBOX/dedupe-transcript.jsonl"
cat > "$DDS_TRANSCRIPT" << 'TRANSCRIPT'
{"type":"user","message":{"role":"user","content":"hello"},"uuid":"u1","timestamp":"2026-08-10T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":5}},"uuid":"a1","timestamp":"2026-08-10T10:00:01Z"}
TRANSCRIPT

# pending は 1 タブ 1 ファイルなので、毎回同じパスを書き換えて再実行を模す
dds_pending_write() {
    # dds_pending_write <claude_session_id> <message>
    cat > "$DDS_PENDING/dedupe.json" << EOF
{"tab":"dedupe-tab","session":"$DDS_SESSION","claude_session_id":"$1","message":"$2","event":"Stop","time":"10:00:00","transcript_path":"$DDS_TRANSCRIPT","dir":"/tmp/myapp","task_type":"dev"}
EOF
}
dds_run() { ZELLIJ_SESSION_NAME="$DDS_SESSION" bash "$HOME/.claude-conductor/scripts/record-output.sh" "dedupe-tab"; }
dds_lines() { wc -l < "$DDS_DAILY" | tr -d ' '; }

dds_pending_write "sid-A" "first"
dds_run
[[ "$(dds_lines)" == "1" ]] && pass "first record appended" || fail "first record count wrong: $(dds_lines)"

# 同一 tab + 同一 claude_session_id の再実行は行を増やさず内容を置き換える
dds_pending_write "sid-A" "second"
dds_run
[[ "$(dds_lines)" == "1" ]] && pass "retry keeps a single daily entry" || fail "retry duplicated entry: $(dds_lines)"
[[ "$(jq -r '.message' "$DDS_DAILY")" == "second" ]] \
  && pass "retry updates the entry content" || fail "entry not updated: $(jq -r '.message' "$DDS_DAILY")"

# 別 claude_session_id は別行（--resume で sid が変わったケース）
dds_pending_write "sid-B" "third"
dds_run
[[ "$(dds_lines)" == "2" ]] && pass "different claude_session_id appends a new entry" || fail "sid-B count wrong: $(dds_lines)"
[[ "$(head -1 "$DDS_DAILY" | jq -r '.claude_session_id')" == "sid-A" ]] \
  && pass "existing entry of another sid kept" || fail "sid-A entry lost"

# 置換は「削除して末尾に追記」＝置換された行は最終行へ移動する
dds_pending_write "sid-A" "fourth"
dds_run
[[ "$(dds_lines)" == "2" ]] && pass "replacement does not grow the file" || fail "replacement count wrong: $(dds_lines)"
[[ "$(head -1 "$DDS_DAILY" | jq -r '.claude_session_id')" == "sid-B" ]] \
  && pass "untouched entry keeps its position" || fail "sid-B moved unexpectedly"
[[ "$(tail -1 "$DDS_DAILY" | jq -r '.claude_session_id')" == "sid-A" ]] \
  && [[ "$(tail -1 "$DDS_DAILY" | jq -r '.message')" == "fourth" ]] \
  && pass "replaced entry is appended at the tail" || fail "replaced entry not at tail"

# restored:true の行は置換対象外（復元済みの履歴は残す）
DDS_TMP="$SANDBOX/dedupe-restored.jsonl"
jq -c '. + {restored:true}' "$DDS_DAILY" > "$DDS_TMP" && mv "$DDS_TMP" "$DDS_DAILY"
dds_pending_write "sid-A" "fifth"
dds_run
[[ "$(dds_lines)" == "3" ]] && pass "restored entries are not replaced" || fail "restored entry replaced: $(dds_lines)"
[[ "$(jq -sr '[.[] | select(.restored == true)] | length' "$DDS_DAILY")" == "2" ]] \
  && pass "restored entries kept intact" || fail "restored entries changed"
[[ "$(tail -1 "$DDS_DAILY" | jq -r '.message')" == "fifth" ]] \
  && pass "new entry appended alongside restored ones" || fail "new entry missing after restored"

# claude_session_id を持たないレコードは dedupe キーが無いので無条件追記
rm -f "$DDS_PENDING/dedupe.json"
cat > "$DDS_PENDING/nosid.json" << EOF
{"tab":"dedupe-nosid","session":"$DDS_SESSION","message":"sixth","event":"Stop","time":"10:00:00"}
EOF
ZELLIJ_SESSION_NAME="$DDS_SESSION" bash "$HOME/.claude-conductor/scripts/record-output.sh" "dedupe-nosid"
ZELLIJ_SESSION_NAME="$DDS_SESSION" bash "$HOME/.claude-conductor/scripts/record-output.sh" "dedupe-nosid"
[[ "$(dds_lines)" == "5" ]] && pass "records without claude_session_id always append" || fail "no-sid count wrong: $(dds_lines)"
rm -f "$DDS_PENDING/nosid.json"

# screen-<slug> はタブ名だけから作られる合成 ID（screen-detect-lib.sh）なので、
# 無関係な過去タスクが同名タブを使っていると同じキーになる。dedupe 対象外とし、
# 常に追記する（重複は回復できるが、他タスクの履歴削除は回復できない）。
dds_pending_write "screen-dedupe-tab" "seventh"
dds_run
dds_pending_write "screen-dedupe-tab" "eighth"
dds_run
[[ "$(dds_lines)" == "7" ]] && pass "screen-<slug> session ids are never deduped" || fail "screen sid deduped: $(dds_lines)"
[[ "$(jq -sr '[.[] | select(.claude_session_id == "screen-dedupe-tab")] | length' "$DDS_DAILY")" == "2" ]] \
  && pass "both screen-detected entries kept" || fail "screen entries lost"

# ロックを取れなかった場合（fail-open）は全体書き換えを行わず追記のみ。
# 非ロックの書き換えは並行 restore が立てた restored:true を巻き戻しうる。
mkdir -p "$DDS_DAILY.lock"
echo "$$" > "$DDS_DAILY.lock/pid"
dds_pending_write "sid-A" "ninth"
dds_run
[[ -d "$DDS_DAILY.lock" ]] && pass "record-output leaves a lock it does not hold" || fail "record-output released a foreign lock"
release_lock "$DDS_DAILY.lock"
[[ "$(dds_lines)" == "8" ]] \
  && pass "record without the lock appends instead of rewriting" || fail "unlocked write count wrong: $(dds_lines)"
[[ "$(jq -sr '[.[] | select(.claude_session_id == "sid-A" and (.restored // false) != true)] | length' "$DDS_DAILY")" == "2" ]] \
  && pass "unlocked write leaves the existing entry untouched" || fail "unlocked write replaced an entry"
rm -f "$DDS_PENDING/dedupe.json"

# ロックは持ち越されない（次の record-output がブロックされない）
[[ ! -d "$DDS_DAILY.lock" ]] && pass "daily-log lock released after replace" || fail "daily-log lock left behind"

# ============================================================
section "26j. restore-session.sh (rebuild tasks from registry)"
# ============================================================

# restore-session.sh は別プロセスとして走るのでモックはそのまま使う
# （query-tab-names は MOCK_TAB_NAMES + new-tab で作られたタブを返す）。
# これまでのセクションで作られたタブ名を持ち越さないようリセットする。
mock_zellij_reset

RS="$HOME/.claude-conductor/scripts/restore-session.sh"
[[ -f "$RS" ]] && pass "restore-session.sh installed" || fail "restore-session.sh missing"
RS_CALLS="$HOME/.claude-pending/zellij-calls.log"
source "$HOME/.claude-conductor/scripts/registry-lib.sh"

RS_DIR1="$SANDBOX/rs-work/alpha"
RS_DIR2="$SANDBOX/rs-work/beta"
mkdir -p "$RS_DIR1" "$RS_DIR2"
RS_TRANSCRIPT="$SANDBOX/rs-transcript.jsonl"
echo '{"x":1}' > "$RS_TRANSCRIPT"

# transcriptが残っているタスクは --resume 付きで再生成される
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-1" "alpha-dev" "$RS_DIR1" "" "" "$RS_TRANSCRIPT"
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" bash "$RS"
grep -q "new-tab -n alpha-dev --cwd $RS_DIR1 -- env TASK_TAB_NAME=alpha-dev TASK_TYPE= claude --resume rs-sid-1" "$RS_CALLS" \
  && pass "task recreated with --resume when transcript exists" || fail "no resume recreation: $(grep new-tab "$RS_CALLS")"
grep -q "go-to-tab-name Main" "$RS_CALLS" \
  && pass "focus returns to Main after restore" || fail "did not return to Main"

# transcriptが消えているタスクは新規セッションで再生成される（壊れた--resumeをしない）
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-2" "beta-dev" "$RS_DIR2" "" "" "/nonexistent/transcript.jsonl"
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" bash "$RS"
grep -q "new-tab -n beta-dev --cwd $RS_DIR2 -- env TASK_TAB_NAME=beta-dev TASK_TYPE= claude$" "$RS_CALLS" \
  && pass "missing transcript -> fresh session (no broken --resume)" || fail "wrong recreation: $(grep new-tab "$RS_CALLS")"

# 既に存在するタブは再生成しない（エントリは保持）
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-3" "alive-tab" "$RS_DIR1" "" "" ""
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main
alive-tab" bash "$RS"
grep -q "new-tab" "$RS_CALLS" \
  && fail "recreated a tab that already exists" || pass "existing tab skipped"
[[ -f "$CONDUCTOR_HOME/tasks/rs-sess/rs-sid-3.json" ]] \
  && pass "skipped entry kept in registry" || fail "entry dropped for live tab"

# dirが消えたエントリは破棄され、再生成もされない
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-4" "gone-dir" "$SANDBOX/rs-work/removed" "" "" ""
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" bash "$RS"
grep -q "new-tab" "$RS_CALLS" \
  && fail "recreated a task whose dir vanished" || pass "vanished dir not recreated"
[[ ! -f "$CONDUCTOR_HOME/tasks/rs-sess/rs-sid-4.json" ]] \
  && pass "vanished-dir entry dropped from registry" || fail "stale entry remains"

# 同一タブに複数エントリ（resume再開でsidが変わった場合）: 最新updated_atのみ再生成
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-old" "dup-tab" "$RS_DIR1" "" "" "$RS_TRANSCRIPT"
jq '.updated_at = "2020-01-01T00:00:00+0000"' "$CONDUCTOR_HOME/tasks/rs-sess/rs-old.json" > "$CONDUCTOR_HOME/tasks/rs-sess/rs-old.json.tmp" \
  && mv "$CONDUCTOR_HOME/tasks/rs-sess/rs-old.json.tmp" "$CONDUCTOR_HOME/tasks/rs-sess/rs-old.json"
registry_upsert "rs-sess" "rs-new" "dup-tab" "$RS_DIR1" "" "" "$RS_TRANSCRIPT"
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" bash "$RS"
NEW_TAB_COUNT=$(grep -c "new-tab" "$RS_CALLS")
[[ "$NEW_TAB_COUNT" == "1" ]] && pass "duplicate tab entries restored once" || fail "restored $NEW_TAB_COUNT times"
grep -q -- "--resume rs-new" "$RS_CALLS" \
  && pass "newest entry's session id wins" || fail "stale sid used: $(grep new-tab "$RS_CALLS")"

# レジストリが空なら何もしない（zellijも呼ばない）
rm -rf "$CONDUCTOR_HOME/tasks"
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess bash "$RS"
[[ ! -s "$RS_CALLS" ]] && pass "empty registry is a silent no-op" || fail "unexpected zellij calls: $(cat "$RS_CALLS")"

# 壊れたJSONエントリが混ざっていても他タスクの復元は続行される
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-6" "gamma-dev" "$RS_DIR1" "" "" "$RS_TRANSCRIPT"
echo '{broken json' > "$CONDUCTOR_HOME/tasks/rs-sess/corrupt.json"
: > "$RS_CALLS"
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" bash "$RS"
grep -q "new-tab -n gamma-dev" "$RS_CALLS" \
  && pass "corrupt registry entry does not abort restore" || fail "restore aborted on corrupt entry: $(cat "$RS_CALLS")"

# create_task が rc=3（タブは出来たがフォーカス未確認）でも「復元済み（不完全）」
# として数える。硬い失敗と同じ扱いにすると、次回起動では同名タブが既存として
# スキップされるので永遠に直らず、最後の go-to-tab-name Main も出ないため
# フォーカスが半端なタブに残ってしまう。
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-7" "halfbuilt-dev" "$RS_DIR1" "" "" ""
mock_zellij_reset
ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" MOCK_FOCUS_EMPTY_UNTIL=99999 \
  CONDUCTOR_TAB_READY_MS=300 bash "$RS" 2>/dev/null
grep -q "new-tab -n halfbuilt-dev" "$RS_CALLS" \
  && pass "half-built restore creates the tab" || fail "no tab created: $(cat "$RS_CALLS")"
grep -q "go-to-tab-name Main" "$RS_CALLS" \
  && pass "focus returns to Main even when a tab stays half-built" \
  || fail "did not return to Main after a half-built restore"

# ============================================================
section "26k. dashboard-loop.sh triggers restore on startup"
# ============================================================

# ダッシュボード起動時にrestore-session.shが呼ばれ、タスクが再生成される
rm -rf "$CONDUCTOR_HOME/tasks"
registry_upsert "rs-sess" "rs-sid-5" "dash-restore" "$RS_DIR1" "" "" ""
: > "$RS_CALLS"
CONDUCTOR_DASHBOARD_ONCE=1 ZELLIJ_SESSION_NAME=rs-sess MOCK_TAB_NAMES="Main" \
  bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" >/dev/null 2>&1
grep -q "new-tab -n dash-restore" "$RS_CALLS" \
  && pass "dashboard startup restores registered tasks" || fail "dashboard did not restore: $(cat "$RS_CALLS")"

rm -rf "$CONDUCTOR_HOME/tasks" "$HOME/.claude-pending/rs-sess"

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
section "28b. fetch-news.sh (description trimming)"
# ============================================================

# description の切り詰めは awk で手書きせず jq に任せる。awk で「エスケープ →
# 切り詰め」の順にすると 120 文字目が \" の \ に当たったときに \ が単独で残って
# JSON が壊れ、逆に「切り詰め → エスケープ」にしても substr がバイト単位のため
# マルチバイト文字を割ると BSD awk が towc エラーで異常終了する。どちらも
# 当日の news ファイルが 1 件も書かれない結果になる。jq なら符号化は構成上
# 正しく、`.[:120]` はコードポイント単位で切るのでどちらの故障も起きない。
# 実スクリプトを固定フィードで走らせて結果を見る。
NEWS_TRUNC_FEED="$SANDBOX/news-trunc-feed.xml"
export NEWS_TRUNC_FEED

cat > "$MOCK_BIN/curl" << 'MOCKCURL'
#!/bin/bash
cat "$NEWS_TRUNC_FEED"
MOCKCURL
chmod +x "$MOCK_BIN/curl"

# $1 の文字を $2 個並べる（bash 3.2 に文字列の乗算は無い）
repeat_char() {
    printf '%*s' "$2" '' | tr ' ' "$1"
}

# 日本語など複数バイト文字は tr では並べられないので awk で繰り返す
repeat_str() {
    awk -v s="$1" -v n="$2" 'BEGIN { out = ""; for (i = 0; i < n; i++) out = out s; print out }'
}

# $NEWS_TRUNC_FEED に置いたフィードで fetch-news.sh を走らせる。
# 当日ファイルのパスは実行の前後で引き直し、両方を探す。日付を先に固定すると
# 日付をまたいだ瞬間に書き先と検証先がずれて偽 fail になる。実行中にまたぐ
# 可能性もあるので、実行後の日付だけを見るのでも足りない。
news_feed_run() {
    NEWS_TRUNC_BEFORE="$NEWS_DIR/$(date '+%Y-%m-%d').json"
    rm -f "$NEWS_TRUNC_BEFORE"
    bash "$HOME/.claude-conductor/scripts/fetch-news.sh" 2>/dev/null
    NEWS_TRUNC_AFTER="$NEWS_DIR/$(date '+%Y-%m-%d').json"
    if [[ -f "$NEWS_TRUNC_AFTER" ]]; then
        NEWS_TRUNC_FILE="$NEWS_TRUNC_AFTER"
    else
        NEWS_TRUNC_FILE="$NEWS_TRUNC_BEFORE"
    fi
}

# $1 を <item> の中身にした 1 件だけのフィードで走らせる
news_item_run() {
    cat > "$NEWS_TRUNC_FEED" << FEED
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>TC</title>
<item>$1</item>
</channel>
</rss>
FEED
    news_feed_run
}

# $1 を description に持つ 1 件だけのフィードで走らせる
news_trunc_run() {
    news_item_run "<title><![CDATA[Truncate Case]]></title><link>https://example.com/t</link><description><![CDATA[$1]]></description>"
}

news_trunc_desc() {
    jq -r '.items[0].description' "$NEWS_TRUNC_FILE" 2>/dev/null || true
}

# (1) マルチバイト境界: 120 文字目が 'あ' に当たる。バイト単位で切ると
# 文字の途中で割れ、BSD awk が towc エラーで落ちて当日ファイルが全滅する。
NEWS_TRUNC_HEAD=$(repeat_char A 119)
news_trunc_run "${NEWS_TRUNC_HEAD}あ and more text past the limit"

[[ -f "$NEWS_TRUNC_FILE" ]] \
  && pass "news file written when the cut lands on a multibyte char" \
  || fail "no news file: the multibyte cut killed the run"
jq '.' "$NEWS_TRUNC_FILE" > /dev/null 2>&1 \
  && pass "news JSON is valid when the cut lands on a multibyte char" \
  || fail "news JSON invalid: $(tail -c 120 "$NEWS_TRUNC_FILE" 2>/dev/null)"
[[ "$(news_trunc_desc)" == "${NEWS_TRUNC_HEAD}あ..." ]] \
  && pass "the multibyte char is kept whole at the cut" \
  || fail "description wrong at the multibyte cut: $(news_trunc_desc)"

# (2) エスケープ境界: 安全文字 119 個の直後に `"`。エスケープしてから切ると
# `\"` の `\` だけが末尾に残って JSON が壊れる。
news_trunc_run "${NEWS_TRUNC_HEAD}\"personal superintelligence\" and more text past the limit"

[[ -f "$NEWS_TRUNC_FILE" ]] \
  && pass "news file written when the cut lands on a quote" \
  || fail "no news file: the escaped description broke the JSON"
jq '.' "$NEWS_TRUNC_FILE" > /dev/null 2>&1 \
  && pass "news JSON is valid when the cut lands on a quote" \
  || fail "news JSON invalid: $(tail -c 120 "$NEWS_TRUNC_FILE" 2>/dev/null)"
NEWS_TRUNC_COUNT=$(jq -r '.items | length' "$NEWS_TRUNC_FILE" 2>/dev/null || echo 0)
[[ "$NEWS_TRUNC_COUNT" == "1" ]] && pass "the item survives the cut" || fail "item count: $NEWS_TRUNC_COUNT"
[[ "$(news_trunc_desc)" == "${NEWS_TRUNC_HEAD}\"..." ]] \
  && pass "the quote is kept whole at the cut" \
  || fail "description wrong at the cut: $(news_trunc_desc)"

# (3) 119 文字（上限未満）: そのまま、"..." は付かない
NEWS_TRUNC_119=$(repeat_char B 119)
news_trunc_run "$NEWS_TRUNC_119"
[[ "$(news_trunc_desc)" == "$NEWS_TRUNC_119" ]] \
  && pass "119 chars are left untouched" || fail "119 chars altered: $(news_trunc_desc)"

# (4) 120 文字ちょうど: 上限と同じなので切らない
NEWS_TRUNC_120=$(repeat_char C 120)
news_trunc_run "$NEWS_TRUNC_120"
[[ "$(news_trunc_desc)" == "$NEWS_TRUNC_120" ]] \
  && pass "120 chars are left untouched" || fail "120 chars altered: $(news_trunc_desc)"

# (5) 121 文字: 先頭 120 文字 + "..."
NEWS_TRUNC_121=$(repeat_char D 121)
news_trunc_run "$NEWS_TRUNC_121"
[[ "$(news_trunc_desc)" == "$(repeat_char D 120)..." ]] \
  && pass "121 chars are cut to 120 plus an ellipsis" || fail "121 chars cut wrong: $(news_trunc_desc)"

# (6) 日本語だけの description: バイトではなく文字で数える（Go 版と同じ単位）。
# 130 文字 = 390 バイトなので、バイト単位なら 40 文字で切れてしまう。
NEWS_TRUNC_JP=$(repeat_str "あ" 130)
news_trunc_run "$NEWS_TRUNC_JP"
[[ "$(news_trunc_desc)" == "$(repeat_str "あ" 120)..." ]] \
  && pass "Japanese description is cut by characters, not bytes" \
  || fail "Japanese cut wrong: $(news_trunc_desc)"
# バイト数で確かめる（awk の length はロケール次第で文字にもバイトにもなる）。
# 'あ' は UTF-8 で 3 バイトなので 120 文字 + "..." は 363 バイト。
# バイトで切っていた頃は 120 バイト = 40 文字 + "..." で 123 バイトだった。
NEWS_TRUNC_JP_BYTES=$(printf '%s' "$(news_trunc_desc)" | wc -c | tr -d ' ')
[[ "$NEWS_TRUNC_JP_BYTES" == "363" ]] \
  && pass "Japanese description keeps 120 chars plus the ellipsis" \
  || fail "Japanese description bytes: $NEWS_TRUNC_JP_BYTES (want 363)"

# (7) タブを含む description でも列がずれない（awk は TSV を出し jq が組む）
news_trunc_run "before	after"
[[ "$(news_trunc_desc)" == "before after" ]] \
  && pass "tabs in the description do not shift the columns" \
  || fail "tab handling wrong: $(news_trunc_desc)"

# (8) CRLF の CDATA: \r は削除、\n だけを空白にする。両方を空白にすると
# 二重空白になって本文が間延びする。
news_trunc_run "$(printf 'line one\r\nline two')"
[[ "$(news_trunc_desc)" == "line one line two" ]] \
  && pass "CRLF collapses to a single space" \
  || fail "CRLF handling wrong: [$(news_trunc_desc)]"

# (9) 改行で整形された <link>: url に余白を残さない。余白付きの url は
# news-loop の open が失敗する。
news_item_run '<title><![CDATA[Link Case]]></title><link>
    https://example.com/spaced
  </link><description><![CDATA[desc]]></description>'
NEWS_TRUNC_URL=$(jq -r '.items[0].url' "$NEWS_TRUNC_FILE" 2>/dev/null || true)
[[ "$NEWS_TRUNC_URL" == "https://example.com/spaced" ]] \
  && pass "a newline-wrapped <link> yields a clean url" \
  || fail "url has stray whitespace: [$NEWS_TRUNC_URL]"

# (10) 不正な UTF-8 バイト: awk は測定も切断もしないので落ちない（LC_ALL=C）。
# jq が U+FFFD へ置き換えた有効な JSON になる。
printf '<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"><channel><title>TC</title>\n<item><title><![CDATA[Bad Byte]]></title><link>https://example.com/b</link><description><![CDATA[before\377after]]></description></item>\n</channel></rss>\n' \
    > "$NEWS_TRUNC_FEED"
news_feed_run
[[ -f "$NEWS_TRUNC_FILE" ]] \
  && pass "news file written despite an invalid UTF-8 byte" \
  || fail "no news file: the invalid byte killed the run"
jq '.' "$NEWS_TRUNC_FILE" > /dev/null 2>&1 \
  && pass "news JSON is valid despite an invalid UTF-8 byte" \
  || fail "news JSON invalid: $(tail -c 120 "$NEWS_TRUNC_FILE" 2>/dev/null)"
NEWS_TRUNC_REPL=$(printf '\357\277\275')
[[ "$(news_trunc_desc)" == "before${NEWS_TRUNC_REPL}after" ]] \
  && pass "the invalid byte becomes U+FFFD" \
  || fail "invalid byte handling wrong: [$(news_trunc_desc)]"

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
section "30g. _conductor_session_name (shared truncate helper)"
# ============================================================

# 24文字以内の名前はそのまま返る
SN=$(zsh -c "source '$INIT_FILE' && _conductor_session_name 'my-project'" 2>/dev/null) || SN=""
[[ "$SN" == "my-project" ]] && pass "short name passes through unchanged" || fail "short name changed: $SN"

# ちょうど24文字は境界値としてそのまま返る
NAME24="abcdefghij-abcdefghij-ab"
SN=$(zsh -c "source '$INIT_FILE' && _conductor_session_name '$NAME24'" 2>/dev/null) || SN=""
[[ "$SN" == "$NAME24" ]] && pass "24-char name passes through unchanged" || fail "24-char name changed: $SN"

# 24文字超は24文字以内に切り詰められ、決定的（同入力なら同出力）
LONG_NAME="this-is-a-very-long-session-name"
SN1=$(zsh -c "source '$INIT_FILE' && _conductor_session_name '$LONG_NAME'" 2>/dev/null) || SN1=""
SN2=$(zsh -c "source '$INIT_FILE' && _conductor_session_name '$LONG_NAME'" 2>/dev/null) || SN2=""
[[ "${#SN1}" -le 24 && -n "$SN1" ]] && pass "long name truncated to <=24 chars ($SN1)" || fail "not truncated: '$SN1' (${#SN1} chars)"
[[ "$SN1" == "$SN2" ]] && pass "truncation is deterministic" || fail "non-deterministic: $SN1 vs $SN2"

# 同名でもハッシュ源（第2引数）が異なれば別のセッション名になる
SN_A=$(zsh -c "source '$INIT_FILE' && _conductor_session_name '$LONG_NAME' '/path/alpha'" 2>/dev/null) || SN_A=""
SN_B=$(zsh -c "source '$INIT_FILE' && _conductor_session_name '$LONG_NAME' '/path/beta'" 2>/dev/null) || SN_B=""
[[ -n "$SN_A" && "$SN_A" != "$SN_B" ]] \
  && pass "distinct hash sources yield distinct names ($SN_A / $SN_B)" \
  || fail "hash-source collision: '$SN_A' vs '$SN_B'"

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
section "37b. dashboard-loop.sh (jump clears only lifecycle-less pendings)"
# ============================================================

# ジャンプでクリアするのは「hooksもscreen検出も持たないagent」のみ。
# claudeはhooksが、screen方式agent（codex）はscreen検出がライフサイクルを
# 持つため、ジャンプでは消さない（消しても次ポーリングで再生成されるだけ）。
JC_DIR="$HOME/.claude-pending/jump-session"
mkdir -p "$JC_DIR"
echo '{"tab":"somecli-task","session":"jump-session","message":"turn done","event":"Stop","time":"10:00:00","agent":"somecli"}' > "$JC_DIR/sc.json"
echo '{"tab":"codex-task","session":"jump-session","message":"turn done","event":"Stop","time":"10:00:30","agent":"codex"}' > "$JC_DIR/cx.json"
echo '{"tab":"claude-task","session":"jump-session","message":"done","event":"Stop","time":"10:01:00","agent":"claude"}' > "$JC_DIR/cl.json"

: > "$HOME/.claude-pending/zellij-calls.log"
( printf '1'; sleep 3 ) | MOCK_TABS="somecli-task codex-task claude-task" ZELLIJ_SESSION_NAME=jump-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" >/dev/null 2>&1 &
JC_PID=$!
sleep 2
kill "$JC_PID" 2>/dev/null || true
wait "$JC_PID" 2>/dev/null || true

grep -q 'action go-to-tab-name somecli-task' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "jump goes to selected tab" || fail "jump did not switch tab"
[[ ! -f "$JC_DIR/sc.json" ]] && pass "hook-less non-screen pending cleared on jump" || fail "somecli pending not cleared"
[[ -f "$JC_DIR/cl.json" ]] && pass "claude pending untouched by jump" || fail "claude pending removed unexpectedly"

# screen方式agent（codex, detection=screen）のエントリはジャンプで消さない
( printf '1'; sleep 3 ) | MOCK_TABS="codex-task claude-task" ZELLIJ_SESSION_NAME=jump-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" >/dev/null 2>&1 &
JC_PID=$!
sleep 2
kill "$JC_PID" 2>/dev/null || true
wait "$JC_PID" 2>/dev/null || true
grep -q 'action go-to-tab-name codex-task' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "jump goes to codex tab" || fail "jump did not switch to codex tab"
[[ -f "$JC_DIR/cx.json" ]] && pass "screen-agent pending kept on jump" || fail "codex pending cleared on jump"
rm -f "$JC_DIR/cx.json"

# Jumping to a claude task keeps its entry (hooks own the lifecycle)
( printf '1'; sleep 3 ) | MOCK_TABS="claude-task" ZELLIJ_SESSION_NAME=jump-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" >/dev/null 2>&1 &
JC_PID=$!
sleep 2
kill "$JC_PID" 2>/dev/null || true
wait "$JC_PID" 2>/dev/null || true
grep -q 'action go-to-tab-name claude-task' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "jump goes to claude tab" || fail "jump did not switch to claude tab"
[[ -f "$JC_DIR/cl.json" ]] && pass "claude pending kept on jump" || fail "claude pending cleared on jump"

# An entry without an agent field (older claude pending) is treated as claude
echo '{"tab":"old-task","session":"jump-session","message":"done","event":"Stop","time":"10:02:00"}' > "$JC_DIR/old.json"
( printf '1'; sleep 3 ) | MOCK_TABS="old-task" ZELLIJ_SESSION_NAME=jump-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" >/dev/null 2>&1 &
JC_PID=$!
sleep 2
kill "$JC_PID" 2>/dev/null || true
wait "$JC_PID" 2>/dev/null || true
[[ -f "$JC_DIR/old.json" ]] && pass "agent-less pending treated as claude" || fail "agent-less pending cleared"
rm -rf "$JC_DIR"

# ============================================================
section "37c. dashboard-loop.sh (screen detection in the poll)"
# ============================================================

# screen方式agentのタブはポーリング内で dump-screen され、承認待ちが
# そのままpending一覧に載る（issue #28）。ONCE経路でも検出が走ること
SD_DIR="$HOME/.claude-pending/sd-session"
rm -rf "$SD_DIR"
mkdir -p "$SD_DIR"
SD_PANES='[
  {"id":0,"is_plugin":true,"tab_name":"codex-scr","title":"tab-bar"},
  {"id":5,"is_plugin":false,"tab_name":"codex-scr","terminal_command":"env TASK_TAB_NAME=codex-scr TASK_TYPE=dev TASK_AGENT=codex codex","title":"codex"}
]'
mkdir -p "$SDL_FIX/dash"
cp "$SDL_FIX/blocked-command.txt" "$SDL_FIX/dash/terminal_5.txt"

SD_OUT=$(CONDUCTOR_DASHBOARD_ONCE=1 MOCK_TABS="codex-scr" MOCK_PANES_JSON="$SD_PANES" \
    MOCK_SCREEN_DIR="$SDL_FIX/dash" ZELLIJ_SESSION_NAME=sd-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" 2>/dev/null)

SD_SLUG=$( source "$SDL" && _screen_tab_slug "codex-scr" )
[[ -f "$SD_DIR/screen-$SD_SLUG.json" ]] && pass "poll writes screen Notification pending" || fail "screen pending not created by poll"
echo "$SD_OUT" | grep -q "codex-scr" && pass "screen-detected approval listed in dashboard" || fail "approval not listed: $SD_OUT"
echo "$SD_OUT" | grep -q "Would you like to run the following command?" \
  && pass "dashboard shows the matched approval line" || fail "approval message missing"

# workingに戻ればポーリングがpendingを消し、Mainへ自動復帰する
cp "$SDL_FIX/working.txt" "$SDL_FIX/dash/terminal_5.txt"
: > "$HOME/.claude-pending/zellij-calls.log"
SD_OUT=$(CONDUCTOR_DASHBOARD_ONCE=1 MOCK_TABS="codex-scr" MOCK_PANES_JSON="$SD_PANES" \
    MOCK_SCREEN_DIR="$SDL_FIX/dash" ZELLIJ_SESSION_NAME=sd-session \
    bash "$HOME/.claude-conductor/scripts/dashboard-loop.sh" 2>/dev/null)
[[ ! -f "$SD_DIR/screen-$SD_SLUG.json" ]] && pass "poll clears pending when agent works again" || fail "pending survived working"
echo "$SD_OUT" | grep -q "All tasks running" && pass "dashboard back to all-running" || fail "dashboard still lists task"
grep -q 'go-to-tab-name Main' "$HOME/.claude-pending/zellij-calls.log" \
  && pass "poll auto-returns to Main when turn resumes" || fail "no auto-return in poll"
rm -rf "$SD_DIR"

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
section "42b. upload-log.sh generate_summary (codex rollout)"
# ============================================================

# codex の rollout は .type=="user"/"assistant" を持たないため、claude 形式の
# 抽出では会話が空になり dd が必ず中止されていた。要約へ渡される会話テキストを
# 確認するため、claude モックには stdin をそのまま吐かせる。
cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
echo "SUMMARY-OF:"
cat
MOCK
chmod +x "$MOCK_BIN/claude"

CXS_ROLLOUT="$SANDBOX/codex-summary-rollout.jsonl"
cat > "$CXS_ROLLOUT" << 'ROLLOUT'
{"timestamp":"2026-08-10T10:00:00.000Z","type":"session_meta","payload":{"id":"thread-cxs","cwd":"/tmp/myapp","cli_version":"0.147.0","source":"exec"}}
{"timestamp":"2026-08-10T10:00:00.100Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","approval_policy":"never"}}
{"timestamp":"2026-08-10T10:00:00.200Z","type":"response_item","payload":{"type":"message","id":"m0","role":"developer","content":[{"type":"input_text","text":"DEVELOPERPROMPTMARKER system instructions"}]}}
{"timestamp":"2026-08-10T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"timestamp":"2026-08-10T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"CODEXUSERMARKER fix the bug","images":[],"text_elements":[]}}
{"timestamp":"2026-08-10T10:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"CODEXAGENTMARKER fixed and pushed","phase":"final_answer","memory_citation":null}}
{"timestamp":"2026-08-10T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}
{"timestamp":"2026-08-10T10:00:05.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"CODEXAGENTMARKER fixed and pushed","turn_id":"t1"}}
ROLLOUT

if CXS=$(run_summary "$CXS_ROLLOUT"); then
    echo "$CXS" | grep -q "CODEXUSERMARKER" \
        && pass "codex user_message extracted" || fail "codex user text missing: $CXS"
    echo "$CXS" | grep -q "CODEXAGENTMARKER" \
        && pass "codex agent_message extracted" || fail "codex agent text missing: $CXS"
    ! echo "$CXS" | grep -q "DEVELOPERPROMPTMARKER" \
        && pass "codex developer prompt excluded" || fail "developer prompt leaked: $CXS"
else
    fail "generate_summary failed on a codex rollout"
fi

# claude 形式は従来どおり抽出できる（回帰確認）
if CLS=$(run_summary "$MOCK_TRANSCRIPT"); then
    echo "$CLS" | grep -q "fix the bug" \
        && pass "claude transcript still extracted" || fail "claude text missing: $CLS"
else
    fail "generate_summary failed on a claude transcript"
fi

# codex の secrets も要約前にマスクされる
CXS_SECRET="$SANDBOX/codex-secret-rollout.jsonl"
cat > "$CXS_SECRET" << 'ROLLOUT'
{"timestamp":"2026-08-10T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"token ghp_abcdefghijklmnopqrstuvwxyz0123456789 here"}}
ROLLOUT
if CXSEC=$(run_summary "$CXS_SECRET"); then
    ! echo "$CXSEC" | grep -q "ghp_abcdef" \
        && pass "codex conversation is secret-filtered" || fail "codex secret leaked: $CXSEC"
else
    fail "generate_summary failed on the codex secret rollout"
fi

# どちらの形式でもない jsonl は会話が取れないので従来どおり失敗する
CXS_BROKEN="$SANDBOX/broken-transcript.jsonl"
cat > "$CXS_BROKEN" << 'BROKEN'
{"timestamp":"2026-08-10T10:00:00.000Z","type":"session_meta","payload":{"id":"x"}}
{"timestamp":"2026-08-10T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}
BROKEN
if run_summary "$CXS_BROKEN" >/dev/null 2>&1; then
    fail "generate_summary should fail on an unrecognised transcript"
else
    pass "generate_summary fails on an unrecognised transcript"
fi

# 新形式(item_completed)の rollout からも会話が抽出できること。
# ここでは 26i1b の fixture をそのまま一次情報として使う。
if CXV2S=$(run_summary "$CXV2_TRANSCRIPT"); then
    echo "$CXV2S" | grep -q "V2USERMARKER" \
        && pass "v2 UserMessage item extracted" || fail "v2 user text missing: $CXV2S"
    echo "$CXV2S" | grep -q "V2AGENTMARKER" \
        && pass "v2 AgentMessage item extracted" || fail "v2 agent text missing: $CXV2S"
    ! echo "$CXV2S" | grep -q "V2REASONMARKER" \
        && pass "v2 Reasoning item excluded from the conversation" || fail "reasoning leaked: $CXV2S"
else
    fail "generate_summary failed on a v2 codex rollout"
fi

# content 要素の形が揺れても、読める分だけ拾って要約は続行する（dd を止めない）。
# 素の文字列要素、.text を持たない要素が混ざっても落ちないこと。
CXV2L_TRANSCRIPT="$SANDBOX/codex-rollout-v2-lenient.jsonl"
cat > "$CXV2L_TRANSCRIPT" << 'ROLLOUT'
{"timestamp":"2026-08-10T18:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":["LENIENTSTRINGMARKER bare string element"]}}}
{"timestamp":"2026-08-10T18:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Image","url":"https://example.com/x.png"},{"type":"Text","text":"LENIENTTEXTMARKER done"}]}}}
ROLLOUT
if CXV2L=$(run_summary "$CXV2L_TRANSCRIPT"); then
    echo "$CXV2L" | grep -q "LENIENTSTRINGMARKER" \
        && pass "bare string content elements are accepted" || fail "string element dropped: $CXV2L"
    echo "$CXV2L" | grep -q "LENIENTTEXTMARKER" \
        && pass "unknown content elements degrade instead of aborting" || fail "text lost beside unknown element: $CXV2L"
else
    fail "generate_summary failed on an odd v2 content shape"
fi

# codex-rollout-lib.sh が無い環境（部分的な更新など）でも claude transcript の
# 要約は動き、codex 側だけが安全に失敗する。ここが壊れると全 dd が止まる。
NOLIB_HOME="$SANDBOX/nolib-conductor"
mkdir -p "$NOLIB_HOME/scripts"
if NOLIB_SUM=$(CONDUCTOR_HOME="$NOLIB_HOME" bash -c "UPLOAD_LOG_LIB=1 source '$UPLOAD_SCRIPT'; generate_summary '$MOCK_TRANSCRIPT'" 2>/dev/null); then
    echo "$NOLIB_SUM" | grep -q "fix the bug" \
        && pass "claude summary works without codex-rollout-lib.sh" || fail "claude summary broken without the lib: $NOLIB_SUM"
else
    fail "generate_summary failed on a claude transcript without the lib"
fi
if CONDUCTOR_HOME="$NOLIB_HOME" bash -c "UPLOAD_LOG_LIB=1 source '$UPLOAD_SCRIPT'; generate_summary '$CXV2_TRANSCRIPT'" >/dev/null 2>&1; then
    fail "codex summary should fail safely without the lib"
else
    pass "codex summary fails safely without the lib"
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

# record-output.sh stamps completed_at with the current time, and the log path
# is derived from it — so the expected date is today, captured here (not a
# hardcoded date, which would break on every day after the test was written).
E2E_DATE=$(date '+%Y/%m/%d')
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
    grep -q "$E2E_DATE" <<< "$LOGFILE" && pass "log stored under YYYY/MM/DD" || fail "wrong date path: $LOGFILE (expected $E2E_DATE)"
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
[[ "$(slug 'git@github.com:torvalds/torvalds.git')" == "torvalds/torvalds" ]] \
    && pass "repo_slug allows owner == repo" || fail "same-name slug wrong: $(slug 'git@github.com:torvalds/torvalds.git')"
set +e
( source "$UPDATE_LIB"; uc_repo_slug "" ) >/dev/null 2>&1; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "repo_slug empty url returns non-zero" || fail "empty url did not fail"
set +e
( source "$UPDATE_LIB"; uc_repo_slug "notaurl" ) >/dev/null 2>&1; RC=$?
set -e
[[ $RC -ne 0 ]] && pass "repo_slug rejects url without a path" || fail "bare string did not fail"

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
section "54. mdev dispatch (update subcommand + startup check)"
# ============================================================

# Stub update.sh and check-update.sh with markers so we can observe which one
# mdev() invokes without running the real flows.
mv "$CONDUCTOR_HOME/scripts/update.sh" "$CONDUCTOR_HOME/scripts/update.sh.real"
mv "$CONDUCTOR_HOME/scripts/check-update.sh" "$CONDUCTOR_HOME/scripts/check-update.sh.real"
printf '#!/bin/bash\necho called > "%s/mdev-update-marker"\n' "$SANDBOX" > "$CONDUCTOR_HOME/scripts/update.sh"
printf '#!/bin/bash\necho called > "%s/mdev-check-marker"\n' "$SANDBOX" > "$CONDUCTOR_HOME/scripts/check-update.sh"
chmod +x "$CONDUCTOR_HOME/scripts/update.sh" "$CONDUCTOR_HOME/scripts/check-update.sh"

# `mdev update` runs the updater and does NOT start a session / startup check
rm -f "$SANDBOX/mdev-update-marker" "$SANDBOX/mdev-check-marker"
zsh -c "source '$CONDUCTOR_HOME/init.zsh' && mdev update" >/dev/null 2>&1
[[ -f "$SANDBOX/mdev-update-marker" ]] && pass "mdev update dispatches to update.sh" || fail "mdev update did not call update.sh"
[[ ! -f "$SANDBOX/mdev-check-marker" ]] && pass "mdev update skips startup check" || fail "mdev update ran startup check"

# A normal `mdev <name>` runs the startup update check (and not the updater)
rm -f "$SANDBOX/mdev-update-marker" "$SANDBOX/mdev-check-marker"
zsh -c "source '$CONDUCTOR_HOME/init.zsh' && mdev testsess" >/dev/null 2>&1
[[ -f "$SANDBOX/mdev-check-marker" ]] && pass "mdev runs startup update check" || fail "mdev did not run check-update.sh"
[[ ! -f "$SANDBOX/mdev-update-marker" ]] && pass "normal mdev does not run updater" || fail "normal mdev ran updater"

# Restore the real scripts
mv "$CONDUCTOR_HOME/scripts/update.sh.real" "$CONDUCTOR_HOME/scripts/update.sh"
mv "$CONDUCTOR_HOME/scripts/check-update.sh.real" "$CONDUCTOR_HOME/scripts/check-update.sh"

# ============================================================
section "54b. mdev attach-or-create (issue #37)"
# ============================================================

# Section 45 replaced the mock zellij with a list-tabs-only variant; rebuild
# one that logs calls and serves `list-sessions` from MOCK_SESSIONS_OUTPUT.
cat > "$MOCK_BIN/zellij" << 'MOCK'
#!/bin/bash
echo "mock-zellij: $*" >> "$HOME/.claude-pending/zellij-calls.log"
if [[ "$1" == "list-sessions" && -n "$MOCK_SESSIONS_OUTPUT" ]]; then
    printf '%s\n' "$MOCK_SESSIONS_OUTPUT"
fi
MOCK
chmod +x "$MOCK_BIN/zellij"

# Stub startup helpers so mdev runs without network / real update flows.
mv "$CONDUCTOR_HOME/scripts/fetch-news.sh" "$CONDUCTOR_HOME/scripts/fetch-news.sh.real"
mv "$CONDUCTOR_HOME/scripts/check-update.sh" "$CONDUCTOR_HOME/scripts/check-update.sh.real"
printf '#!/bin/bash\nexit 0\n' > "$CONDUCTOR_HOME/scripts/fetch-news.sh"
printf '#!/bin/bash\nexit 0\n' > "$CONDUCTOR_HOME/scripts/check-update.sh"
chmod +x "$CONDUCTOR_HOME/scripts/fetch-news.sh" "$CONDUCTOR_HOME/scripts/check-update.sh"

mkdir -p "$HOME/.claude-pending"
ZLOG="$HOME/.claude-pending/zellij-calls.log"
MDEV_WORKDIR="$SANDBOX/proj/myapp"
mkdir -p "$MDEV_WORKDIR"

# 引数なし・セッション不在: ディレクトリ名のみ（タイムスタンプなし）で新規作成
: > "$ZLOG"
zsh -c "cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
grep -q "new-session-with-layout .* --session myapp$" "$ZLOG" \
  && pass "absent session: creates with plain dirname (no timestamp)" \
  || fail "wrong create call: $(cat "$ZLOG")"
grep -q "mock-zellij: attach" "$ZLOG" \
  && fail "absent session: unexpected attach" || pass "absent session: no attach attempted"

# 生存セッションあり: attachし、新規作成しない
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp [Created 1h 2m 3s ago] '; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
grep -q "mock-zellij: attach myapp$" "$ZLOG" \
  && pass "alive session: attaches to it" || fail "no attach call: $(cat "$ZLOG")"
grep -q "new-session-with-layout" "$ZLOG" \
  && fail "alive session: unexpected new-session" || pass "alive session: no new session created"

# EXITEDセッション: 削除してから新規作成（復元は#36のレジストリが担当）
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp [Created 5h ago] (EXITED - attach to resurrect)'; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
grep -q "mock-zellij: delete-session myapp --force" "$ZLOG" \
  && pass "exited session: deleted before recreation" || fail "no delete-session call: $(cat "$ZLOG")"
grep -q "new-session-with-layout .* --session myapp$" "$ZLOG" \
  && pass "exited session: recreated with same name" || fail "no create call: $(cat "$ZLOG")"
grep -q "mock-zellij: attach" "$ZLOG" \
  && fail "exited session: unexpected attach (would resurrect stale layout)" \
  || pass "exited session: zellij resurrection not used"

# 前方一致の別セッションは誤マッチしない（myapp-2 が生きていても myapp は不在扱い）
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp-2 [Created 1h ago] '; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
grep -q "new-session-with-layout .* --session myapp$" "$ZLOG" \
  && pass "prefix-sharing session does not false-match" || fail "prefix false-match: $(cat "$ZLOG")"

# --new: 生存セッションがあってもタイムスタンプ付き名で新規作成
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp [Created 1h ago] '; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev --new" >/dev/null 2>&1
grep -Eq "new-session-with-layout .* --session myapp-[0-9]{6}$" "$ZLOG" \
  && pass "--new forces a fresh timestamped session" || fail "--new wrong call: $(cat "$ZLOG")"
grep -q "mock-zellij: attach" "$ZLOG" \
  && fail "--new: unexpected attach" || pass "--new: does not attach"

# 明示名指定: その名前で attach-or-create が働く
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='customsess [Created 1h ago] '; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev customsess" >/dev/null 2>&1
grep -q "mock-zellij: attach customsess$" "$ZLOG" \
  && pass "explicit name: attaches when alive" || fail "explicit name did not attach: $(cat "$ZLOG")"

# 24文字超のディレクトリ名は truncate される
LONG_DIR="$SANDBOX/proj/this-is-a-really-long-project-dir"
mkdir -p "$LONG_DIR"
: > "$ZLOG"
zsh -c "cd '$LONG_DIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
MDEV_SESS=$(grep -o -- '--session [^ ]*$' "$ZLOG" | head -1 | cut -d' ' -f2)
[[ -n "$MDEV_SESS" && "${#MDEV_SESS}" -le 24 ]] \
  && pass "long dirname truncated to <=24 chars ($MDEV_SESS)" \
  || fail "session name not truncated: '$MDEV_SESS'"

# 長いディレクトリ名でも --new は通常セッション名と衝突しない
# （タイムスタンプがtruncateで落ちても、ハッシュで区別される）
: > "$ZLOG"
zsh -c "cd '$LONG_DIR' && source '$INIT_FILE' && mdev --new" >/dev/null 2>&1
MDEV_NEW_SESS=$(grep -o -- '--session [^ ]*$' "$ZLOG" | head -1 | cut -d' ' -f2)
[[ -n "$MDEV_NEW_SESS" && "${#MDEV_NEW_SESS}" -le 24 && "$MDEV_NEW_SESS" != "$MDEV_SESS" ]] \
  && pass "--new on long dirname yields a distinct session ($MDEV_NEW_SESS)" \
  || fail "--new collided with default session: '$MDEV_NEW_SESS' vs '$MDEV_SESS'"

# EXITED再構築時にそのセッションのstale pendingを掃除する
mkdir -p "$HOME/.claude-pending/myapp"
echo '{"tab":"stale-tab"}' > "$HOME/.claude-pending/myapp/stale-sid.json"
: > "$ZLOG"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp [Created 5h ago] (EXITED - attach to resurrect)'; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
[[ -z "$(ls -A "$HOME/.claude-pending/myapp" 2>/dev/null)" ]] \
  && pass "exited rebuild clears stale pending for the session" \
  || fail "stale pending remains: $(ls "$HOME/.claude-pending/myapp")"

# 生存セッションへのattachではpendingを消さない
mkdir -p "$HOME/.claude-pending/myapp"
echo '{"tab":"live-tab"}' > "$HOME/.claude-pending/myapp/live-sid.json"
zsh -c "export MOCK_SESSIONS_OUTPUT='myapp [Created 1h ago] '; cd '$MDEV_WORKDIR' && source '$INIT_FILE' && mdev" >/dev/null 2>&1
[[ -f "$HOME/.claude-pending/myapp/live-sid.json" ]] \
  && pass "alive attach keeps pending intact" || fail "pending removed on alive attach"
rm -rf "$HOME/.claude-pending/myapp"

# Restore the real scripts
mv "$CONDUCTOR_HOME/scripts/fetch-news.sh.real" "$CONDUCTOR_HOME/scripts/fetch-news.sh"
mv "$CONDUCTOR_HOME/scripts/check-update.sh.real" "$CONDUCTOR_HOME/scripts/check-update.sh"

# ============================================================
section "55. Uninstall"
# ============================================================

# Seed a codex config holding our notify plus user content: uninstall must
# strip only the conductor line.
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" << TOML
notify = ["bash", "$HOME/.claude-conductor/scripts/codex-notify.sh"] # claude-conductor

[projects."/tmp/foo"]
trust_level = "trusted"
TOML

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

# Codex notify removed, user content kept
grep -q 'codex-notify.sh' "$HOME/.codex/config.toml" \
  && fail "codex notify still present after uninstall" || pass "codex notify removed on uninstall"
grep -q 'trust_level = "trusted"' "$HOME/.codex/config.toml" \
  && pass "codex user config preserved on uninstall" || fail "codex user config lost"
