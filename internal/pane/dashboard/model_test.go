package dashboard

import (
	"errors"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func key(s string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: rune(s[0]), Text: s}
}

func modelWithEntries() Model {
	return Model{
		session: "s",
		theme:   ui.Resolve(ui.DefaultThemeName),
		width:   60,
		entries: []pending.Entry{
			{Tab: "api-feature", Event: "Notification", Time: "18:05:31"},
			{Tab: "web-fix", Event: "Stop", Time: "19:20:01"},
		},
	}
}

func TestPressingDEntersDeletePrompt(t *testing.T) {
	m, cmd := modelWithEntries().Update(key("d"))

	got := m.(Model)
	if !got.awaitingDelete {
		t.Error("awaitingDelete = false, want true after pressing d")
	}
	if got.prompt() != "Delete which number?" {
		t.Errorf("prompt = %q, want the delete prompt", got.prompt())
	}
	if cmd == nil {
		t.Error("no command returned; the prompt timeout must be scheduled")
	}
}

func TestDeleteSequenceStartsDeletion(t *testing.T) {
	m, _ := modelWithEntries().Update(key("d"))
	m, cmd := m.(Model).Update(key("1"))

	got := m.(Model)
	if got.awaitingDelete {
		t.Error("awaitingDelete = true, want false once the number was given")
	}
	if !got.deleting {
		t.Error("deleting = false, want true")
	}
	if cmd == nil {
		t.Error("no command returned; deletion must be started")
	}
}

// 一覧に無い番号では削除を始めない。取り消せない操作なので、
// 押し間違いは何も起こさないのが正しい。
func TestDeleteOutOfRangeDoesNothing(t *testing.T) {
	m, _ := modelWithEntries().Update(key("d"))
	m, cmd := m.(Model).Update(key("9"))

	got := m.(Model)
	if got.deleting {
		t.Error("deleting = true, want false for an out-of-range number")
	}
	if cmd != nil {
		t.Error("a command was returned for an out-of-range number")
	}
}

func TestNonDigitCancelsDeletePrompt(t *testing.T) {
	m, _ := modelWithEntries().Update(key("d"))
	m, cmd := m.(Model).Update(key("x"))

	got := m.(Model)
	if got.awaitingDelete {
		t.Error("awaitingDelete = true, want false after a non-digit")
	}
	if got.deleting {
		t.Error("deleting = true, want false")
	}
	if cmd != nil {
		t.Error("a command was returned for a non-digit key")
	}
}

func TestDigitWithoutDJumps(t *testing.T) {
	m, cmd := modelWithEntries().Update(key("1"))

	if m.(Model).deleting {
		t.Error("deleting = true, want false for a bare digit")
	}
	if cmd == nil {
		t.Error("no command returned; a bare digit must jump to the tab")
	}
}

func TestJumpOutOfRangeDoesNothing(t *testing.T) {
	_, cmd := modelWithEntries().Update(key("9"))

	if cmd != nil {
		t.Error("a command was returned for an out-of-range jump")
	}
}

// 削除の実行中はキーを受け付けない。アップロード待ちの数秒に
// 次の削除が重なると、消す対象を取り違える。
func TestKeysAreIgnoredWhileDeleting(t *testing.T) {
	m := modelWithEntries()
	m.deleting = true

	got, cmd := m.Update(key("1"))
	if cmd != nil {
		t.Error("a command was returned while a deletion was in flight")
	}
	if got.(Model).awaitingDelete {
		t.Error("awaitingDelete = true, want false while deleting")
	}
}

// アップロードが失敗したら削除は成立していない。その旨を表示する。
func TestFailedDeletionShowsCancelledStatus(t *testing.T) {
	m := modelWithEntries()
	m.deleting = true

	got, cmd := m.Update(deleteResultMsg{err: errors.New("upload failed")})

	model := got.(Model)
	if model.deleting {
		t.Error("deleting = true, want false once the result arrived")
	}
	if model.status != "Upload failed. Deletion cancelled." {
		t.Errorf("status = %q, want the cancellation message", model.status)
	}
	if cmd == nil {
		t.Error("no command returned; the status must be cleared and the list refreshed")
	}
}

// 成功時はアップロード先を少しのあいだ出す。タブが閉じる前に確認できるように。
func TestSuccessfulDeletionShowsUploadResult(t *testing.T) {
	m := modelWithEntries()
	m.deleting = true

	got, _ := m.Update(deleteResultMsg{output: "https://example.com/log/123"})

	model := got.(Model)
	if model.status != "https://example.com/log/123" {
		t.Errorf("status = %q, want the upload result", model.status)
	}
	if model.prompt() != "https://example.com/log/123" {
		t.Errorf("prompt = %q, want the upload result", model.prompt())
	}
}

func TestStatusIsClearedByItsOwnGeneration(t *testing.T) {
	m := modelWithEntries()
	m.deleting = true

	got, _ := m.Update(deleteResultMsg{output: "result"})
	model := got.(Model)
	gen := model.statusGen

	got, _ = model.Update(clearStatusMsg(gen))
	if s := got.(Model).status; s != "" {
		t.Errorf("status = %q, want empty after its own timer fired", s)
	}
}

