package dashboard

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/paths"
	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
	"github.com/k-kudo-hub/claude-conductor/internal/zellij"
)

// PollInterval は状態を見直す間隔。bash 版と同じ 2 秒。
const PollInterval = 2 * time.Second

// DeletePromptTimeout は d を押してから番号入力を待つ時間。bash 版の
// `read -t 3` と同じ。削除は取り消せないので、放置した d が後のキー入力を
// 巻き込まないよう必ず打ち切る。
const DeletePromptTimeout = 3 * time.Second

// StatusDuration はアップロード結果やエラーを出しておく時間。
const StatusDuration = 2 * time.Second

// DetectTimeout はスクリーン検出 1 回ぶんの上限。検出は zellij の画面
// ダンプに依存するため、応答しないときに次のポーリングが永久に来なく
// なるのを防ぐ。
const DetectTimeout = 10 * time.Second

// AgentDetectionTimeout はエージェントの追跡方法を問い合わせる上限。
const AgentDetectionTimeout = 3 * time.Second

// DefaultWidth は端末サイズを問い合わせられないときに使う幅。
const DefaultWidth = 44

type tickMsg time.Time

// entriesMsg は 1 回の観測の結果。
//
// scheduleNext は「この観測が定期ポーリングの一部か」を表す。ジャンプや
// 削除の直後にも観測するが、そこで次の tick まで積むとポーリングの鎖が
// 1 本ずつ増えていく。増えると screen-detect-tick.sh の実行頻度が上がり、
// 旧 dashboard-loop.sh のコメントが警告していた「短い間隔で観測が重なり
// idle 確定が一瞬で成立する」状態を招く。
type entriesMsg struct {
	entries      []pending.Entry
	scheduleNext bool
}

// promptTimeoutMsg は番号入力待ちの打ち切り。世代番号で古いタイマーを弾く。
type promptTimeoutMsg int

// clearStatusMsg は一時表示の消去。世代番号で古いタイマーを弾く。
type clearStatusMsg int

// deleteResultMsg は task-delete.sh の結果。err が非 nil なら
// アップロードに失敗しており、タスクは消えていない。
type deleteResultMsg struct {
	output string
	err    error
}

// jumpedMsg はタブ切り替えの完了。切り替え後は次のポーリングを待たずに
// 一覧を読み直す。
type jumpedMsg struct{}

// Model は Dashboard ペインの状態。
type Model struct {
	session string
	dir     string
	theme   ui.Theme
	width   int
	height  int
	entries []pending.Entry

	awaitingDelete bool
	promptGen      int

	deleting  bool
	status    string
	statusGen int
}

// NewModel は空の状態から始める。最初の一覧は Init の観測で埋まる。
func NewModel(session string, th ui.Theme, width int) Model {
	return Model{
		session: session,
		dir:     pending.Dir(session),
		theme:   th,
		width:   width,
	}
}

func tick() tea.Cmd {
	return tea.Tick(PollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func promptTimeout(gen int) tea.Cmd {
	return tea.Tick(DeletePromptTimeout, func(time.Time) tea.Msg {
		return promptTimeoutMsg(gen)
	})
}

func clearStatus(gen int) tea.Cmd {
	return tea.Tick(StatusDuration, func(time.Time) tea.Msg {
		return clearStatusMsg(gen)
	})
}

// restoreSession はセッションに登録済みのタスクをタブとして復元する
// （issue #36）。レジストリが空か、既にタブがある場合は何もしない。
func restoreSession() tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("bash", paths.Script("restore-session.sh")).Run()
		return nil
	}
}

// observe は 1 回ぶんの観測。hooks を持たないエージェントの状態を
// スクリーンから拾い（issue #28）、そのうえで pending を読み直す。
//
// bash 版はこれを描画ループの中で同期実行していたため、画面取得が遅いと
// ペインごと固まっていた。コマンドとして走らせ、待っている間も入力を
// 受け付けられるようにする。
func observe(session, dir string, scheduleNext bool) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), DetectTimeout)
		defer cancel()

		_ = exec.CommandContext(ctx, "bash",
			paths.Script("screen-detect-tick.sh"), session).Run()
		return entriesMsg{entries: Snapshot(dir), scheduleNext: scheduleNext}
	}
}

// Snapshot は現在の表示対象を、Zellij のタブ順で返す。
func Snapshot(dir string) []pending.Entry {
	return OrderByTabs(pending.Load(dir), zellij.Names(zellij.ListTabs()))
}

// deleteTask はタスクを削除する。task-delete.sh が「記録 → アップロード →
// 削除 → タブを閉じる」を順に行い、アップロードに失敗した時点で中断して
// 非ゼロを返す。
func deleteTask(tab string) tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("bash", paths.Script("task-delete.sh"), tab).Output()
		return deleteResultMsg{output: strings.TrimSpace(string(out)), err: err}
	}
}

// jump はタブへ切り替える。
//
// pending をここで消すのは、hooks もスクリーン検出も持たないエージェント
// だけ。それ以外は自分で状態を畳むので、ここで消すと次のポーリングが
// すぐ作り直すだけになる（スクリーン検出の Notification は、ターンが
// 目に見えて再開するまで残るのが正しい）。
func jump(e pending.Entry) tea.Cmd {
	return func() tea.Msg {
		_ = zellij.GoToTab(e.Tab)

		agent := e.Agent
		if agent == "" {
			// agent を持たない古い pending は claude のものとして扱う。
			agent = "claude"
		}
		if e.Path != "" && ShouldClearOnJump(agent, detectionMethod(agent)) {
			_ = os.Remove(e.Path)
		}
		return jumpedMsg{}
	}
}

