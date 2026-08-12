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
# macOS には timeout(1) が無く、bash 3.2 には `wait -n` も無い。代わりに perl の
# alarm(2) を使う。alarm は exec を跨いで生き残り、SIGALRM の既定動作がプロセス終了
# なので `perl -e 'alarm N; exec @ARGV' N zellij ...` は fork 1回だけの timeout(1)
# 相当になる（見張りプロセスも sleep も残らない）。perl が無い環境用に、従来の
# ポーリング方式もフォールバックとして残す。

# 1回の `zellij action` を諦めるまでの秒数
_zj_call_timeout() { echo "${CONDUCTOR_ZELLIJ_TIMEOUT:-10}"; }
# new-tab 後のハンドシェイク（タブ登録待ち + フォーカス検証）全体の予算（ミリ秒）
_zj_tab_ready_ms() { echo "${CONDUCTOR_TAB_READY_MS:-10000}"; }
# create_task 全体（new-tab からレイアウト適用まで）の予算（秒）
_zj_setup_budget() { echo "${CONDUCTOR_TASK_SETUP_BUDGET:-30}"; }
# 登録待ち・フォーカス検証のポーリング間隔（ミリ秒。fork を増やさない固定値）
_ZJ_POLL_MS=100

# alarm 方式に使う perl。source 時に一度だけ解決する。
_ZJ_PERL="$(command -v perl 2>/dev/null)"

# _zellij_guarded <timeout_sec> <zellij の引数...>
# `zellij "$@"` を実行し、<timeout_sec> 以内に終わらなければ打ち切る。
# 子プロセスはこの関数の stdout をそのまま引き継ぐので、
# `out=$(_zellij_guarded 10 action go-to-tab-name foo)` で出力を取れる。
# 戻り値は zellij の終了ステータス。打ち切った場合は timeout(1) と同じ 124。
_zellij_guarded() {
    local limit="${1:-10}"; shift
    local pid rc
    if [[ -n "$_ZJ_PERL" && -z "$CONDUCTOR_GUARD_NO_PERL" ]]; then
        # exec の対象を {$ARGV[0]} で明示し、引数が1個でも perl がシェル解釈に
        # 落ちないようにする（引数中の空白もそのまま渡る）。
        # バックグラウンド + wait にするのは、SIGALRM で死んだ子を前景で回収すると
        # bash が "Alarm clock" を stderr へ出してしまうため（wait を黙らせれば漏れない）。
        "$_ZJ_PERL" -e 'alarm shift; exec {$ARGV[0]} @ARGV or exit 127' \
            "$limit" zellij "$@" &
        pid=$!
        wait "$pid" 2>/dev/null
        rc=$?
        # SIGALRM(14) で打ち切られた = 142。timeout(1) 準拠の 124 に正規化する
        [[ $rc -eq 142 ]] && rc=124
        return $rc
    fi
    _zellij_guarded_poll "$limit" "$@"
}

