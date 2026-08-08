package taskbar

import (
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
)

// PollInterval は自分の状態を見直す間隔。bash 版と同じ 2 秒。
const PollInterval = 2 * time.Second

// DeleteConfirmTimeout は 1 度目の d から 2 度目を待つ時間。bash 版の
// `read -t 2` と同じ。
const DeleteConfirmTimeout = 2 * time.Second

// StatusDuration は削除結果を出しておく時間。
const StatusDuration = 2 * time.Second

// DefaultWidth は端末サイズを問い合わせられないときに使う幅。
const DefaultWidth = 80

type tickMsg time.Time

type confirmTimeoutMsg int

type clearStatusMsg int

// deleteResultMsg は task-delete.sh の結果。err が非 nil なら
// アップロードに失敗しており、タブは残っている。
type deleteResultMsg struct {
	output string
	err    error
}

// Model は制御バーの状態。
type Model struct {
	tab     string
	session string
	dir     string
	theme   ui.Theme
	width   int

	waiting bool

	awaitingConfirm bool
	confirmGen      int

	deleting  bool
	status    string
	statusGen int
}

// NewModel は自分のタブの状態を読んだモデルを返す。
func NewModel(tab, session string, th ui.Theme, width int) Model {
	dir := pending.Dir(session)
	return Model{
		tab:     tab,
		session: session,
		dir:     dir,
		theme:   th,
		width:   width,
		waiting: isWaiting(dir, tab),
	}
}

// isWaiting は自分のタブが外部応答待ちかを返す。
func isWaiting(dir, tab string) bool {
	for _, e := range pending.Load(dir) {
		if e.Tab == tab {
			return e.Event == WaitingEvent
		}
	}
	return false
}

func tick() tea.Cmd {
	return tea.Tick(PollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func confirmTimeout(gen int) tea.Cmd {
	return tea.Tick(DeleteConfirmTimeout, func(time.Time) tea.Msg {
		return confirmTimeoutMsg(gen)
	})
}

func clearStatus(gen int) tea.Cmd {
	return tea.Tick(StatusDuration, func(time.Time) tea.Msg {
		return clearStatusMsg(gen)
	})
}

func goToMain() tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("zellij", "action", "go-to-tab-name", "Main").Run()
		return nil
	}
}

// waitingToggledMsg は Waiting の切り替え完了。tickMsg を返すと
// その handler が次の tick を積むため、押すたびにポーリングの鎖が
// 1 本ずつ増えてしまう。専用の型にして状態の読み直しだけを行う。
type waitingToggledMsg struct{}

func toggleWaiting(tab string) tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("bash", paths.Script("waiting-toggle.sh"), tab).Run()
		return waitingToggledMsg{}
	}
}

// deleteTask は Dashboard の d+番号 と同じ共通の削除経路を使う。
func deleteTask(tab string) tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("bash", paths.Script("task-delete.sh"), tab).Output()
		return deleteResultMsg{output: strings.TrimSpace(string(out)), err: err}
	}
}

func (m Model) Init() tea.Cmd { return tick() }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case tickMsg:
		m.waiting = isWaiting(m.dir, m.tab)
		return m, tick()

	case waitingToggledMsg:
		// 次の tick は既に走っているので、ここでは積まない。
		m.waiting = isWaiting(m.dir, m.tab)
		return m, nil

	case confirmTimeoutMsg:
		if int(msg) == m.confirmGen {
			m.awaitingConfirm = false
		}
		return m, nil

	case clearStatusMsg:
		if int(msg) == m.statusGen {
			m.status = ""
		}
		return m, nil

	case deleteResultMsg:
		m.deleting = false
		m.statusGen++
		if msg.err != nil {
			m.status = "Upload failed. Deletion cancelled."
			return m, clearStatus(m.statusGen)
		}
		// 削除に成功していれば、このタブごとまもなく閉じられる。
		m.status = msg.output
		return m, tea.Sequence(clearStatus(m.statusGen), tea.Quit)

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

func (m Model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if ui.IsQuit(msg) {
		return m, tea.Quit
	}

	if m.deleting {
		return m, nil
	}

	key := msg.String()

	if m.awaitingConfirm {
		m.awaitingConfirm = false
		if key == "d" {
			m.deleting = true
			return m, deleteTask(m.tab)
		}
		return m, nil
	}

	switch key {
	case "m":
		return m, goToMain()
	case "w":
		return m, toggleWaiting(m.tab)
	case "d":
		m.awaitingConfirm = true
		m.confirmGen++
		return m, confirmTimeout(m.confirmGen)
	}
	return m, nil
}

// prompt はキーヒントの代わりに出す一時メッセージを決める。
func (m Model) prompt() string {
	switch {
	case m.deleting:
		return "Deleting task..."
	case m.status != "":
		return m.status
	case m.awaitingConfirm:
		return "Press d again to delete this tab"
	default:
		return ""
	}
}

func (m Model) View() tea.View {
	// 1 行しか持たないので代替画面は使わない。タスクタブ側の出力を
	// 覆い隠さないようにする。
	return tea.NewView(Render(m.theme, m.waiting, m.prompt(), m.width))
}

// Run は task-bar サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	var tab string
	for _, a := range args {
		switch {
		case a == "--once":
			once = true
		case strings.HasPrefix(a, "-"):
			fmt.Fprintf(stderr, "conductor task-bar: unknown option %q\n", a)
			return 2
		default:
			tab = a
		}
	}

	if tab == "" {
		tab = os.Getenv("TASK_TAB_NAME")
	}
	if tab == "" {
		tab = "unknown"
	}

	session := pending.SessionName()
	th := ui.Current()

	if once {
		dir := pending.Dir(session)
		fmt.Fprintln(stdout, Render(th, isWaiting(dir, tab), "", envWidth()))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(tab, session, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor task-bar: %v\n", err)
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
