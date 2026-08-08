package newtask

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/config"
	"github.com/k-kudo-hub/claude-conductor/internal/paths"
	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
	"github.com/k-kudo-hub/claude-conductor/internal/zellij"
)

// DefaultWidth は端末サイズを問い合わせられないときに使う幅。
const DefaultWidth = 44

// step はタスク作成の進行段階。
type step int

const (
	stepIdle step = iota
	stepName
)

// pickedMsg は fzf の選択結果。value が空ならキャンセル。
type pickedMsg struct {
	kind  string
	value string
}

// createdMsg はタスク作成の完了。
type createdMsg struct{ err error }

// clearStatusMsg は進行表示の消去。
type clearStatusMsg struct{}

// Model は New Task ペインの状態。
type Model struct {
	session string
	theme   ui.Theme
	width   int

	step   step
	status string
	input  textinput.Model

	// 選択済みの内容。名前入力まで持ち越す。
	dir      string
	taskType string
	agent    string
}

// NewModel は待機状態のモデルを返す。
func NewModel(session string, th ui.Theme, width int) Model {
	in := textinput.New()
	in.Prompt = ""
	return Model{
		session: session,
		theme:   th,
		width:   width,
		input:   in,
	}
}

func (m Model) Init() tea.Cmd { return nil }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case pickedMsg:
		return m.handlePicked(msg)

	case createdMsg:
		m.step = stepIdle
		if msg.err != nil {
			m.status = "Failed to create the task."
		} else {
			m.status = ""
		}
		return m, nil

	case clearStatusMsg:
		m.status = ""
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(msg)
	}

	if m.step == stepName {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if m.step == stepName {
		switch msg.String() {
		case "enter":
			name := ResolveName(DefaultName(m.dir, m.taskType), m.input.Value())
			name = UniqueTabName(name, zellij.QueryTabNames())
			m.step = stepIdle
			m.input.Blur()
			m.status = fmt.Sprintf("Creating %s task '%s'...", m.taskType, name)
			return m, createTask(m.dir, m.taskType, name, m.agent)
		case "esc":
			m.step = stepIdle
			m.input.Blur()
			m.status = ""
			return m, nil
		}

		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}

	// 作成中は次の [n] を受け付けない。同じ手順が二重に走らないようにする。
	if m.status != "" {
		return m, nil
	}

	if s := msg.String(); s == "n" || s == "N" {
		return m, pickDirectory()
	}
	return m, nil
}

// handlePicked は fzf の選択結果を受けて次の段階へ進める。どの段階でも
// 空（キャンセル）なら待機に戻す。
func (m Model) handlePicked(msg pickedMsg) (tea.Model, tea.Cmd) {
	if msg.value == "" {
		m.step = stepIdle
		m.status = ""
		return m, nil
	}

	switch msg.kind {
	case "dir":
		m.dir = msg.value
		return m, pickTaskType()

	case "type":
		m.taskType = ParseChoice(msg.value)
		cfg, err := config.Load()
		if err != nil {
			m.status = "Failed to read the config."
			return m, nil
		}
		// エージェントが 1 つも設定されていなければ、従来どおり単一
		// エージェントの経路で作る（エージェント名は空のまま）。
		names := cfg.AgentNames()
		switch len(names) {
		case 0:
			return m.startNameInput(cfg)
		case 1:
			m.agent = names[0]
			return m.startNameInput(cfg)
		default:
			return m, pickAgent(names)
		}

	case "agent":
		m.agent = msg.value
		cfg, err := config.Load()
		if err != nil {
			m.status = "Failed to read the config."
			return m, nil
		}
		return m.startNameInput(cfg)
	}

	return m, nil
}

// startNameInput は名前入力に進む。設定で入力を省く場合はそのまま作成する。
func (m Model) startNameInput(cfg *config.Config) (tea.Model, tea.Cmd) {
	def := DefaultName(m.dir, m.taskType)

	if cfg.SkipTaskNameInput {
		name := UniqueTabName(def, zellij.QueryTabNames())
		m.status = fmt.Sprintf("Creating %s task '%s'...", m.taskType, name)
		return m, createTask(m.dir, m.taskType, name, m.agent)
	}

	// 候補を初期値として編集できる状態で出す。bash 3.2 には read -i が
	// 無く、シェル版は候補の提示と入力受け取りを分けていた。
	m.step = stepName
	m.input.SetValue(def)
	m.input.CursorEnd()
	return m, m.input.Focus()
}