# perl が無い環境向けのフォールバック。1回の sleep が短いほど時刻精度は上がるが
# その分 fork が増えるので、100ms 固定で回して実時間（SECONDS）でも期限を見る。
_zellij_guarded_poll() {
    local limit="${1:-10}"; shift
    local pid rc waited=0 start=$SECONDS
    zellij "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        # 判定は「ポーリング間隔の累計」を主、「実時間」を保険にする。
        # SECONDS は1秒単位なので、比較は -gt にして「早く切ってしまう」側には
        # 倒さない（-ge だと start の位相次第で最大1秒早く殺してしまう）。
        if [[ $waited -ge $(( limit * 1000 )) || $(( SECONDS - start )) -gt $limit ]]; then
            # kill/wait はブロックごと黙らせる。非対話 bash は signal で死んだ
            # ジョブを "Terminated" と報告し、それが呼び出し元の stderr を汚す。
            { kill -TERM "$pid"; sleep 0.2; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            return 124
        fi
        # 健全なサーバの `zellij action` は数十msで返るので、最初の100msだけ細かく
        # 見て正常系の待ちを詰める。細かい刻みは10回まで（＝sleepのfork10回まで）に
        # 制限し、それ以降は100ms固定。累計と実時間のずれが数%に収まる範囲。
        if [[ $waited -lt 100 ]]; then
            sleep 0.01
            waited=$((waited + 10))
        else
            sleep 0.1
            waited=$((waited + 100))
        fi
    done
    wait "$pid"
    rc=$?
    return $rc
}

# _zj_budget_cap <開始SECONDS> <予算秒> <1回のタイムアウト秒>
# 「残り予算」と「1回のタイムアウト」の小さい方を返す。予算切れなら 0 を返し、
# 呼び出し元はそれ以上コマンドを撃たない。予算が空なら無制限（= タイムアウトのまま）。
_zj_budget_cap() {
    local start="$1" budget="$2" timeout="$3" left
    if [[ -z "$budget" ]]; then
        echo "$timeout"
        return 0
    fi
    left=$(( budget - (SECONDS - start) ))
    if [[ $left -le 0 ]]; then
        echo 0
    elif [[ $left -lt $timeout ]]; then
        echo "$left"
    else
        echo "$timeout"
    fi
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
#
# 出力仕様が変わった場合の構造的な代替:
#   zellij action list-panes -t -c -j の各要素にある is_focused と tab_name を
#   突き合わせ、目的のタブにフォーカス中のペインが在るかで事後確認する
#   （両フィールドとも 0.44.1 の出力に実在。screen_detect_tick が同じ JSON を
#   使っているので追加の依存も無い）。stdout ヒューリスティックより重いぶん、
#   出力が消えたときの置き換え先として記録しておく。
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

# 再開に使うエージェントのセッションIDを返す。次のすべてを満たしたときだけ
# 再開し、1つでも欠ければ空を返して新規セッションで起動する（壊れた resume を
# しない）。
#
#   - セッションIDが記録されている
#   - transcript のパスが記録されている
#   - セッションIDがスクリーン検出の合成ID（screen-<slug>）ではない
#   - transcript のファイルが実在する
#
# 3つ目が要るのは、hookを持たないエージェント（codex）の完了をタブの画面から
# 検出するとき、screen-detect-lib.sh が claude_session_id をタブ名から
# `screen-<slug>` として合成するため。合成IDは daily ログにもそのまま載り、
# transcript はレジストリ由来で実在するので他の条件を素通りしてしまい、
# `codex resume screen-cx_task-1234567890` という存在しないIDで起動する。
#
# 復元は「起動時のセッション復元」と「Doneからの復元」の2経路あるが、
# 判断はここに集約する。別々に書くと片方だけに直しが入って挙動がずれる。
resume_session_id() {
    local sid="$1" transcript="$2"
    [[ -n "$sid" ]] || return 0
    [[ -n "$transcript" ]] || return 0
    # 合成IDの接頭辞 "screen-" は screen-detect-lib.sh が生成し、record-output.sh の
    # dedupe 判定でも見ている。変えるなら3箇所同時に。
    case "$sid" in
        screen-*) return 0 ;;
    esac
    [[ -f "$transcript" ]] || return 0
    echo "$sid"
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

# apply_layout <dir> <type> [残り予算秒]
# 残り予算を渡すと、その秒数を超えた時点で残りのレイアウト操作を打ち切る
# （劣化サーバで1コマンドずつタイムアウトを積み上げて数分固まらないため）。
# 省略時は無制限（従来どおり）。
apply_layout() {
    local dir="$1"
    local type="$2"
    local budget="${3:-}"
    local start=$SECONDS
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
    local zj_timeout cap
    zj_timeout=$(_zj_call_timeout)

    while IFS= read -r step; do
        local action direction command
        action=$(echo "$step" | jq -r '.action')
        direction=$(echo "$step" | jq -r '.direction')
        command=$(echo "$step" | jq -r '.command // empty')

        cap=$(_zj_budget_cap "$start" "$budget" "$zj_timeout")
        if [[ "$cap" -le 0 ]]; then
            echo "apply_layout: budget exhausted; skipping the rest of the '$type' layout" >&2
            return 0
        fi

        case "$action" in
            new-pane)
                if [[ -n "$command" ]]; then
                    _zellij_guarded "$cap" action new-pane --direction "$direction" --cwd "$dir" -- "$command"
                else
                    _zellij_guarded "$cap" action new-pane --direction "$direction" --cwd "$dir"
                fi
                ;;
            move-focus)
                _zellij_guarded "$cap" action move-focus "$direction"
                ;;
            focus-previous-pane)
                _zellij_guarded "$cap" action focus-previous-pane
                ;;
            resize)
                local amount
                amount=$(echo "$step" | jq -r '.amount // 1')
                local j
                for (( j=0; j<amount; j++ )); do
                    cap=$(_zj_budget_cap "$start" "$budget" "$zj_timeout")
                    if [[ "$cap" -le 0 ]]; then
                        echo "apply_layout: budget exhausted; skipping the rest of the '$type' layout" >&2
                        return 0
                    fi
                    _zellij_guarded "$cap" action resize "$direction"
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

    local rc zj_timeout cap
    zj_timeout=$(_zj_call_timeout)
    # タスク作成全体の予算。劣化サーバでは1コマンドごとにタイムアウトぶん待たされ、
    # 素の合計は new-tab 10s + 登録待ち 10s + フォーカス 10s + 各ペイン操作 10s×35 =
    # 6分超になりうる。フォーカス確認後は残り予算でタイムアウトを頭打ちにし、
    # 尽きたらレイアウト系を諦める（タブとエージェントは既に動いている）。
    local setup_start=$SECONDS setup_budget
    setup_budget=$(_zj_setup_budget)
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

    # task-control ペインはタスクの中核なので、予算が尽きていても最低1秒は試す
    cap=$(_zj_budget_cap "$setup_start" "$setup_budget" "$zj_timeout")
    [[ "$cap" -le 0 ]] && cap=1
    _zellij_guarded "$cap" action new-pane --direction down --cwd "$dir" -- bash "$CONDUCTOR_HOME/scripts/task-control.sh" "$name"

    # ここから下（リサイズ・レイアウト）は見た目の調整で、タブとしては既に
    # 機能している。予算切れなら黙って諦めて rc=0 で返す。
    local i
    for i in {1..30}; do
        cap=$(_zj_budget_cap "$setup_start" "$setup_budget" "$zj_timeout")
        if [[ "$cap" -le 0 ]]; then
            echo "create_task: setup budget (${setup_budget}s) exhausted for tab '$name'; skipping the remaining layout" >&2
            return 0
        fi
        _zellij_guarded "$cap" action resize decrease up
    done

    cap=$(_zj_budget_cap "$setup_start" "$setup_budget" "$zj_timeout")
    if [[ "$cap" -le 0 ]]; then
        echo "create_task: setup budget (${setup_budget}s) exhausted for tab '$name'; skipping the remaining layout" >&2
        return 0
    fi
    _zellij_guarded "$cap" action focus-previous-pane

    # Layout is cosmetic; its status must not mask tab-creation success.
    apply_layout "$dir" "$type" "$(( setup_budget - (SECONDS - setup_start) ))"
    return 0
}
