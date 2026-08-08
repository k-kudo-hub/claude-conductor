package taskbar

import (
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func key(s string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: rune(s[0]), Text: s}
}

func newModel(t *testing.T) Model {
	t.Helper()
	return Model{
		tab:   "my-task",
		dir:   t.TempDir(),
		theme: ui.Resolve(ui.DefaultThemeName),
		width: 80,
	}
}

// Waiting の切り替え結果は tickMsg として返してはいけない。返すと
// その handler が次の tick を積み、押すたびにポーリングの鎖が増える。
func TestWaitingToggleDoesNotChainAnotherPoll(t *testing.T) {
	m, _ := newModel(t).Update(waitingToggledMsg{})

	if _, ok := m.(Model); !ok {
		t.Fatal("unexpected model type")
	}
	_, cmd := newModel(t).Update(waitingToggledMsg{})
	if cmd != nil {
		t.Error("a command was returned; the toggle must not schedule another poll")
	}
}

// 定期ポーリングだけが次の tick を積む。
func TestTickSchedulesTheNextPoll(t *testing.T) {
	_, cmd := newModel(t).Update(tickMsg{})

	if cmd == nil {
		t.Error("no command returned; the poll must keep running")
	}
}

func TestPressingWTogglesWaiting(t *testing.T) {
	_, cmd := newModel(t).Update(key("w"))

	if cmd == nil {
		t.Error("no command returned for w")
	}
}

// dd は 2 打鍵で確定する。1 打鍵目では削除を始めない。
func TestDeleteNeedsTwoPresses(t *testing.T) {
	m, cmd := newModel(t).Update(key("d"))

	got := m.(Model)
	if !got.awaitingConfirm {
		t.Error("awaitingConfirm = false, want true after the first d")
	}
	if got.deleting {
		t.Error("deleting = true after a single d")
	}
	if cmd == nil {
		t.Error("no command returned; the confirm timeout must be scheduled")
	}

	m2, cmd2 := got.Update(key("d"))
	if !m2.(Model).deleting {
		t.Error("deleting = false, want true after the second d")
	}
	if cmd2 == nil {
		t.Error("no command returned; deletion must start")
	}
}

// 別のキーが挟まれば確認は取り消す。
func TestOtherKeyCancelsDeleteConfirm(t *testing.T) {
	m, _ := newModel(t).Update(key("d"))
	m2, cmd := m.(Model).Update(key("m"))

	if m2.(Model).awaitingConfirm {
		t.Error("awaitingConfirm = true, want false")
	}
	if m2.(Model).deleting {
		t.Error("deleting = true, want false")
	}
	if cmd != nil {
		t.Error("a command was returned for a cancelled confirm")
	}
}

func TestStaleConfirmTimeoutIsIgnored(t *testing.T) {
	m, _ := newModel(t).Update(key("d"))
	stale := m.(Model).confirmGen

	m, _ = m.(Model).Update(key("m")) // いったん解除
	m, _ = m.(Model).Update(key("d")) // 押し直し
	m, _ = m.(Model).Update(confirmTimeoutMsg(stale))

	if !m.(Model).awaitingConfirm {
		t.Error("a stale timeout cleared the current confirm")
	}
}

func TestCtrlCQuits(t *testing.T) {
	_, cmd := newModel(t).Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})

	if cmd == nil {
		t.Fatal("no command returned for ctrl+c")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Error("ctrl+c did not produce a quit")
	}
}

func TestPromptPrecedence(t *testing.T) {
	m := newModel(t)

	m.deleting = true
	m.status = "result"
	m.awaitingConfirm = true
	if got := m.prompt(); got != "Deleting task..." {
		t.Errorf("prompt = %q, want the deleting message", got)
	}

	m.deleting = false
	if got := m.prompt(); got != "result" {
		t.Errorf("prompt = %q, want the status message", got)
	}

	m.status = ""
	if got := m.prompt(); got != "Press d again to delete this tab" {
		t.Errorf("prompt = %q, want the confirm prompt", got)
	}

	m.awaitingConfirm = false
	if got := m.prompt(); got != "" {
		t.Errorf("prompt = %q, want empty", got)
	}
}