// pickDirectory は fd で候補を作り fzf に選ばせる。
func pickDirectory() tea.Cmd {
	cfg, err := config.Load()
	if err != nil {
		return func() tea.Msg { return pickedMsg{kind: "dir"} }
	}

	dirs := existingDirs(cfg.ExpandedSearchDirs())
	if len(dirs) == 0 {
		return func() tea.Msg { return pickedMsg{kind: "dir"} }
	}

	args := append([]string{"--type", "d", "--max-depth", strconv.Itoa(cfg.Depth()), "."}, dirs...)
	out, err := exec.Command("fd", args...).Output()
	if err != nil {
		return func() tea.Msg { return pickedMsg{kind: "dir"} }
	}

	return pick("dir", "Directory: ", splitLines(string(out)))
}

func pickTaskType() tea.Cmd {
	cfg, err := config.Load()
	if err != nil {
		return func() tea.Msg { return pickedMsg{kind: "type"} }
	}

	names := cfg.TaskTypeNames()
	choices := make([]string, 0, len(names))
	for _, name := range names {
		choices = append(choices, FormatChoice(name, cfg.TaskTypes[name].Description))
	}
	return pick("type", "Task type: ", choices)
}

func pickAgent(names []string) tea.Cmd {
	return pick("agent", "Agent: ", names)
}

// pick は fzf を前面で走らせて 1 つ選ばせる。fzf は UI を端末へ直接描くので、
// 選択結果だけを受け取ればよい。
func pick(kind, prompt string, options []string) tea.Cmd {
	if len(options) == 0 {
		return func() tea.Msg { return pickedMsg{kind: kind} }
	}

	var out bytes.Buffer
	c := exec.Command("fzf", "--prompt="+prompt)
	c.Stdin = strings.NewReader(strings.Join(options, "\n"))
	c.Stdout = &out

	return tea.ExecProcess(c, func(error) tea.Msg {
		// 非ゼロ終了はキャンセル。空文字を返して待機に戻す。
		return pickedMsg{kind: kind, value: strings.TrimSpace(out.String())}
	})
}

// createTask はタスクのタブを作る。レイアウト適用やレジストリ登録を含む
// 手順は task-lib.sh の create_task が持っている。
func createTask(dir, taskType, name, agent string) tea.Cmd {
	return func() tea.Msg {
		err := exec.Command("bash", paths.Script("task-create.sh"),
			dir, taskType, name, "", agent).Run()
		return createdMsg{err: err}
	}
}

func existingDirs(dirs []string) []string {
	out := make([]string, 0, len(dirs))
	for _, d := range dirs {
		if info, err := os.Stat(d); err == nil && info.IsDir() {
			out = append(out, d)
		}
	}
	return out
}

func splitLines(s string) []string {
	var lines []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	return lines
}

func (m Model) View() tea.View {
	if m.step == stepName {
		v := tea.NewView(renderNameInput(m.theme, m.input.View(), m.width))
		v.AltScreen = true
		v.Cursor = m.input.Cursor()
		return v
	}

	v := tea.NewView(Render(m.theme, m.session, m.status, m.width))
	v.AltScreen = true
	return v
}

// Run は new-task サブコマンドの本体。
func Run(args []string, stdout, stderr io.Writer) int {
	once := false
	for _, a := range args {
		switch a {
		case "--once":
			once = true
		default:
			fmt.Fprintf(stderr, "conductor new-task: unknown option %q\n", a)
			return 2
		}
	}

	session := pending.SessionName()
	th := ui.Current()

	if once {
		fmt.Fprintln(stdout, Render(th, session, "", envWidth()))
		return 0
	}

	if _, err := tea.NewProgram(NewModel(session, th, envWidth())).Run(); err != nil {
		fmt.Fprintf(stderr, "conductor new-task: %v\n", err)
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
