#!/bin/bash
# Claude Conductor - Task Library
# Shared functions for creating tasks (tabs) and applying layouts.
# Sourced by task-create-loop.sh and done-loop.sh; defines functions only.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# --- zellij call guards ---------------------------------------------------
# zellij 0.44.1 の `zellij action` はサーバ応答を最大1秒しか待たない。つまり
# rc=0 は「サーバが受理した」であって「処理が終わった」ではない（new-tab が
# 典型で、タブが登録される前に rc=0 で戻ってくる）。さらに劣化サーバでは
# `zellij action` 自体が戻ってこないことがあり、実測ではハングした list-panes が
# 200 個以上のプロセスとして積み上がった。
#
# macOS には timeout(1) が無く、bash 3.2 には `wait -n` も無い。そこで zellij を
# バックグラウンドで起動し、ポーリングで見張って期限を過ぎたら kill する。

# 1回の `zellij action` を諦めるまでの秒数
_zj_call_timeout() { echo "${CONDUCTOR_ZELLIJ_TIMEOUT:-10}"; }
# new-tab 後のハンドシェイク（タブ登録待ち + フォーカス検証）全体の予算（ミリ秒）
_zj_tab_ready_ms() { echo "${CONDUCTOR_TAB_READY_MS:-10000}"; }
# 上記ポーリングの間隔（ミリ秒）
_ZJ_POLL_MS=100

# _zellij_guarded <timeout_sec> <zellij の引数...>
# `zellij "$@"` を実行し、<timeout_sec> 以内に終わらなければ kill する。
# 子プロセスはこの関数の stdout をそのまま引き継ぐので、
# `out=$(_zellij_guarded 10 action go-to-tab-name foo)` で出力を取れる。
# 戻り値は zellij の終了ステータス。kill した場合は timeout(1) と同じ 124。
_zellij_guarded() {
    local limit_ms=$(( ${1:-10} * 1000 )); shift
    local pid rc waited=0
    zellij "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $waited -ge $limit_ms ]]; then
            # kill/wait はブロックごと黙らせる。非対話 bash は signal で死んだ
            # ジョブを "Terminated" と報告し、それが呼び出し元の stderr を汚す。
            { kill -TERM "$pid"; sleep 0.2; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            return 124
        fi
        # 健全なサーバなら `zellij action` は数十msで返る。最初だけ細かく見て
        # 正常系の追加待ちを実質ゼロにし、待たされるほど間隔を伸ばす。
        if [[ $waited -lt 100 ]]; then
            sleep 0.002; waited=$((waited + 2))
        elif [[ $waited -lt 1000 ]]; then
            sleep 0.02; waited=$((waited + 20))
        else
            sleep 0.1; waited=$((waited + 100))
        fi
    done
    wait "$pid"
    rc=$?
    return $rc
}

# _wait_tab_registered <name>
# タブ名が `zellij action query-tab-names` に現れるまで待つ。new-tab の rc=0 は
# 登録完了を保証しないため、名前で指すコマンド（go-to-tab-name）はこれを待たずに
# 撃つと無言で外れる。
_wait_tab_registered() {
    local name="$1"
    local budget_ms; budget_ms=$(_zj_tab_ready_ms)
    local timeout; timeout=$(_zj_call_timeout)
    local waited=0 start=$SECONDS names
    while :; do
        names=$(_zellij_guarded "$timeout" action query-tab-names 2>/dev/null)
        if printf '%s\n' "$names" | grep -Fxq -- "$name"; then
            return 0
        fi
        # 予算はポーリング間隔の合計と実時間の両方で見る（1回の呼び出しが
        # 遅いサーバでは前者だけだと期限が伸びてしまう）
        if [[ $waited -ge $budget_ms || $(( (SECONDS - start) * 1000 )) -ge $budget_ms ]]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + _ZJ_POLL_MS))
    done
}