// ShouldClearOnJump は、ジャンプ時にそのエントリを消してよいかを返す。
//
// 消してよいのは hooks もスクリーン検出も持たないエージェントだけ。
// claude は hooks が、detection=screen のエージェントはスクリーン検出が
// 状態を畳むので、ここで消しても次のポーリングが作り直すだけになる。
func ShouldClearOnJump(agent, detection string) bool {
	if agent == "" || agent == "claude" {
		return false
	}
	return detection != "screen"
}

// detectionMethod はエージェントの状態追跡方法（hooks / screen）を返す。
// 設定は config.json にあり、解釈は task-lib.sh が持っている。
func detectionMethod(agent string) string {
	ctx, cancel := context.WithTimeout(context.Background(), AgentDetectionTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, "bash",
		paths.Script("agent-detection.sh"), agent).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func (m Model) Init() tea.Cmd {
	return tea.Sequence(restoreSession(), observe(m.session, m.dir, true))
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tickMsg:
		return m, observe(m.session, m.dir, true)

	case entriesMsg:
		// 番号入力を待っている間は一覧を固定する。並びが変わると、
		// 押した番号が別のタブを指してしまう。
		if !m.awaitingDelete {
			m.entries = msg.entries
		}
		// 次の予約は定期ポーリング由来の観測でだけ行う。こうしないと
		// ジャンプや削除のたびに鎖が 1 本ずつ増える。
		if msg.scheduleNext {
			return m, tick()
		}
		return m, nil

	case jumpedMsg:
		return m, observe(m.session, m.dir, false)

	case deleteResultMsg:
		return m.handleDeleteResult(msg)

	case promptTimeoutMsg:
		if int(msg) == m.promptGen {
			m.awaitingDelete = false
		}
		return m, nil

	case clearStatusMsg:
		if int(msg) == m.statusGen {
			m.status = ""
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

func (m Model) handleDeleteResult(msg deleteResultMsg) (tea.Model, tea.Cmd) {
	m.deleting = false
	m.statusGen++

	if msg.err != nil {
		m.status = "Upload failed. Deletion cancelled."
		return m, tea.Batch(clearStatus(m.statusGen), observe(m.session, m.dir, false))
	}

	// アップロード先の URL が返るので、タブが閉じる前に見えるよう少し残す。
	// 何も出ない場合はアップロードが無効か対象が無かったということ。
	m.status = msg.output
	return m, tea.Batch(clearStatus(m.statusGen), observe(m.session, m.dir, false))
}

func (m Model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if ui.IsQuit(msg) {
		return m, tea.Quit
	}

	// 削除の実行中は取り消せない。誤入力を拾わないよう伏せる。
	if m.deleting {
		return m, nil
	}

	key := msg.String()

	if m.awaitingDelete {
		m.awaitingDelete = false
		n, err := strconv.Atoi(key)
		if err != nil {
			return m, nil
		}
		e := EntryForIndex(m.entries, n-1)
		if e == nil {
			return m, nil
		}
		m.deleting = true
		return m, deleteTask(e.Tab)
	}

	if key == "d" || key == "D" {
		m.awaitingDelete = true
		m.promptGen++
		return m, promptTimeout(m.promptGen)
	}

	n, err := strconv.Atoi(key)
	if err != nil {
		return m, nil
	}
	if e := EntryForIndex(m.entries, n-1); e != nil {
		return m, jump(*e)
	}
	return m, nil
}

// prompt はフッターに出す一時メッセージを決める。
func (m Model) prompt() string {
	switch {
	case m.deleting:
		return "Deleting task..."
	case m.status != "":
		return m.status
	case m.awaitingDelete:
		return "Delete which number?"
	default:
		return ""
	}
}

func (m Model) View() tea.View {
	v := tea.NewView(Render(m.theme, m.session, m.entries, m.prompt(), m.width, m.height))
	v.AltScreen = true
	return v
}

// Run は dashboard サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	for _, a := range args {
		switch a {
		case "--once":
			once = true
		default:
			fmt.Fprintf(stderr, "conductor dashboard: unknown option %q\n", a)
			return 2
		}
	}

	session := pending.SessionName()
	th := ui.Current()

	if once {
		// 単発でも通常の起動と同じ手順を踏む。セッション復元とスクリーン
		// 検出まで含めて確かめられるようにするため。
		_ = exec.Command("bash", paths.Script("restore-session.sh")).Run()

		ctx, cancel := context.WithTimeout(context.Background(), DetectTimeout)
		defer cancel()
		_ = exec.CommandContext(ctx, "bash",
			paths.Script("screen-detect-tick.sh"), session).Run()
		fmt.Fprintln(stdout, Render(th, session, Snapshot(pending.Dir(session)), "", envWidth(), 0))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(session, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor dashboard: %v\n", err)
		return 1
	}
	return 0
}

func envWidth() int {
	if w, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && w > 0 {
		return w
	}
	return DefaultWidth
}
