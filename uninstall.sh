#!/bin/bash
set -e

CONDUCTOR_HOME="$HOME/.claude-conductor"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Claude Conductor - Uninstaller${NC}"
echo ""

# --- Remove hooks from Claude Code settings ---
SETTINGS_FILE="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
    HOOKS_TO_REMOVE='["Notification", "Stop", "PostToolUse", "UserPromptSubmit"]'
    # Remove only hooks that reference claude-conductor scripts
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"
    jq '
      .hooks = (
        .hooks | to_entries
        | map(select(
            .value | tostring | test("claude-conductor") | not
          ))
        | from_entries
      )
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo -e "  ${GREEN}✓${NC} Removed hooks (backup: ${SETTINGS_FILE}.backup)"
fi

# --- Remove Codex notify (only the conductor line) ---
CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
if [[ -f "$CODEX_CONFIG" ]] && grep -q "codex-notify.sh" "$CODEX_CONFIG"; then
    # config.toml が conductor の notify 行だけなら grep -v の出力は空になり
    # rc=1 が返る。set -e のままだとそこで uninstall が止まり、$CONDUCTOR_HOME を
    # 消さずに終わってしまう。「一致なし」の 1 だけを許し、本当のエラー(2 以上)は
    # 従来どおり落とす。
    grep -v "codex-notify.sh" "$CODEX_CONFIG" > "${CODEX_CONFIG}.tmp" || [[ $? -eq 1 ]]
    mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"
    echo -e "  ${GREEN}✓${NC} Removed Codex notify from $CODEX_CONFIG"
fi

# --- Remove files ---
# install.sh は $CONDUCTOR_HOME/bin に触れないが、uninstall は $CONDUCTOR_HOME を
# 丸ごと消すので Go 版バイナリ bin/mdev と FLAVOR も一緒に消える。
if [[ -d "$CONDUCTOR_HOME" ]]; then
    GO_FLAVOR_NOTE=""
    if [[ -e "$CONDUCTOR_HOME/bin/mdev" || -e "$CONDUCTOR_HOME/FLAVOR" ]]; then
        GO_FLAVOR_NOTE=" (including bin/ and FLAVOR)"
    fi
    if [[ -e "$CONDUCTOR_HOME/bin/mdev" ]]; then
        echo -e "  ${YELLOW}!${NC} bin/mdev (Go flavor) is inside $CONDUCTOR_HOME and will be removed too"
    fi
    rm -rf "$CONDUCTOR_HOME"
    echo -e "  ${GREEN}✓${NC} Removed ${CONDUCTOR_HOME}${GO_FLAVOR_NOTE}"
fi

# --- Remove pending data ---
if [[ -d "$HOME/.claude-pending" ]]; then
    rm -rf "$HOME/.claude-pending"
    echo -e "  ${GREEN}✓${NC} Removed ~/.claude-pending"
fi

echo ""
echo -e "${BOLD}Remove this line from your .zshrc:${NC}"
echo '  source "$HOME/.claude-conductor/init.zsh"'
echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
