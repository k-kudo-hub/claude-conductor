#!/bin/bash
# Claude Conductor - Screen Detection Library (issue #28)
# State detection for agents without lifecycle hooks (config
# .agents.<name>.detection == "screen"). The dashboard poll calls
# screen_detect_tick, which snapshots each screen-agent pane via
# `zellij action dump-screen` and matches the agent's configured patterns:
#
#   neutral  (viewer / picker screen) -> nothing changes at all
#   blocked  (known approval prompt)  -> Notification pending, no delay
#   working  (turn in progress)       -> the tab's pendings are cleared
#   idle     (anything else)          -> Stop pending, but only once idle has
#                                        held for a second (see idle_pending)
#
# Unknown dialogs deliberately fall back to idle (herdr's strictness): only
# a known approval prompt may surface as blocked, so a new UI screen never
# spams the dashboard with false approvals. A screen the agent does not own
# is neutral rather than idle, because on it neither the spinner nor the
# prompt box is visible and nothing can be concluded from what is shown.
# Sourced by dashboard-loop.sh; defines functions only.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
# shellcheck source=scripts/task-lib.sh
. "$CONDUCTOR_HOME/scripts/task-lib.sh"

# Classification window: the bottom of the screen without blank padding.
# dump-screen pads to the viewport height, so a fixed tail of raw lines
# would see nothing but padding on tall panes.
SCREEN_TAIL_LINES=20

# screen_classify <agent> <dump-screen text>
# Prints "neutral" / "blocked<TAB><matched line>" / "working" / "idle".
# Neutral wins over everything: a full-screen viewer or picker hides the
# agent's own UI, so nothing on it says anything about the turn. Blocked
# wins over working because an approval dialog is what the user must act on.
screen_classify() {
    local agent="$1" text="$2"
    local tail_buf pattern line
    tail_buf=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "$SCREEN_TAIL_LINES")

    # A screen the agent does not own: the spinner is hidden (would read as a
    # false done) and scrolled-back log lines may quote approval prompts
    # (would read as a false blocked). herdr's skip_state_update equivalent.
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if printf '%s\n' "$tail_buf" | grep -E -q -- "$pattern" 2>/dev/null; then
            echo "neutral"
            return 0
        fi
    done <<< "$(agent_patterns "$agent" "neutral")"

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

# Latest registry entry for the tab, as "dir<TAB>task_type<TAB>transcript".
# Screen-generated pendings borrow these fields so downstream consumers
# (upload-log.sh needs transcript_path, restore-task.sh needs dir) keep
# working when a screen entry is the only pending left for the tab.
_screen_registry_lookup() {
    local session="$1" tab="$2" f best="" best_t=0 t
    for f in "$CONDUCTOR_HOME/tasks/$session"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r '.tab // empty' "$f" 2>/dev/null)" == "$tab" ]] || continue
        t=$(stat -f %m "$f" 2>/dev/null || echo 0)
        if [[ "$t" -ge "$best_t" ]]; then
            best="$f"
            best_t="$t"
        fi
    done
    [[ -n "$best" ]] || return 0
    jq -r '[.dir // "", .task_type // "", .transcript_path // ""] | @tsv' "$best" 2>/dev/null || true
}

_screen_write_pending() {
    local file="$1" tab="$2" session="$3" slug="$4" message="$5" event="$6" agent="$7"
    local dir="" task_type="" transcript=""
    IFS=$'\t' read -r dir task_type transcript <<< "$(_screen_registry_lookup "$session" "$tab")"
    # 合成ID `screen-<slug>` の生成元。この接頭辞は record-output.sh の dedupe
    # 判定と task-lib.sh の resume_session_id でも見ている。変えるなら3箇所同時に。
    jq -n \
        --arg tab "$tab" \
        --arg session "$session" \
        --arg claude_session_id "screen-$slug" \
        --arg message "$message" \
        --arg event "$event" \
        --arg time "$(date '+%H:%M:%S')" \
        --arg agent "$agent" \
        --arg dir "$dir" \
        --arg task_type "$task_type" \
        --arg transcript_path "$transcript" \
        '{tab: $tab, session: $session, claude_session_id: $claude_session_id, message: $message, event: $event, time: $time, agent: $agent}
         + (if $transcript_path != "" then {transcript_path: $transcript_path} else {} end)
         + (if $dir != "" then {dir: $dir} else {} end)
         + (if $task_type != "" then {task_type: $task_type} else {} end)' \
        > "$file"
}

