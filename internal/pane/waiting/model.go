package waiting

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// PollInterval は pending ファイルを読み直す間隔。bash 版と同じ 2 秒。
// hooks はファイルを書くだけで通知はしてこないので、ここは実際に
// ポーリングするしかない。
const PollInterval = 2 * time.Second

// DefaultWidth は端末サイズを問い合わせられないとき（--once 実行など）に
// 使う幅。
const DefaultWidth = 40

type tickMsg time.Time

// Model は Waiting ペインの状態。
type Model struct {
	dir     string
	theme   ui.Theme
	width   int
	height  int
	entries []pending.Entry
}

// NewModel は pending ディレクトリを読んだ状態のモデルを返す。
func NewModel(dir string, th ui.Theme, width int) Model {
	return Model{
		dir:     dir,
		theme:   th,
		width:   width,
		entries: load(dir),
	}
}

func load(dir string) []pending.Entry {
	return pending.FilterByEvent(pending.Load(dir), Event)
}

func tick() tea.Cmd {
	return tea.Tick(PollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
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
		m.entries = load(m.dir)
		return m, tick()
	case tea.KeyPressMsg:
		// 表示専用のペインだが、終了だけは受け付ける。raw モードでは
		// ^C が SIGINT にならないため、これが無いと Zellij の外で
		// 起動したときにキーボードから抜けられない。
		if ui.IsQuit(msg) {
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m Model) View() tea.View {
	// 代替画面には入らない。Zellij は代替画面のペインを別扱いし、
	// ペイン境界のドラッグやタブバーのクリックが効かなくなる。
	// bash 版も alternate screen は使わず、同じ位置に上書きしていた。
	return tea.NewView(Render(m.theme, m.entries, m.width, m.height))
}

// Run は waiting サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	for _, a := range args {
		switch a {
		case "--once":
			once = true
		default:
			fmt.Fprintf(stderr, "conductor waiting: unknown option %q\n", a)
			return 2
		}
	}

	dir := pending.Dir(pending.SessionName())
	th := ui.Current()

	// --once は test.sh から実バイナリの出力を確かめるための単発描画。
	// TTY を持たない文脈で走るので Bubble Tea は起動しない。
	if once {
		fmt.Fprintln(stdout, Render(th, load(dir), envWidth(), 0))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(dir, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor waiting: %v\n", err)
		return 1
	}
	return 0
}

// envWidth は COLUMNS があればそれを、無ければ既定幅を返す。実端末では
// 起動直後に WindowSizeMsg が届いて上書きされる。
func envWidth() int {
	if w, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && w > 0 {
		return w
	}
	return DefaultWidth
}
