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

# --- Install files ---
echo -e "${BOLD}Installing to ${CONDUCTOR_HOME}...${NC}"

mkdir -p "$CONDUCTOR_HOME/scripts"
mkdir -p "$CONDUCTOR_HOME/layouts"
mkdir -p "$CONDUCTOR_HOME/news"

cp "$REPO_DIR"/scripts/*.sh "$CONDUCTOR_HOME/scripts/"
chmod +x "$CONDUCTOR_HOME/scripts/"*.sh

cp "$REPO_DIR"/layouts/*.kdl "$CONDUCTOR_HOME/layouts/"
cp "$REPO_DIR"/init.zsh "$CONDUCTOR_HOME/init.zsh"
cp "$REPO_DIR"/hooks.json "$CONDUCTOR_HOME/hooks.json"

# config.default.json は常に最新版で上書き
cp "$REPO_DIR"/config.default.json "$CONDUCTOR_HOME/config.default.json"

# config.json はユーザーカスタマイズを保護（初回のみコピー）
if [[ ! -f "$CONDUCTOR_HOME/config.json" ]]; then
    cp "$REPO_DIR"/config.default.json "$CONDUCTOR_HOME/config.json"
fi

echo -e "  ${GREEN}✓${NC} Scripts"
echo -e "  ${GREEN}✓${NC} Layouts"
echo -e "  ${GREEN}✓${NC} Config"
echo -e "  ${GREEN}✓${NC} Shell functions"
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
