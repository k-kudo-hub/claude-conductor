package dashboard

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

// Dashboard は Zellij のタブ順に並べる。pending ファイルの並び（ファイル名順）
// ではなく、画面上のタブと同じ順序で番号が振られないと、番号ジャンプが
// 直感に反する。
func TestOrderByTabsFollowsTabOrder(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "web-fix", Event: "Notification"},
		{Tab: "api-feature", Event: "Notification"},
		{Tab: "docs", Event: "Stop"},
	}
	tabs := []string{"Main", "api-feature", "docs", "web-fix"}

	got := OrderByTabs(entries, tabs)
	want := []string{"api-feature", "docs", "web-fix"}

	if len(got) != len(want) {
		t.Fatalf("OrderByTabs returned %d entries, want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i].Tab != w {
			t.Errorf("entry %d: Tab = %q, want %q", i, got[i].Tab, w)
		}
	}
}

// Waiting は Waiting ペインが受け持つので Dashboard には出さない。
func TestOrderByTabsExcludesWaiting(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "active", Event: "Notification"},
		{Tab: "blocked", Event: "Waiting"},
	}
	tabs := []string{"active", "blocked"}

	got := OrderByTabs(entries, tabs)
	if len(got) != 1 {
		t.Fatalf("OrderByTabs returned %d entries, want 1", len(got))
	}
	if got[0].Tab != "active" {
		t.Errorf("Tab = %q, want active", got[0].Tab)
	}
}

// タブが閉じられた後に残った pending は出さない。存在しないタブへ
// ジャンプさせないため。
func TestOrderByTabsDropsEntriesWithoutTab(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "alive", Event: "Notification"},
		{Tab: "closed", Event: "Notification"},
	}

	got := OrderByTabs(entries, []string{"alive"})
	if len(got) != 1 {
		t.Fatalf("OrderByTabs returned %d entries, want 1", len(got))
	}
	if got[0].Tab != "alive" {
		t.Errorf("Tab = %q, want alive", got[0].Tab)
	}
}

// Zellij の外（タブ一覧が取れない）ではタブ順に並べ替えられないが、
// 待ちが見えなくなるよりは元の順で出すほうがよい。
func TestOrderByTabsWithoutTabListKeepsEntries(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "a", Event: "Notification"},
		{Tab: "b", Event: "Stop"},
	}

	got := OrderByTabs(entries, nil)
	if len(got) != 2 {
		t.Fatalf("OrderByTabs returned %d entries, want 2", len(got))
	}
}

// 同じタブに複数の pending がある場合（hooks とスクリーン検出の両方が
// 書いた場合など）も、タブ順の位置に並べる。
func TestOrderByTabsKeepsMultipleEntriesPerTab(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "dup", Event: "Notification", Time: "10:00"},
		{Tab: "other", Event: "Stop", Time: "11:00"},
		{Tab: "dup", Event: "Stop", Time: "12:00"},
	}

	got := OrderByTabs(entries, []string{"dup", "other"})
	if len(got) != 3 {
		t.Fatalf("OrderByTabs returned %d entries, want 3", len(got))
	}
	if got[0].Tab != "dup" || got[1].Tab != "dup" || got[2].Tab != "other" {
		t.Errorf("order = %q %q %q, want dup dup other", got[0].Tab, got[1].Tab, got[2].Tab)
	}
}