# screen_update_pending <session> <tab> <agent> <state> <message>
# Applies one observed state to the tab's pending files. The screen detector
# owns exactly one file per tab (screen-<slug>.json); notify-based entries
# (codex agent-turn-complete) keep their own thread-id files and win over a
# screen-generated Stop so a turn never shows up twice.
screen_update_pending() {
    local session="$1" tab="$2" agent="$3" state="$4" message="$5"

    # neutral is "no observation": leave the last state and every pending file
    # untouched so a viewer or picker cannot move the tab on the dashboard.
    if [[ "$state" == "neutral" ]]; then
        return 0
    fi

    local pending_dir="$HOME/.claude-pending/$session"
    mkdir -p "$pending_dir"

    local slug screen_file state_file prev_raw prev prev_at now effective f
    local confirm_idle=0
    slug=$(_screen_tab_slug "$tab")
    screen_file="$pending_dir/screen-${slug}.json"
    state_file="$pending_dir/.screen-state/$slug"
    mkdir -p "$pending_dir/.screen-state"
    # || true: callers may run under set -e (test.sh) and a missing state
    # file on the first observation must not abort them.
    # The file holds one line: the state, plus an epoch for idle_pending.
    prev_raw=$(cat "$state_file" 2>/dev/null || true)
    prev="${prev_raw%% *}"
    prev_at="${prev_raw#* }"
    [[ "$prev_at" == "$prev_raw" ]] && prev_at=""

    # working -> idle は1回の観測では確定させず idle_pending に置く。codex の
    # スピナー行はツール実行の切れ目や再描画の1フレームで消えるため、その
    # 瞬間を拾うと偽の done がダッシュボードに出る。確定は「次の観測」では
    # なく「実時間が1秒以上経ってからの観測」を条件にする。ダッシュボードの
    # ポーリングはキー入力で早回りしうるので、観測回数だけを条件にすると
    # 同じ1フレームを連続で見て確定してしまう（herdr の
    # PendingIdleConfirmation も実時間ベース: 100ms x 3回 / 700ms 上限）。
    # blocked には遅延をかけない: 人間を待たせている状態は即時性が要る。
    now=$(date +%s)
    effective="$state"
    if [[ "$state" == "idle" ]]; then
        if [[ "$prev" == "working" ]]; then
            effective="idle_pending $now"
        elif [[ "$prev" == "idle_pending" ]]; then
            if [[ "$prev_at" =~ ^[0-9]+$ ]] && [[ $((now - prev_at)) -lt 1 ]]; then
                # 早回りした再観測。最初に idle を見た時刻を保ったまま待つ。
                effective="idle_pending $prev_at"
            else
                confirm_idle=1
            fi
        fi
    fi
    echo "$effective" > "$state_file"

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
            # restart mid-turn never yanks the focus. idle_pending is
            # deliberately excluded: it means "that idle frame is not to be
            # trusted", nothing was shown to the user, and yanking focus on a
            # spinner flicker would drag them out of a tab they are reading.
            # An answered approval still comes through as blocked -> working,
            # and a prompt sent after a finished turn as idle -> working.
            if [[ "$prev" == "blocked" || "$prev" == "idle" ]]; then
                # 毎tick走る経路なので、ここもガード必須（素の呼び出しだと
                # 劣化サーバでダッシュボードごと止まる）
                _zellij_guarded "$(_zj_call_timeout)" action go-to-tab-name Main \
                    >/dev/null 2>&1 || true
            fi
            ;;
        idle)
            # The approval dialog is gone (answered inside the tab).
            if [[ -f "$screen_file" && "$(jq -r '.event' "$screen_file" 2>/dev/null)" == "Notification" ]]; then
                rm -f "$screen_file"
            fi
            # Converge duplicated done states: the notify bridge can land its
            # Stop seconds after ours (sqlite + sessions-tree lookups), and a
            # doubled entry would also break the w-key Waiting toggle. Once
            # any other pending exists for the tab, our Stop is redundant.
            if [[ -f "$screen_file" && "$(jq -r '.event' "$screen_file" 2>/dev/null)" == "Stop" ]]; then
                for f in "$pending_dir"/*.json; do
                    [[ -f "$f" && "$f" != "$screen_file" ]] || continue
                    if [[ "$(jq -r '.tab' "$f" 2>/dev/null)" == "$tab" ]]; then
                        rm -f "$screen_file"
                        break
                    fi
                done
            fi
            # Stop only once idle is confirmed (idle_pending held for at least
            # a second): a freshly created tab idles at the composer and must
            # not appear as done, and a single idle frame mid-turn is not a
            # turn end. Skip when the tab already has a pending (usually the
            # notify Stop).
            if [[ "$confirm_idle" == "1" ]]; then
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
    local panes tab pane_id agent text result state message zj_timeout
    # 劣化したzellijサーバでは `zellij action` が戻ってこない。このtickは毎秒回るので
    # 素通しにするとハングしたプロセスが積み上がる（実測200個超）。kill ガードで
    # 打ち切り、その場合の出力は空 = このtickは何も検出しなかった扱いにする
    # （従来の `2>/dev/null || true` と同じ挙動）。
    zj_timeout=$(_zj_call_timeout)
    panes=$(_zellij_guarded "$zj_timeout" action list-panes -t -c -j 2>/dev/null | jq -r '
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
        # dump-screen はペイン数ぶん毎tick叩くので、ハング時の蓄積は list-panes より
        # 速い。同じガードで打ち切り、空なら（従来どおり）このペインを飛ばす。
        text=$(_zellij_guarded "$zj_timeout" action dump-screen -p "terminal_$pane_id" 2>/dev/null || true)
        [[ -n "$text" ]] || continue
        result=$(screen_classify "$agent" "$text")
        state=$(printf '%s\n' "$result" | head -1 | cut -f1)
        message=$(printf '%s\n' "$result" | head -1 | cut -s -f2)
        screen_update_pending "$session" "$tab" "$agent" "$state" "$message"
    done <<< "$panes"
    return 0
}
