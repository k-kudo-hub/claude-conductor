#!/bin/bash
set -e

CONDUCTOR_HOME="$HOME/.claude-conductor"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Claude Conductor - Installer${NC}"
echo ""

# --- Check dependencies ---
echo -e "${BOLD}Checking dependencies...${NC}"
missing=()
for cmd in zellij jq fzf claude; do
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $cmd"
    else
        echo -e "  ${RED}✗${NC} $cmd"
        missing+=("$cmd")
    fi
done

# terminal-notifier is optional (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
    if command -v terminal-notifier &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} terminal-notifier"
    else
        echo -e "  ${YELLOW}?${NC} terminal-notifier (optional, for macOS notifications)"
    fi
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Missing required dependencies: ${missing[*]}${NC}"
    echo "Install them and try again."
    exit 1
fi

echo ""

# --- Flavor ---
# $CONDUCTOR_HOME/FLAVOR に "go" と書かれていれば Go 版 (mdev-go) を採用する。
# ファイルが無い / 中身が "go" 以外なら従来どおり Shell 版 (scripts/*-loop.sh)。
# install.sh も `mdev update` も layouts と hooks を無条件に上書きするため、
# このフラグが無いと Go 版へ寄せた設定が再実行のたびに黙って巻き戻る。
CONDUCTOR_FLAVOR=""
if [[ -f "$CONDUCTOR_HOME/FLAVOR" ]]; then
    CONDUCTOR_FLAVOR=$(head -n 1 "$CONDUCTOR_HOME/FLAVOR" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
fi

# --- Install files ---
echo -e "${BOLD}Installing to ${CONDUCTOR_HOME}...${NC}"

mkdir -p "$CONDUCTOR_HOME/scripts"
mkdir -p "$CONDUCTOR_HOME/layouts"
mkdir -p "$CONDUCTOR_HOME/news"

# 注: $CONDUCTOR_HOME/bin には一切触れない。Go 版のバイナリ bin/mdev は
# この repo の管理外（mdev-go 側で配置する）であり、install.sh を何度
# 実行しても消したり上書きしたりしない。
cp "$REPO_DIR"/scripts/*.sh "$CONDUCTOR_HOME/scripts/"
chmod +x "$CONDUCTOR_HOME/scripts/"*.sh

cp "$REPO_DIR"/layouts/*.kdl "$CONDUCTOR_HOME/layouts/"
cp "$REPO_DIR"/init.zsh "$CONDUCTOR_HOME/init.zsh"
cp "$REPO_DIR"/hooks.json "$CONDUCTOR_HOME/hooks.json"

# FLAVOR=go: レイアウトの 5 ペインを Go 版の `bin/mdev pane <name>` へ向け直す。
# ${CONDUCTOR_HOME:-$HOME/.claude-conductor} のプレフィックスは維持する。
if [[ "$CONDUCTOR_FLAVOR" == "go" ]]; then
    sed -e 's|/scripts/dashboard-loop\.sh|/bin/mdev pane dashboard|' \
        -e 's|/scripts/waiting-loop\.sh|/bin/mdev pane waiting|' \
        -e 's|/scripts/done-loop\.sh|/bin/mdev pane done|' \
        -e 's|/scripts/news-loop\.sh|/bin/mdev pane news|' \
        -e 's|/scripts/task-create-loop\.sh|/bin/mdev pane task-create|' \
        "$CONDUCTOR_HOME/layouts/multi.kdl" > "$CONDUCTOR_HOME/layouts/multi.kdl.tmp" \
        && mv "$CONDUCTOR_HOME/layouts/multi.kdl.tmp" "$CONDUCTOR_HOME/layouts/multi.kdl"
fi

# バージョンと更新元URLを記録する。
# tarball からの更新など .git が無い文脈では update.sh が
# CONDUCTOR_VERSION / CONDUCTOR_REPO_URL を渡して正しい値を注入する。
VERSION="${CONDUCTOR_VERSION:-$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")}"
echo "$VERSION" > "$CONDUCTOR_HOME/VERSION"

REPO_URL="${CONDUCTOR_REPO_URL:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")}"
echo "$REPO_URL" > "$CONDUCTOR_HOME/REPO_URL"

# config.default.json は常に最新版で上書き
cp "$REPO_DIR"/config.default.json "$CONDUCTOR_HOME/config.default.json"

# config.json はユーザーカスタマイズを保護（初回のみコピー）
if [[ ! -f "$CONDUCTOR_HOME/config.json" ]]; then
    cp "$REPO_DIR"/config.default.json "$CONDUCTOR_HOME/config.json"
else
    # 後から追加されたエージェント項目（detection / patterns, issue #28）を
    # 既存configへ補完する。無いとスクリーン検出が無言で無効のままになる。
    # ユーザーが設定済みの値は一切上書きしない（デフォルトは不足キーのみ埋める）。
    # patterns はオブジェクト丸ごとではなくキー単位で合成する。丸ごとだと
    # patterns を一度でも触ったユーザーには後から追加された状態（neutral 等）が
    # 永久に届かず、検出ルールの更新が止まる。ただし空オブジェクトは
    # 「検出を止める」という明示の意思表示なので、そのまま残す。
    jq --slurpfile DEF "$CONDUCTOR_HOME/config.default.json" '
        if .agents then
            .agents |= with_entries(
                . as $e
                | .value = (((($DEF[0].agents[$e.key] // {})
                              | {detection, patterns}
                              | with_entries(select(.value != null)))
                             + $e.value)
                            | if (.patterns | type) == "object" and (.patterns | length) > 0
                              then .patterns = ((($DEF[0].agents[$e.key].patterns) // {}) + .patterns)
                              else . end))
        else . end' \
        "$CONDUCTOR_HOME/config.json" > "$CONDUCTOR_HOME/config.json.tmp" \
        && mv "$CONDUCTOR_HOME/config.json.tmp" "$CONDUCTOR_HOME/config.json" \
        || {
            # config.json が壊れている / patterns がオブジェクト以外、など。
            # 既存configはそのまま残すが、黙って落とすと補完されていないことに
            # 気付けないので必ず知らせる。
            rm -f "$CONDUCTOR_HOME/config.json.tmp"
            echo -e "  ${YELLOW}!${NC} config.json のマージをスキップしました（既存設定はそのままです）"
        }
fi

echo -e "  ${GREEN}✓${NC} Scripts"
echo -e "  ${GREEN}✓${NC} Layouts"
echo -e "  ${GREEN}✓${NC} Config"
echo -e "  ${GREEN}✓${NC} Shell functions"
if [[ "$CONDUCTOR_FLAVOR" == "go" ]]; then
    echo -e "  ${GREEN}✓${NC} Flavor: go (layouts point at bin/mdev pane)"
fi
echo ""

# --- Configure Claude Code hooks ---
echo -e "${BOLD}Configuring Claude Code hooks...${NC}"

SETTINGS_FILE="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
    # Merge hooks into existing settings.json
    EXISTING=$(cat "$SETTINGS_FILE")
    CONDUCTOR_HOOKS=$(cat "$CONDUCTOR_HOME/hooks.json")

    echo "$EXISTING" | jq --argjson hooks "$CONDUCTOR_HOOKS" '.hooks = (.hooks // {}) + $hooks' > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} Hooks merged into $SETTINGS_FILE"
else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    jq -n --argjson hooks "$(cat "$CONDUCTOR_HOME/hooks.json")" '{"hooks": $hooks}' > "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} Created $SETTINGS_FILE"
fi

# FLAVOR=go: 上のマージは hooks をイベント名単位で丸ごと置き換えるので、
# Go 版へ切り替えてあった hooks が Shell 版へ戻る。切り替えロジックは
# mdev 側（mdev-go）に検証済みのものが在るため、ここで再実装せず
# `mdev hooks switch` を呼ぶ。このコマンドは冪等で、既に Go 版なら何もしない。
if [[ "$CONDUCTOR_FLAVOR" == "go" ]]; then
    if [[ -x "$CONDUCTOR_HOME/bin/mdev" ]]; then
        if "$CONDUCTOR_HOME/bin/mdev" hooks switch >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Hooks switched to the go flavor (mdev hooks switch)"
        else
            echo -e "  ${YELLOW}!${NC} mdev hooks switch failed; hooks stay on the shell flavor"
        fi
    else
        # Go 版バイナリが未設置でも install 自体は成功させる。hooks は Shell 版の
        # まま残るので、そのままでも Conductor は動く。
        echo -e "  ${YELLOW}!${NC} FLAVOR=go but $CONDUCTOR_HOME/bin/mdev is missing or not executable;"
        echo -e "    hooks stay on the shell flavor. Install the Go binary and re-run."
    fi
fi
echo ""

# --- Configure Codex notify (optional) ---
# codex reads `notify` from the user-global config only (project-local notify
# is ignored). codex-notify.sh bridges agent-turn-complete events into the
# conductor pending files, which is what makes Dashboard / Waiting / Done work
# for codex tasks. The key must sit ABOVE any [table] header: TOML would
# otherwise attach it to that table and codex would ignore it.
echo -e "${BOLD}Configuring Codex notify...${NC}"
if command -v codex &>/dev/null; then
    CODEX_CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
    CODEX_CONFIG="$CODEX_CONFIG_DIR/config.toml"
    NOTIFY_LINE="notify = [\"bash\", \"$CONDUCTOR_HOME/scripts/codex-notify.sh\"] # claude-conductor"
    if [[ -f "$CODEX_CONFIG" ]] && grep -q "codex-notify.sh" "$CODEX_CONFIG"; then
        echo -e "  ${GREEN}✓${NC} Codex notify already configured"
    elif [[ -f "$CODEX_CONFIG" ]] && grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG"; then
        echo -e "  ${YELLOW}?${NC} $CODEX_CONFIG already sets notify (another tool); left untouched."
        echo -e "    To bridge codex tasks into the dashboard, have your notify program"
        echo -e "    also invoke: $CONDUCTOR_HOME/scripts/codex-notify.sh '<payload-json>'"
    else
        mkdir -p "$CODEX_CONFIG_DIR"
        if [[ -f "$CODEX_CONFIG" ]]; then
            printf '%s\n\n' "$NOTIFY_LINE" | cat - "$CODEX_CONFIG" > "${CODEX_CONFIG}.tmp"
            mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"
        else
            printf '%s\n' "$NOTIFY_LINE" > "$CODEX_CONFIG"
        fi
        echo -e "  ${GREEN}✓${NC} Codex notify added to $CODEX_CONFIG"
    fi
else
    echo -e "  ${YELLOW}?${NC} codex not found; skipping (optional)"
fi
echo ""

# --- Shell setup ---
INIT_LINE='source "$HOME/.claude-conductor/init.zsh"'

if grep -qF "claude-conductor/init.zsh" "$HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Shell already configured in .zshrc"
else
    echo -e "${BOLD}Add this line to your .zshrc:${NC}"
    echo ""
    echo -e "  ${YELLOW}${INIT_LINE}${NC}"
    echo ""
    read -p "Add automatically? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "" >> "$HOME/.zshrc"
        echo "# Claude Conductor" >> "$HOME/.zshrc"
        echo "$INIT_LINE" >> "$HOME/.zshrc"
        echo -e "  ${GREEN}✓${NC} Added to .zshrc"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo "Usage:"
echo "  mdev          Start a multi-task dashboard session"
echo "  dev           Start a single dev session"
echo ""
echo "In the dashboard, press [n] to create a new task."
echo ""
echo "Restart your shell or run: source ~/.zshrc"
