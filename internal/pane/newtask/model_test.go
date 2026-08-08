package newtask

import (
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func key(s string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: rune(s[0]), Text: s}
}

func newModel() Model {
	return NewModel("s", ui.Resolve(ui.DefaultThemeName), 44)
}

// 失敗の知らせは必ず消える。消えないと status が立ったままになり、
// 「作成中は [n] を受け付けない」判定に永久に引っかかってペインが
// 操作不能になる。
func TestFailedCreationSchedulesStatusClear(t *testing.T) {
	m, cmd := newModel().Update(createdMsg{err: errAny{}})

	if got := m.(Model).status; got == "" {
		t.Error("status is empty; the failure must be shown")
	}
	if cmd == nil {
		t.Fatal("no command returned; the status clear must be scheduled")
	}

	// 予約された世代のメッセージで実際に消えること。
	// cmd() をそのまま呼ぶと tea.Tick が実時間だけ待つので、同じ
	// 世代番号のメッセージを直接送って確かめる。
	cleared, _ := m.(Model).Update(clearStatusMsg(m.(Model).statusGen))
	if got := cleared.(Model).status; got != "" {
		t.Errorf("status = %q, want it cleared", got)
	}
}

// 消えたあとは [n] がまた効く。
func TestPaneRecoversAfterFailure(t *testing.T) {
	m, _ := newModel().Update(createdMsg{err: errAny{}})
	cleared, _ := m.(Model).Update(clearStatusMsg(m.(Model).statusGen))

	_, cmd2 := cleared.(Model).Update(key("n"))
	if cmd2 == nil {
		t.Error("[n] did not start a new task after the failure was cleared")
	}
}

// 表示中は [n] を受け付けない。同じ手順が二重に走らないようにする。
func TestKeyIsIgnoredWhileStatusIsShown(t *testing.T) {
	m, _ := newModel().Update(createdMsg{err: errAny{}})

	_, cmd := m.(Model).Update(key("n"))
	if cmd != nil {
		t.Error("[n] was accepted while a status message was showing")
	}
}

// 古い世代のタイマーが、後から出したメッセージを消してはいけない。
func TestStaleClearStatusIsIgnored(t *testing.T) {
	m := newModel()
	m.status = "current"
	m.statusGen = 5

	got, _ := m.Update(clearStatusMsg(4))
	if s := got.(Model).status; s != "current" {
		t.Errorf("status = %q, want it kept when a stale timer fires", s)
	}
}

func TestCtrlCQuits(t *testing.T) {
	_, cmd := newModel().Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})

	if cmd == nil {
		t.Fatal("no command returned for ctrl+c")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Error("ctrl+c did not produce a quit")
	}
}

// 候補が揃ったら fzf を出す。候補作りは Update の外（Cmd 内）で行うので、
// Update に届くのは「出せ」という指示だけ。
func TestRunPickerStartsTheSelector(t *testing.T) {
	_, cmd := newModel().Update(runPickerMsg{
		kind: "dir", prompt: "Directory: ", options: []string{"/a", "/b"},
	})

	if cmd == nil {
		t.Error("no command returned; the selector must be started")
	}
}

// 候補が空なら選択に進まず、待機に戻す。
func TestRunPickerWithoutOptionsCancels(t *testing.T) {
	_, cmd := newModel().Update(runPickerMsg{kind: "dir", prompt: "Directory: "})
	if cmd == nil {
		t.Fatal("no command returned")
	}

	msg, ok := cmd().(pickedMsg)
	if !ok {
		t.Fatalf("got %T, want pickedMsg", cmd())
	}
	if msg.value != "" {
		t.Errorf("value = %q, want empty (cancelled)", msg.value)
	}
}

// キャンセル（空の選択）は待機に戻す。
func TestCancelledPickReturnsToIdle(t *testing.T) {
	m, cmd := newModel().Update(pickedMsg{kind: "dir"})

	if got := m.(Model).step; got != stepIdle {
		t.Errorf("step = %v, want stepIdle", got)
	}
	if cmd != nil {
		t.Error("a command was returned for a cancelled pick")
	}
}

func TestWindowSizeUpdatesWidth(t *testing.T) {
	m, _ := newModel().Update(tea.WindowSizeMsg{Width: 100, Height: 20})

	if got := m.(Model).width; got != 100 {
		t.Errorf("width = %d, want 100", got)
	}
}

type errAny struct{}

func (errAny) Error() string { return "failed" }