# _focus_tab_verified <name>
# フォーカスを名前で移し、実際に移ったことを確認する。
#
# 判定根拠: `zellij action go-to-tab-name` は存在しないタブ名でも rc=0 で戻る
# 無言の no-op で、終了ステータスからは成否が分からない。zellij 0.44.1（macOS）
# で実測した唯一の差は stdout で、
#     ヒット時  -> 移動先タブの index を出力（"0" / "1" ...）rc=0
#     ミス時    -> stdout は空                                rc=0
# したがって「stdout 非空 = フォーカス成功」で判定する。将来の zellij がこの出力を
# やめた場合はフォーカスが永久に未確認となり、create_task はペインを作らずに
# 失敗を返す（= Main を壊すより中止を選ぶ）方向に倒れる。
_focus_tab_verified() {
    local name="$1"
    local budget_ms; budget_ms=$(_zj_tab_ready_ms)
    local timeout; timeout=$(_zj_call_timeout)
    local waited=0 start=$SECONDS out
    while :; do
        out=$(_zellij_guarded "$timeout" action go-to-tab-name "$name" 2>/dev/null)
        if [[ -n "$out" ]]; then
            return 0
        fi
        if [[ $waited -ge $budget_ms || $(( (SECONDS - start) * 1000 )) -ge $budget_ms ]]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + _ZJ_POLL_MS))
    done
}

load_config() {
    local config_file="$CONDUCTOR_HOME/config.json"
    if [[ ! -f "$config_file" ]]; then
        config_file="$CONDUCTOR_HOME/config.default.json"
    fi
    echo "$config_file"
}

# Agent launch command. With a name, resolves config .agents.<name>.command
# (an unknown name falls back to the name itself as the command). Without a
# name, keeps the legacy .agent.command path. The value is a single string
# that callers word-split on purpose, so wrapper invocations like
# "fdev secrets exec my-header -- claude" work as-is.
agent_command() {
    local agent="$1" cmd
    if [[ -n "$agent" ]]; then
        cmd=$(jq -r --arg a "$agent" '.agents[$a].command // empty' "$(load_config)" 2>/dev/null)
        [[ -z "$cmd" ]] && cmd="$agent"
    else
        cmd=$(jq -r '.agent.command // empty' "$(load_config)" 2>/dev/null)
        [[ -z "$cmd" ]] && cmd="claude"
    fi
    echo "$cmd"
}

# Arguments inserted between the agent command and the session id when
# resuming. With a name, resolves config .agents.<name>.resume_args;
# without one, the legacy .agent.resume_args. Word-split like agent_command.
agent_resume_args() {
    local agent="$1" args
    if [[ -n "$agent" ]]; then
        args=$(jq -r --arg a "$agent" '.agents[$a].resume_args // empty' "$(load_config)" 2>/dev/null)
    else
        args=$(jq -r '.agent.resume_args // empty' "$(load_config)" 2>/dev/null)
    fi
    [[ -z "$args" ]] && args="--resume"
    echo "$args"
}

# Configured agent names (config .agents keys), one per line. Empty output
# means no named agents are configured and tasks use the legacy single-agent
# path.
agent_names() {
    jq -r '.agents // {} | keys_unsorted[]' "$(load_config)" 2>/dev/null
}

# State detection method for an agent: "hooks" (Claude Code lifecycle hooks
# own the pending files) or "screen" (issue #28: the dashboard polls the
# tab's screen and matches config .agents.<name>.patterns). Anything not
# explicitly configured as "screen" falls back to hooks so agent-less legacy
# tabs and unknown agents are never screen-scanned.
agent_detection() {
    local agent="$1" method=""
    if [[ -n "$agent" ]]; then
        method=$(jq -r --arg a "$agent" '.agents[$a].detection // empty' "$(load_config)" 2>/dev/null)
    fi
    [[ -z "$method" ]] && method="hooks"
    echo "$method"
}

# Screen-detection regexes (grep -E) for one state ("neutral" / "blocked" /
# "working"), one per line. Empty output means the agent defines no patterns
# for that state and it can never be classified as such.
agent_patterns() {
    local agent="$1" state="$2"
    [[ -z "$agent" ]] && return 0
    jq -r --arg a "$agent" --arg s "$state" \
        '.agents[$a].patterns[$s] // [] | .[]' "$(load_config)" 2>/dev/null
}

# Tab name -> filesystem-safe slug keying a tab's screen-detection files
# (pending + last-state). tr -c mangles multibyte names byte-wise, so two
# Japanese tab names would collide on the sanitized part alone — the cksum
# suffix keeps distinct names distinct.
_screen_tab_slug() {
    local safe hash
    safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
    hash=$(printf '%s' "$1" | cksum | awk '{print $1}')
    printf '%s-%s' "$safe" "$hash"
}