// 古い世代のタイマーが、後から出したメッセージを消してはいけない。
func TestStaleClearStatusIsIgnored(t *testing.T) {
	m := modelWithEntries()
	m.status = "current"
	m.statusGen = 5

	got, _ := m.Update(clearStatusMsg(4))
	if s := got.(Model).status; s != "current" {
		t.Errorf("status = %q, want it kept when a stale timer fires", s)
	}
}

func TestStaleDeletePromptTimeoutIsIgnored(t *testing.T) {
	m, _ := modelWithEntries().Update(key("d"))
	stale := m.(Model).promptGen

	m, _ = m.(Model).Update(key("x"))
	m, _ = m.(Model).Update(key("d"))
	m, _ = m.(Model).Update(promptTimeoutMsg(stale))

	if !m.(Model).awaitingDelete {
		t.Error("a stale timeout cleared the current delete prompt")
	}
}

// 表示中のメッセージは削除プロンプトより優先する。直前の操作結果が
// 読めないまま消えないようにする。
func TestPromptPrecedence(t *testing.T) {
	m := modelWithEntries()

	m.deleting = true
	m.status = "result"
	m.awaitingDelete = true
	if got := m.prompt(); got != "Deleting task..." {
		t.Errorf("prompt = %q, want the deleting message while a deletion is in flight", got)
	}

	m.deleting = false
	if got := m.prompt(); got != "result" {
		t.Errorf("prompt = %q, want the status message", got)
	}

	m.status = ""
	if got := m.prompt(); got != "Delete which number?" {
		t.Errorf("prompt = %q, want the delete prompt", got)
	}

	m.awaitingDelete = false
	if got := m.prompt(); got != "" {
		t.Errorf("prompt = %q, want empty", got)
	}
}

func TestEntriesMsgSchedulesNextPoll(t *testing.T) {
	entries := []pending.Entry{{Tab: "a", Event: "Notification"}}

	m, cmd := modelWithEntries().Update(entriesMsg{entries: entries, scheduleNext: true})

	if len(m.(Model).entries) != 1 {
		t.Errorf("entries = %d, want 1", len(m.(Model).entries))
	}
	if cmd == nil {
		t.Error("no command returned; the next poll must be scheduled after an observation")
	}
}

// ジャンプや削除の直後の観測では次を予約しない。予約するとポーリングの
// 鎖が1本ずつ増え、スクリーン検出の実行頻度が上がってしまう。
func TestOneOffObservationDoesNotSchedulePoll(t *testing.T) {
	entries := []pending.Entry{{Tab: "a", Event: "Notification"}}

	m, cmd := modelWithEntries().Update(entriesMsg{entries: entries, scheduleNext: false})

	if len(m.(Model).entries) != 1 {
		t.Errorf("entries = %d, want 1", len(m.(Model).entries))
	}
	if cmd != nil {
		t.Error("a command was returned; a one-off observation must not chain another poll")
	}
}

// 番号入力を待っている間は一覧を固定する。並びが変わると押した番号が
// 別のタブを指す。
func TestListIsFrozenWhileAwaitingDelete(t *testing.T) {
	prompted, _ := modelWithEntries().Update(key("d"))
	m := prompted.(Model)
	before := len(m.entries)

	after, _ := m.Update(entriesMsg{entries: nil, scheduleNext: true})
	if len(after.(Model).entries) != before {
		t.Errorf("entries = %d, want %d kept while the prompt is open",
			len(after.(Model).entries), before)
	}
}

func TestCtrlCQuits(t *testing.T) {
	_, cmd := modelWithEntries().Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})

	if cmd == nil {
		t.Fatal("no command returned for ctrl+c")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Errorf("ctrl+c did not produce a quit")
	}
}

// ジャンプで pending を消してよいのは、hooks もスクリーン検出も持たない
// エージェントだけ。claude は hooks が、detection=screen のエージェントは
// スクリーン検出が状態を畳むので、ここで消すと次のポーリングが作り直す。
func TestShouldClearOnJump(t *testing.T) {
	cases := []struct {
		name      string
		agent     string
		detection string
		want      bool
	}{
		{"hook-less agent", "somecli", "hooks", true},
		{"hook-less agent, detection unknown", "somecli", "", true},
		{"screen agent", "codex", "screen", false},
		{"claude", "claude", "hooks", false},
		{"agent-less entry is treated as claude", "", "", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ShouldClearOnJump(tc.agent, tc.detection); got != tc.want {
				t.Errorf("ShouldClearOnJump(%q, %q) = %v, want %v",
					tc.agent, tc.detection, got, tc.want)
			}
		})
	}
}

func TestWindowSizeUpdatesWidth(t *testing.T) {
	m, _ := modelWithEntries().Update(tea.WindowSizeMsg{Width: 100, Height: 20})

	if got := m.(Model).width; got != 100 {
		t.Errorf("width = %d, want 100", got)
	}
}
