package done

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/daily"
	"github.com/k-kudo-hub/claude-conductor/internal/paths"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// PollInterval は日次ログを読み直す間隔。bash 版と同じ 5 秒。
const PollInterval = 5 * time.Second

// RestorePromptTimeout は r を押してから番号入力を待つ時間。bash 版の
// `read -t 3` と同じ。放置した r が後のキー入力を巻き込まないようにする。
const RestorePromptTimeout = 3 * time.Second

// DefaultWidth は端末サイズを問い合わせられないときに使う幅。
const DefaultWidth = 44

// DateFormat は日次ログのファイル名に使う日付書式。
const DateFormat = "2006-01-02"

type tickMsg time.Time

// promptTimeoutMsg は番号入力待ちの打ち切り。世代番号を持ち、新しい r で
// 上書きされた古いタイムアウトを無視できるようにする。
type promptTimeoutMsg int

// restoredMsg は restore-task.sh の完了を伝える。
type restoredMsg struct{}

// Model は Done ペインの状態。
type Model struct {
	base    string
	theme   ui.Theme
	width   int
	records []daily.Record

	awaitingRestore bool
	promptGen       int
}

// NewModel はその日の完了タスクを読んだ状態のモデルを返す。
func NewModel(base string, th ui.Theme, width int) Model {
	return Model{
		base:    base,
		theme:   th,
		width:   width,
		records: load(base),
	}
}

// load はその日の完了タスクを、復元済みを除いて表示順に並べて返す。
func load(base string) []daily.Record {
	records := daily.Active(daily.Load(base, time.Now().Format(DateFormat)))
	daily.SortByCompletedAt(records)
	return records
}

func tick() tea.Cmd {
	return tea.Tick(PollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func promptTimeout(gen int) tea.Cmd {
	return tea.Tick(RestorePromptTimeout, func(time.Time) tea.Msg {
		return promptTimeoutMsg(gen)
	})
}

// restoreCommand は復元に使うコマンドを組み立てる。restore-task.sh は
// タブ名 / セッション / 完了時刻 の順で引数を取り、この 3 つで日次ログの
// エントリを一意に選ぶ。
func restoreCommand(r daily.Record) *exec.Cmd {
	return exec.Command("bash", paths.Script("restore-task.sh"),
		r.Tab, r.Session, r.CompletedAt)
}

// restore はタスクを Dashboard に戻す。復元できたかは restore-task.sh が
// 判断し、成功した場合だけ日次ログに restored が立つ。こちらは結果を待って
// 一覧を読み直すだけでよい。
func restore(r daily.Record) tea.Cmd {
	return func() tea.Msg {
		_ = restoreCommand(r).Run()
		return restoredMsg{}
	}
}

func (m Model) Init() tea.Cmd {
	return tick()
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case tickMsg:
		m.records = load(m.base)
		return m, tick()

	case restoredMsg:
		m.records = load(m.base)
		return m, nil

	case promptTimeoutMsg:
		if int(msg) == m.promptGen {
			m.awaitingRestore = false
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

func (m Model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	if !m.awaitingRestore {
		if key == "r" || key == "R" {
			m.awaitingRestore = true
			m.promptGen++
			return m, promptTimeout(m.promptGen)
		}
		return m, nil
	}

	// 番号入力待ち。数字以外はプロンプトを取り消す。
	m.awaitingRestore = false
	n, err := strconv.Atoi(key)
	if err != nil {
		return m, nil
	}
	if r := RecordForIndex(m.records, n-1); r != nil {
		return m, restore(*r)
	}
	return m, nil
}

func (m Model) View() tea.View {
	v := tea.NewView(Render(m.theme, m.records, m.awaitingRestore, m.width))
	v.AltScreen = true
	return v
}

// Run は done サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	for _, a := range args {
		switch a {
		case "--once":
			once = true
		default:
			fmt.Fprintf(stderr, "conductor done: unknown option %q\n", a)
			return 2
		}
	}

	base := paths.Daily()
	th := ui.Current()

	if once {
		fmt.Fprintln(stdout, Render(th, load(base), false, envWidth()))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(base, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor done: %v\n", err)
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
