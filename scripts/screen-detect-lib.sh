#!/bin/bash
# Claude Conductor - Screen Detection Library (issue #28)
# State detection for agents without lifecycle hooks (config
# .agents.<name>.detection == "screen"). The dashboard poll calls
# screen_detect_tick, which snapshots each screen-agent pane via
# `zellij action dump-screen` and matches the agent's configured patterns:
#
#   blocked  (known approval prompt)  -> Notification pending
#   working  (turn in progress)       -> the tab's pendings are cleared
#   idle     (anything else)          -> Stop pending, only after working
#
# Unknown dialogs deliberately fall back to idle (herdr's strictness): only
# a known approval prompt may surface as blocked, so a new UI screen never
# spams the dashboard with false approvals.
# Sourced by dashboard-loop.sh; defines functions only.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
# shellcheck source=scripts/task-lib.sh
. "$CONDUCTOR_HOME/scripts/task-lib.sh"

# Classification window: the bottom of the screen without blank padding.
# dump-screen pads to the viewport height, so a fixed tail of raw lines
# would see nothing but padding on tall panes.
SCREEN_TAIL_LINES=20

# screen_classify <agent> <dump-screen text>
# Prints "blocked<TAB><matched line>" / "working" / "idle". Blocked wins
# over working because an approval dialog is what the user must act on.
screen_classify() {
    local agent="$1" text="$2"
    local tail_buf pattern line
    tail_buf=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "$SCREEN_TAIL_LINES")

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        line=$(printf '%s\n' "$tail_buf" | grep -E -m 1 -- "$pattern" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            printf 'blocked\t%s\n' "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
            return 0
        fi
    done <<< "$(agent_patterns "$agent" "blocked")"

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if printf '%s\n' "$tail_buf" | grep -E -q -- "$pattern" 2>/dev/null; then
            echo "working"
            return 0
        fi
    done <<< "$(agent_patterns "$agent" "working")"

    echo "idle"
}

# Tab name -> filesystem-safe slug shared by the pending file and the
# last-state file.
_screen_tab_slug() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

_screen_write_pending() {
    local file="$1" tab="$2" session="$3" slug="$4" message="$5" event="$6" agent="$7"
    jq -n \
        --arg tab "$tab" \
        --arg session "$session" \
        --arg claude_session_id "screen-$slug" \
        --arg message "$message" \
        --arg event "$event" \
        --arg time "$(date '+%H:%M:%S')" \
        --arg agent "$agent" \
        '{tab: $tab, session: $session, claude_session_id: $claude_session_id, message: $message, event: $event, time: $time, agent: $agent}' \
        > "$file"
}

# screen_update_pending <session> <tab> <agent> <state> <message>
# Applies one observed state to the tab's pending files. The screen detector
# owns exactly one file per tab (screen-<slug>.json); notify-based entries
# (codex agent-turn-complete) keep their own thread-id files and win over a
# screen-generated Stop so a turn never shows up twice.
screen_update_pending() {
    local session="$1" tab="$2" agent="$3" state="$4" message="$5"
    local pending_dir="$HOME/.claude-pending/$session"
    mkdir -p "$pending_dir"

    local slug screen_file state_file prev f
    slug=$(_screen_tab_slug "$tab")
    screen_file="$pending_dir/screen-${slug}.json"
    state_file="$pending_dir/.screen-state/$slug"
    mkdir -p "$pending_dir/.screen-state"
    # || true: callers may run under set -e (test.sh) and a missing state
    # file on the first observation must not abort them.
    prev=$(cat "$state_file" 2>/dev/null || true)
    echo "$state" > "$state_file"

    # A Waiting tab is parked on an external response (waiting-toggle.sh):
    # neither surface it again nor clear it until the user un-parks it.
    for f in "$pending_dir"/*.json; do
        [[ -f "$f" ]] || continue
        if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$tab" \
              && "$(jq -r '.event' "$f" 2>/dev/null)" == "Waiting" ]]; then
            return 0
        fi
    done

    case "$state" in
        blocked)
            # Keep an existing Notification so the time reflects when the
            # approval first appeared, not the latest poll.
            if [[ ! -f "$screen_file" || "$(jq -r '.event' "$screen_file" 2>/dev/null)" != "Notification" ]]; then
                _screen_write_pending "$screen_file" "$tab" "$session" "$slug" \
                    "${message:-Approval required}" "Notification" "$agent"
            fi
            ;;
        working)
            # The agent picked the turn back up: everything pending for the
            # tab (stale approval, previous turn's Stop) is answered.
            for f in "$pending_dir"/*.json; do
                [[ -f "$f" ]] || continue
                if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$tab" ]]; then
                    rm -f "$f"
                fi
            done
            # A blocked/idle -> working transition means the user answered
            # inside the tab (approved, or submitted a prompt): mirror the
            # claude PostToolUse / UserPromptSubmit auto-return to Main.
            # Not on the first observation (prev empty) so a dashboard
            # restart mid-turn never yanks the focus.
            if [[ "$prev" == "blocked" || "$prev" == "idle" ]]; then
                zellij action go-to-tab-name Main 2>/dev/null || true
            fi
            ;;
        idle)
            # The approval dialog is gone (answered inside the tab).
            if [[ -f "$screen_file" && "$(jq -r '.event' "$screen_file" 2>/dev/null)" == "Notification" ]]; then
                rm -f "$screen_file"
            fi
            # Stop only on a working->idle transition: a freshly created tab
            # idles at the composer and must not appear as done. Skip when
            # the tab already has a pending (usually the notify Stop).
            if [[ "$prev" == "working" ]]; then
                for f in "$pending_dir"/*.json; do
                    [[ -f "$f" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$tab" ]]; then
                        return 0
                    fi
                done
                _screen_write_pending "$screen_file" "$tab" "$session" "$slug" \
                    "Task complete" "Stop" "$agent"
            fi
            ;;
    esac
    return 0
}

# screen_detect_tick <session>
# One detection pass over the session's panes. Agent panes are recognized
# by the TASK_AGENT= marker create_task puts in their command line, so a
# tab is scanned from the moment it exists — no registry entry needed for
# a first turn that is already waiting on an approval.
screen_detect_tick() {
    local session="$1"
    local panes tab pane_id agent text result state message
    panes=$(zellij action list-panes -t -c -j 2>/dev/null | jq -r '
        .[]
        | select(.is_plugin == false)
        | select(.terminal_command != null)
        | select(.terminal_command | test("TASK_AGENT="))
        | [.tab_name, (.id | tostring), (.terminal_command | capture("TASK_AGENT=(?<a>[^ ]+)").a)]
        | @tsv' 2>/dev/null)
    [[ -z "$panes" ]] && return 0

    while IFS=$'\t' read -r tab pane_id agent; do
        [[ -n "$tab" && -n "$pane_id" ]] || continue
        [[ "$(agent_detection "$agent")" == "screen" ]] || continue
        text=$(zellij action dump-screen -p "terminal_$pane_id" 2>/dev/null || true)
        [[ -n "$text" ]] || continue
        result=$(screen_classify "$agent" "$text")
        state=$(printf '%s\n' "$result" | head -1 | cut -f1)
        message=$(printf '%s\n' "$result" | head -1 | cut -s -f2)
        screen_update_pending "$session" "$tab" "$agent" "$state" "$message"
    done <<< "$panes"
    return 0
}
