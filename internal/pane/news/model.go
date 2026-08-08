package news

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/paths"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// PollInterval は保存済みニュースを読み直す間隔。bash 版と同じ 5 秒。
// fetch-news.sh が別プロセスで書き換える可能性があるため見張る。
const PollInterval = 5 * time.Second

// DefaultWidth は端末サイズを問い合わせられないときに使う幅。
const DefaultWidth = 44

// DateFormat はニュースファイル名の日付書式。
const DateFormat = "2006-01-02"

type tickMsg time.Time

// reloadedMsg は fetch-news.sh の完了を伝える。
type reloadedMsg struct{}

// Model は News ペインの状態。
type Model struct {
	dir     string
	theme   ui.Theme
	width   int
	height  int
	date    string
	items   []Item
	loading bool
}

// NewModel はその日のニュースを読んだ状態のモデルを返す。
func NewModel(dir string, th ui.Theme, width int) Model {
	date := today()
	return Model{
		dir:   dir,
		theme: th,
		width: width,
		date:  date,
		items: Load(dir, date),
	}
}

func today() string { return time.Now().Format(DateFormat) }

func tick() tea.Cmd {
	return tea.Tick(PollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

// reload は fetch-news.sh を強制実行する。取得の成否は問わない（失敗すれば
// 記事が増えないだけで、次のポーリングが今の内容を出し続ける）。
func reload() tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("bash", paths.Script("fetch-news.sh"), "--force").Run()
		return reloadedMsg{}
	}
}

// openURL は既定のブラウザで記事を開く。開けなくても描画は続ける。
//
// 起動したら必ず Wait で回収する。Go は子プロセスを自動では刈らないので、
// 常駐するこのペインで記事を開くたびにゾンビが 1 つずつ残ってしまう。
// 待つのはコマンド側の goroutine なので、描画は止まらない。
func openURL(url string) tea.Cmd {
	return func() tea.Msg {
		cmd := browserCommand(url)
		if cmd == nil {
			return nil
		}
		if err := cmd.Start(); err != nil {
			return nil
		}
		go func() { _ = cmd.Wait() }()
		return nil
	}
}

// browserCommand は URL を開くコマンドを組み立てる。bash 版と同じく
// open を優先し、無ければ xdg-open を使う。
func browserCommand(url string) *exec.Cmd {
	for _, name := range []string{"open", "xdg-open"} {
		if path, err := exec.LookPath(name); err == nil {
			return exec.Command(path, url)
		}
	}
	return nil
}

func (m Model) Init() tea.Cmd {
	return tick()
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tickMsg:
		// 日付をまたいでも翌日のファイルへ切り替わるよう毎回引き直す。
		m.date = today()
		m.items = Load(m.dir, m.date)
		return m, tick()

	case reloadedMsg:
		m.loading = false
		m.date = today()
		m.items = Load(m.dir, m.date)
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

func (m Model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	// raw モードでは ^C が SIGINT にならないので自分で受ける。
	if ui.IsQuit(msg) {
		return m, tea.Quit
	}

	switch key := msg.String(); key {
	case "r", "R":
		if m.loading {
			return m, nil
		}
		m.loading = true
		return m, reload()
	default:
		n, err := strconv.Atoi(key)
		if err != nil {
			return m, nil
		}
		if url := URLForIndex(m.items, n-1); url != "" {
			return m, openURL(url)
		}
		return m, nil
	}
}

func (m Model) View() tea.View {
	v := tea.NewView(Render(m.theme, m.items, m.date, m.loading, m.width, m.height))
	v.AltScreen = true
	return v
}

// Run は news サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	for _, a := range args {
		switch a {
		case "--once":
			once = true
		default:
			fmt.Fprintf(stderr, "conductor news: unknown option %q\n", a)
			return 2
		}
	}

	dir := paths.News()
	th := ui.Current()

	if once {
		date := today()
		fmt.Fprintln(stdout, Render(th, Load(dir, date), date, false, envWidth(), 0))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(dir, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor news: %v\n", err)
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
