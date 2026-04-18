#!/bin/bash
set -e

CONDUCTOR_HOME="$HOME/.claude-conductor"

RED='\033[0;31m'
GREEN='\033[0;32m'
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

# --- Remove files ---
if [[ -d "$CONDUCTOR_HOME" ]]; then
    rm -rf "$CONDUCTOR_HOME"
    echo -e "  ${GREEN}✓${NC} Removed $CONDUCTOR_HOME"
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