func TestRenderEveryLineHasExactWidth(t *testing.T) {
	long := []pending.Entry{{
		Tab:     strings.Repeat("long-tab-", 10),
		Message: strings.Repeat("long message ", 20),
		Event:   "Notification",
		Time:    "18:05:31",
	}}

	cases := []struct {
		name    string
		entries []pending.Entry
		prompt  string
		width   int
	}{
		{"empty", nil, "", 44},
		{
			"notification",
			[]pending.Entry{{Tab: "api-feature", Message: "Claude needs your permission to use Bash", Event: "Notification", Time: "18:05:31"}},
			"", 44,
		},
		{
			"done",
			[]pending.Entry{{Tab: "web-fix", Message: "Task complete", Event: "Stop", Time: "19:20:01"}},
			"", 44,
		},
		{"long", long, "", 44},
		{
			"japanese",
			[]pending.Entry{{Tab: "開発タスク", Message: "権限の確認をお願いします", Event: "Notification", Time: "18:05:31"}},
			"", 44,
		},
		{
			"delete prompt",
			[]pending.Entry{{Tab: "api-feature", Message: "m", Event: "Notification", Time: "18:05:31"}},
			"Delete which number?", 44,
		},
		{
			"narrow",
			[]pending.Entry{{Tab: "api-feature", Message: "m", Event: "Notification", Time: "18:05:31"}},
			"", ui.MinBoxWidth,
		},
		{
			"wide",
			[]pending.Entry{{Tab: "api-feature", Message: "m", Event: "Notification", Time: "18:05:31"}},
			"", 120,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), "session", tc.entries, tc.prompt, tc.width)
			want := max(tc.width, ui.MinBoxWidth)
			for i, line := range strings.Split(out, "\n") {
				if got := lipgloss.Width(line); got != want {
					t.Errorf("line %d width = %d, want %d\nline: %q", i, got, want, line)
				}
			}
		})
	}
}

func TestRenderShowsTitleAndSession(t *testing.T) {
	out := Render(theme(), "my-session", nil, "", 60)

	if !strings.Contains(out, Title) {
		t.Errorf("output does not contain %q:\n%s", Title, out)
	}
	if !strings.Contains(out, "my-session") {
		t.Errorf("output does not contain the session name:\n%s", out)
	}
}

func TestRenderEmptyState(t *testing.T) {
	if out := Render(theme(), "s", nil, "", 60); !strings.Contains(out, "All tasks running") {
		t.Errorf("output does not contain the empty-state message:\n%s", out)
	}
}

func TestRenderShowsEntryDetails(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "api-feature", Message: "Claude needs your permission", Event: "Notification", Time: "18:05:31"},
	}
	out := Render(theme(), "s", entries, "", 70)

	for _, want := range []string{"1", "api-feature", "18:05:31", "Claude needs your permission"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

// 終了したターンは「done」と分かるようにする。色だけに頼らない。
func TestRenderLabelsDoneEntries(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "web-fix", Message: "Task complete", Event: "Stop", Time: "19:20:01"},
	}

	if out := Render(theme(), "s", entries, "", 70); !strings.Contains(out, "done") {
		t.Errorf("output does not mark the finished turn:\n%s", out)
	}
}

func TestRenderShowsPendingCountAndKeyHints(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "a", Message: "m", Event: "Notification", Time: "1"},
		{Tab: "b", Message: "m", Event: "Notification", Time: "2"},
	}
	out := Render(theme(), "s", entries, "", 70)

	for _, want := range []string{"2 pending", "jump", "delete"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

// 削除は取り消せないので、番号入力待ちであることをはっきり出す。
func TestRenderShowsPrompt(t *testing.T) {
	entries := []pending.Entry{{Tab: "a", Message: "m", Event: "Notification", Time: "1"}}
	out := Render(theme(), "s", entries, "Delete which number?", 70)

	if !strings.Contains(out, "Delete which number?") {
		t.Errorf("output does not contain the prompt:\n%s", out)
	}
	if strings.Contains(out, "jump") {
		t.Errorf("the key hint should be replaced by the prompt:\n%s", out)
	}
}

func TestEntryForIndex(t *testing.T) {
	entries := []pending.Entry{{Tab: "a"}, {Tab: "b"}}

	if got := EntryForIndex(entries, 0); got == nil || got.Tab != "a" {
		t.Errorf("EntryForIndex(0) = %v, want a", got)
	}
	for _, i := range []int{-1, 2, 99} {
		if got := EntryForIndex(entries, i); got != nil {
			t.Errorf("EntryForIndex(%d) = %v, want nil", i, got)
		}
	}
}