apply_layout() {
    local dir="$1"
    local type="$2"
    local config_file
    config_file=$(load_config)

    local steps
    steps=$(jq -c --arg t "$type" '.task_types[$t].layout[]' "$config_file" 2>/dev/null)

    if [[ -z "$steps" ]]; then
        return
    fi

    sleep 0.3

    # レイアウト適用中もサーバが劣化しうるので、各アクションに kill ガードを噛ませる
    # （1本ハングしただけでタスク作成が永久に止まらないようにする）
    local zj_timeout
    zj_timeout=$(_zj_call_timeout)

    while IFS= read -r step; do
        local action direction command
        action=$(echo "$step" | jq -r '.action')
        direction=$(echo "$step" | jq -r '.direction')
        command=$(echo "$step" | jq -r '.command // empty')

        case "$action" in
            new-pane)
                if [[ -n "$command" ]]; then
                    _zellij_guarded "$zj_timeout" action new-pane --direction "$direction" --cwd "$dir" -- "$command"
                else
                    _zellij_guarded "$zj_timeout" action new-pane --direction "$direction" --cwd "$dir"
                fi
                ;;
            move-focus)
                _zellij_guarded "$zj_timeout" action move-focus "$direction"
                ;;
            focus-previous-pane)
                _zellij_guarded "$zj_timeout" action focus-previous-pane
                ;;
            resize)
                local amount
                amount=$(echo "$step" | jq -r '.amount // 1')
                local j
                for (( j=0; j<amount; j++ )); do
                    _zellij_guarded "$zj_timeout" action resize "$direction"
                done
                ;;
        esac
    done <<< "$steps"
}

create_task() {
    local dir="$1"
    local type="$2"
    local name="$3"
    local resume="$4"   # optional: agent session id to resume
    local agent="$5"    # optional: named agent (config .agents key)

    local -a agent_cmd
    read -r -a agent_cmd <<< "$(agent_command "$agent")"

    # A tab recreated under a previous task's name must not inherit that
    # task's screen-detection state: a stale "working" would fake an instant
    # Stop (or a stale "blocked" an unwanted jump to Main) on the new tab's
    # first poll.
    rm -f "$HOME/.claude-pending/${ZELLIJ_SESSION_NAME:-unknown}/.screen-state/$(_screen_tab_slug "$name")"

    # TASK_AGENT rides along only for named agents, so tabs on the legacy
    # single-agent path keep their exact env (and pending files stay
    # agent-less, which downstream treats as claude).
    local -a envs=(TASK_TAB_NAME="$name" TASK_TYPE="$type")
    [[ -n "$agent" ]] && envs+=(TASK_AGENT="$agent")

    local rc zj_timeout
    zj_timeout=$(_zj_call_timeout)
    if [[ -n "$resume" ]]; then
        local -a resume_flags
        read -r -a resume_flags <<< "$(agent_resume_args "$agent")"
        _zellij_guarded "$zj_timeout" action new-tab -n "$name" --cwd "$dir" -- env "${envs[@]}" "${agent_cmd[@]}" "${resume_flags[@]}" "$resume"
        rc=$?
    else
        _zellij_guarded "$zj_timeout" action new-tab -n "$name" --cwd "$dir" -- env "${envs[@]}" "${agent_cmd[@]}"
        rc=$?
    fi
    # Report tab-creation success to the caller (restore relies on this).
    # Bail out before building panes if the tab itself could not be created.
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi

    # ここから先のペイン操作は「フォーカスが新しいタブに在る」ことが大前提で、
    # 外すと new-pane が Main を割ってしまう。new-tab の rc=0 は登録完了を
    # 意味しないので（zellij 0.44.1 の action はサーバ応答を1秒しか待たない）、
    # 旧実装の `sleep 0.3` に代えてタブ登録をポーリングで待ち、さらに
    # フォーカスが実際に移ったことまで確認する。
    if ! _wait_tab_registered "$name"; then
        echo "create_task: tab '$name' was not registered in time; skipping pane setup" >&2
        return 3
    fi
    if ! _focus_tab_verified "$name"; then
        echo "create_task: could not confirm focus on tab '$name'; skipping pane setup" >&2
        return 3
    fi

    _zellij_guarded "$zj_timeout" action new-pane --direction down --cwd "$dir" -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"
    local i
    for i in {1..30}; do
        _zellij_guarded "$zj_timeout" action resize decrease up
    done
    _zellij_guarded "$zj_timeout" action focus-previous-pane

    # Layout is cosmetic; its status must not mask tab-creation success.
    apply_layout "$dir" "$type"
    return 0
}
