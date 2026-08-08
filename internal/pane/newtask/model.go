package newtask

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

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

// 名前入力欄の位置。枠の "│ " と、その上のラベル行のぶん。
const (
	nameFieldLeft = 2
	nameFieldTop  = 2
	// 左右の枠と余白で使う桁数。
	nameFieldOverhead = 4
)

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

// clearStatusMsg は進行表示の消去。世代番号で古いタイマーを弾く。
type clearStatusMsg int

// StatusDuration は失敗の知らせを出しておく時間。これを過ぎたら消して
// 操作を受け付ける状態に戻す。消さないと status が立ったままになり、
// handleKey の「作成中は [n] を受け付けない」判定に永久に引っかかる。
const StatusDuration = 3 * time.Second

// Model は New Task ペインの状態。
type Model struct {
	session string
	theme   ui.Theme
	width   int
	height  int

	step      step
	status    string
	statusGen int
	input     textinput.Model

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
		m.height = msg.Height
		return m, nil

	case runPickerMsg:
		return m, pick(msg.kind, msg.prompt, msg.options)

	case pickedMsg:
		return m.handlePicked(msg)

	case createdMsg:
		m.step = stepIdle
		if msg.err != nil {
			return m.withStatus("Failed to create the task.")
		}
		m.status = ""
		return m, nil

	case clearStatusMsg:
		if int(msg) == m.statusGen {
			m.status = ""
		}
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
	if ui.IsQuit(msg) {
		return m, tea.Quit
	}

	if m.step == stepName {
		switch msg.String() {
		case "enter":
			name := ResolveName(DefaultName(m.dir, m.taskType), m.input.Value())
			m.step = stepIdle
			m.input.Blur()
			m.status = fmt.Sprintf("Creating %s task...", m.taskType)
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
			return m.withStatus("Failed to read the config.")
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
			return m.withStatus("Failed to read the config.")
		}
		return m.startNameInput(cfg)
	}

	return m, nil
}

// withStatus は一時メッセージを表示し、消去も同時に予約する。予約を
// 忘れるとメッセージが残り続け、[n] が受け付けられなくなる。
func (m Model) withStatus(text string) (tea.Model, tea.Cmd) {
	m.status = text
	m.statusGen++
	gen := m.statusGen
	return m, tea.Tick(StatusDuration, func(time.Time) tea.Msg {
		return clearStatusMsg(gen)
	})
}

// startNameInput は名前入力に進む。設定で入力を省く場合はそのまま作成する。
func (m Model) startNameInput(cfg *config.Config) (tea.Model, tea.Cmd) {
	def := DefaultName(m.dir, m.taskType)

	if cfg.SkipTaskNameInput {
		m.status = fmt.Sprintf("Creating %s task...", m.taskType)
		return m, createTask(m.dir, m.taskType, def, m.agent)
	}

	// 候補を初期値として編集できる状態で出す。bash 3.2 には read -i が
	// 無く、シェル版は候補の提示と入力受け取りを分けていた。
	m.step = stepName
	// 枠の内側に収まる幅を与える。設定しないと長い名前がスクロールせず、
	// 枠に切り取られて入力中の文字が見えなくなる。
	m.input.SetWidth(max(m.width-nameFieldOverhead, 1))
	m.input.SetValue(def)
	m.input.CursorEnd()
	return m, m.input.Focus()
}

// pickDirectory は fd で候補を作り fzf に選ばせる。
//
// 候補作りは tea.Cmd の中で行う。Update から直に呼ぶと、fd が走っている
// 間だけ描画もキー入力も止まる（search_dirs が広いと体感できる長さになる）。
func pickDirectory() tea.Cmd {
	return func() tea.Msg {
		cfg, err := config.Load()
		if err != nil {
			return pickedMsg{kind: "dir"}
		}

		dirs := existingDirs(cfg.ExpandedSearchDirs())
		if len(dirs) == 0 {
			return pickedMsg{kind: "dir"}
		}

		args := append([]string{"--type", "d", "--max-depth", strconv.Itoa(cfg.Depth()), "."}, dirs...)
		out, err := exec.Command("fd", args...).Output()
		if err != nil {
			return pickedMsg{kind: "dir"}
		}
		return runPickerMsg{kind: "dir", prompt: "Directory: ", options: splitLines(string(out))}
	}
}

func pickTaskType() tea.Cmd {
	return func() tea.Msg {
		cfg, err := config.Load()
		if err != nil {
			return pickedMsg{kind: "type"}
		}

		names := cfg.TaskTypeNames()
		choices := make([]string, 0, len(names))
		for _, name := range names {
			choices = append(choices, FormatChoice(name, cfg.TaskTypes[name].Description))
		}
		return runPickerMsg{kind: "type", prompt: "Task type: ", options: choices}
	}
}

// runPickerMsg は候補が揃ったので fzf を出す、という指示。fzf の起動は
// tea.ExecProcess でなければならず、これは Cmd の戻り値としてしか
// 扱えないため、候補作りと起動を 2 段に分ける。
type runPickerMsg struct {
	kind    string
	prompt  string
	options []string
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
//
// タブ名の一意化もここで行う。zellij への問い合わせは応答しないことが
// あり（上限 3 秒）、Update から直に呼ぶとその間ペインが止まる。
func createTask(dir, taskType, name, agent string) tea.Cmd {
	return func() tea.Msg {
		unique := UniqueTabName(name, zellij.QueryTabNames())
		err := exec.Command("bash", paths.Script("task-create.sh"),
			dir, taskType, unique, "", agent).Run()
		if err == nil {
			// 作ったタブへ移る。create_task は new-tab のあと、その
			// タブの中で pane を足して focus-previous-pane まで行うが、
			// どのタブを見せるかはここで明示する。作成の直後は、その
			// タスクで作業を始めたいはずなので。
			_ = zellij.GoToTab(unique)
		}
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
	// 代替画面には入らない（Zellij のペイン境界ドラッグとタブ操作を
	// 妨げるため）。詳細は waiting ペインの同じ箇所を参照。
	if m.step == stepName {
		v := tea.NewView(renderNameInput(m.theme, m.input.View(), m.width, m.height))
		// textinput が返すのは入力欄内の座標。実際の欄は枠の中の
		// 2 行目・2 桁目に描くので、その分ずらさないと罫線の上に出る。
		if c := m.input.Cursor(); c != nil {
			c.X += nameFieldLeft
			c.Y += nameFieldTop
			v.Cursor = c
		}
		return v
	}

	return tea.NewView(Render(m.theme, m.session, m.status, m.width, m.height))
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
		fmt.Fprintln(stdout, Render(th, session, "", envWidth(), 0))
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
