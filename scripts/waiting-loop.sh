#!/bin/bash
# Claude Conductor - Waiting Tasks Pane
# Displays tasks waiting on an external response (e.g. PR review).
# These are separated from the Dashboard so they don't crowd active work.

SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"
mkdir -p "$PENDING_DIR"

YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

render() {
    echo -e "${BOLD}  Waiting${NC} ${DIM}[external]${NC}"
    echo -e "${DIM}  ──────────────────────────${NC}"
    echo ""

    local f event tab msg time count=0
    for f in "$PENDING_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        event=$(jq -r '.event' "$f" 2>/dev/null)
        [[ "$event" == "Waiting" ]] || continue

        tab=$(jq -r '.tab' "$f" 2>/dev/null)
        msg=$(jq -r '.message' "$f" 2>/dev/null | head -c 60)
        time=$(jq -r '.time' "$f" 2>/dev/null)

        echo -e "  ${YELLOW}■${NC} ${BOLD}$tab${NC} ${DIM}[$time]${NC}"
        echo -e "      $msg"
        echo ""
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo -e "  ${DIM}No waiting tasks${NC}"
    else
        echo -e "${DIM}  ──────────────────────────${NC}"
        echo -e "  ${BOLD}Waiting: ${count}${NC}"
    fi
}

# Single-pass mode for testing
if [[ "$CONDUCTOR_WAITING_ONCE" == "1" ]]; then
    render
    exit 0
fi

TMPFILE=$(mktemp)
printf '\033[?25l'
trap 'printf "\033[?25h"; rm -f "$TMPFILE"' EXIT
clear

while true; do
    render > "$TMPFILE"

    printf '\033[H'
    cat "$TMPFILE"
    printf '\033[J'

    sleep 2
done
