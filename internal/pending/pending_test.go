package pending

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

func TestLoadReadsEveryField(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "sid-1.json", `{
		"tab": "api-feature",
		"session": "work",
		"claude_session_id": "sid-1",
		"message": "Claude needs your permission to use Bash",
		"event": "Notification",
		"time": "18:05:31",
		"agent": "claude"
	}`)

	got := Load(dir)
	if len(got) != 1 {
		t.Fatalf("Load returned %d entries, want 1", len(got))
	}

	e := got[0]
	if e.Tab != "api-feature" {
		t.Errorf("Tab = %q, want %q", e.Tab, "api-feature")
	}
	if e.Session != "work" {
		t.Errorf("Session = %q, want %q", e.Session, "work")
	}
	if e.ClaudeSessionID != "sid-1" {
		t.Errorf("ClaudeSessionID = %q, want %q", e.ClaudeSessionID, "sid-1")
	}
	if e.Message != "Claude needs your permission to use Bash" {
		t.Errorf("Message = %q", e.Message)
	}
	if e.Event != "Notification" {
		t.Errorf("Event = %q, want %q", e.Event, "Notification")
	}
	if e.Time != "18:05:31" {
		t.Errorf("Time = %q, want %q", e.Time, "18:05:31")
	}
	if e.Agent != "claude" {
		t.Errorf("Agent = %q, want %q", e.Agent, "claude")
	}
	if e.Path == "" {
		t.Error("Path is empty; the source file path must be kept for deletion")
	}
}

func TestLoadMissingDirectoryIsEmpty(t *testing.T) {
	// セッション開始直後などディレクトリがまだ無い状態でも、描画は
	// 「待ちなし」として成立しなければならない。
	if got := Load(filepath.Join(t.TempDir(), "no-such-dir")); len(got) != 0 {
		t.Errorf("Load returned %d entries for a missing dir, want 0", len(got))
	}
}

func TestLoadEmptyDirectoryIsEmpty(t *testing.T) {
	if got := Load(t.TempDir()); len(got) != 0 {
		t.Errorf("Load returned %d entries for an empty dir, want 0", len(got))
	}
}

// 壊れたファイルが1つあっても他の待ちが見えなくなってはいけない。
// bash 版も jq のエラーを捨てて次のファイルへ進んでいた。
func TestLoadSkipsMalformedFiles(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "a.json", `{"tab": "good-one", "event": "Waiting"}`)
	write(t, dir, "b.json", `{not json at all`)
	write(t, dir, "c.json", ``)

	got := Load(dir)
	if len(got) != 1 {
		t.Fatalf("Load returned %d entries, want 1 (malformed files skipped)", len(got))
	}
	if got[0].Tab != "good-one" {
		t.Errorf("Tab = %q, want %q", got[0].Tab, "good-one")
	}
}

func TestLoadIgnoresNonJSONFiles(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "entry.json", `{"tab": "kept"}`)
	write(t, dir, "notes.txt", `{"tab": "ignored"}`)
	if err := os.Mkdir(filepath.Join(dir, ".screen-state"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	got := Load(dir)
	if len(got) != 1 {
		t.Fatalf("Load returned %d entries, want 1", len(got))
	}
	if got[0].Tab != "kept" {
		t.Errorf("Tab = %q, want %q", got[0].Tab, "kept")
	}
}

// 表示順が実行ごとに揺れないよう、ファイル名で安定させる。
func TestLoadIsSortedByFileName(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "c.json", `{"tab": "third"}`)
	write(t, dir, "a.json", `{"tab": "first"}`)
	write(t, dir, "b.json", `{"tab": "second"}`)

	got := Load(dir)
	want := []string{"first", "second", "third"}
	if len(got) != len(want) {
		t.Fatalf("Load returned %d entries, want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i].Tab != w {
			t.Errorf("entry %d: Tab = %q, want %q", i, got[i].Tab, w)
		}
	}
}

func TestFilterByEvent(t *testing.T) {
	entries := []Entry{
		{Tab: "a", Event: "Waiting"},
		{Tab: "b", Event: "Stop"},
		{Tab: "c", Event: "Waiting"},
		{Tab: "d", Event: "Notification"},
	}

	got := FilterByEvent(entries, "Waiting")
	if len(got) != 2 {
		t.Fatalf("FilterByEvent returned %d entries, want 2", len(got))
	}
	if got[0].Tab != "a" || got[1].Tab != "c" {
		t.Errorf("FilterByEvent returned %q and %q, want a and c", got[0].Tab, got[1].Tab)
	}
}

func TestDirUsesSessionName(t *testing.T) {
	t.Setenv("HOME", "/home/tester")

	if got, want := Dir("my-session"), "/home/tester/.claude-pending/my-session"; got != want {
		t.Errorf("Dir(\"my-session\") = %q, want %q", got, want)
	}
}

// bash 版は ZELLIJ_SESSION_NAME が無いとき unknown を使っていた。同じ
// ディレクトリを指さないと、Zellij 外での実行結果が食い違う。
func TestSessionNameFallsBackToUnknown(t *testing.T) {
	t.Setenv("ZELLIJ_SESSION_NAME", "")
	if got := SessionName(); got != "unknown" {
		t.Errorf("SessionName() = %q, want %q", got, "unknown")
	}

	t.Setenv("ZELLIJ_SESSION_NAME", "real-session")
	if got := SessionName(); got != "real-session" {
		t.Errorf("SessionName() = %q, want %q", got, "real-session")
	}
}
