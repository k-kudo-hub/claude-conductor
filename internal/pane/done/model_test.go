package done

import (
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/daily"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func key(s string) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: rune(s[0]), Text: s}
}

func modelWithRecords() Model {
	return Model{
		theme:   ui.Resolve(ui.DefaultThemeName),
		width:   60,
		records: sample(),
	}
}

// r を押すと番号入力待ちに入り、打ち切り用のタイマーが仕掛けられる。
func TestPressingREntersRestorePrompt(t *testing.T) {
	m, cmd := modelWithRecords().Update(key("r"))

	got := m.(Model)
	if !got.awaitingRestore {
		t.Error("awaitingRestore = false, want true after pressing r")
	}
	if cmd == nil {
		t.Error("no command returned; the prompt timeout must be scheduled")
	}
}

func TestRestoreSequenceRunsRestore(t *testing.T) {
	m, _ := modelWithRecords().Update(key("r"))
	m, cmd := m.(Model).Update(key("1"))

	got := m.(Model)
	if got.awaitingRestore {
		t.Error("awaitingRestore = true, want false after the number was given")
	}
	if cmd == nil {
		t.Error("no command returned; restore must be started for a valid number")
	}
}

// 表示に無い番号は何も起こさない。押し間違いでタブを作ってしまわないように。
func TestRestoreOutOfRangeDoesNothing(t *testing.T) {
	m, _ := modelWithRecords().Update(key("r"))
	m, cmd := m.(Model).Update(key("9"))

	if m.(Model).awaitingRestore {
		t.Error("awaitingRestore = true, want false")
	}
	if cmd != nil {
		t.Error("a command was returned for an out-of-range number")
	}
}

func TestNonDigitCancelsRestorePrompt(t *testing.T) {
	m, _ := modelWithRecords().Update(key("r"))
	m, cmd := m.(Model).Update(key("x"))

	if m.(Model).awaitingRestore {
		t.Error("awaitingRestore = true, want false after a non-digit")
	}
	if cmd != nil {
		t.Error("a command was returned for a non-digit key")
	}
}

// 数字だけを押しても復元は始まらない。r が前置されている必要がある。
func TestDigitWithoutRDoesNothing(t *testing.T) {
	m, cmd := modelWithRecords().Update(key("1"))

	if m.(Model).awaitingRestore {
		t.Error("awaitingRestore = true, want false")
	}
	if cmd != nil {
		t.Error("a command was returned for a bare digit")
	}
}

func TestPromptTimeoutClearsPrompt(t *testing.T) {
	m, _ := modelWithRecords().Update(key("r"))
	gen := m.(Model).promptGen

	m, _ = m.(Model).Update(promptTimeoutMsg(gen))

	if m.(Model).awaitingRestore {
		t.Error("awaitingRestore = true, want false after the timeout fired")
	}
}

// 古い世代のタイムアウトが、押し直した新しいプロンプトを消してはいけない。
func TestStalePromptTimeoutIsIgnored(t *testing.T) {
	m, _ := modelWithRecords().Update(key("r"))
	stale := m.(Model).promptGen

	// もう一度 r を押して世代を進める。
	m, _ = m.(Model).Update(key("x")) // いったん解除
	m, _ = m.(Model).Update(key("r"))

	m, _ = m.(Model).Update(promptTimeoutMsg(stale))

	if !m.(Model).awaitingRestore {
		t.Error("a stale timeout cleared the current prompt")
	}
}

// 番号入力を待っている間は一覧を固定する。別セッションの復元で並びが
// 変わると、押した番号が別のタスクを指してしまう。
func TestListIsFrozenWhileAwaitingRestore(t *testing.T) {
	m := modelWithRecords()
	m.base = t.TempDir() // 読み直せば必ず空になる場所を指す

	// プロンプトを開いていない間は読み直す。
	got, _ := m.Update(tickMsg(time.Time{}))
	if len(got.(Model).records) != 0 {
		t.Errorf("records = %d, want the list reloaded when idle", len(got.(Model).records))
	}

	// プロンプトを開いている間は据え置く。
	prompted, _ := modelWithRecords().Update(key("r"))
	m2 := prompted.(Model)
	m2.base = t.TempDir()
	before := len(m2.records)

	after, _ := m2.Update(tickMsg(time.Time{}))
	if len(after.(Model).records) != before {
		t.Errorf("records = %d, want %d kept while the prompt is open",
			len(after.(Model).records), before)
	}
}

func TestCtrlCQuits(t *testing.T) {
	_, cmd := modelWithRecords().Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})

	if cmd == nil {
		t.Fatal("no command returned for ctrl+c")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Errorf("ctrl+c did not produce a quit")
	}
}

func TestWindowSizeUpdatesWidth(t *testing.T) {
	m, _ := modelWithRecords().Update(tea.WindowSizeMsg{Width: 100, Height: 20})

	if got := m.(Model).width; got != 100 {
		t.Errorf("width = %d, want 100", got)
	}
}

// restore-task.sh には タブ名 / セッション / 完了時刻 をこの順で渡す。
// 引数がずれると別のエントリを復元してしまう。
func TestRestoreCommandArguments(t *testing.T) {
	r := daily.Record{
		Tab:         "api-feature",
		Session:     "work",
		CompletedAt: "2026-08-08T18:05:31+0900",
	}

	cmd := restoreCommand(r)
	if cmd == nil {
		t.Fatal("restoreCommand returned nil")
	}

	joined := strings.Join(cmd.Args, " ")
	if !strings.Contains(joined, "restore-task.sh") {
		t.Errorf("command does not invoke restore-task.sh: %q", joined)
	}

	// Args[0] は bash、以降に スクリプト・タブ・セッション・完了時刻 が並ぶ。
	if len(cmd.Args) < 5 {
		t.Fatalf("command has %d args, want at least 5: %q", len(cmd.Args), joined)
	}
	want := []string{"api-feature", "work", "2026-08-08T18:05:31+0900"}
	got := cmd.Args[len(cmd.Args)-3:]
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("arg %d = %q, want %q (full: %q)", i, got[i], want[i], joined)
		}
	}
}
