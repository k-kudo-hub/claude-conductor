package waiting

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

// どんな入力でもペイン幅からはみ出さないこと。はみ出すとZellijが折り返し、
// それ以降の行がすべてずれる。
func TestRenderEveryLineHasExactWidth(t *testing.T) {
	cases := []struct {
		name    string
		entries []pending.Entry
		width   int
	}{
		{"empty", nil, 40},
		{
			"single",
			[]pending.Entry{{Tab: "review-pr42", Message: "Waiting for external response", Time: "18:06:45"}},
			40,
		},
		{
			"multiple",
			[]pending.Entry{
				{Tab: "review-pr42", Message: "Waiting for review", Time: "18:06:45"},
				{Tab: "deploy-check", Message: "Waiting for CI", Time: "18:20:01"},
			},
			40,
		},
		{
			"long message",
			[]pending.Entry{{Tab: "t", Message: strings.Repeat("very long message ", 20), Time: "18:06:45"}},
			40,
		},
		{
			"long tab name",
			[]pending.Entry{{Tab: strings.Repeat("long-tab-", 10), Message: "m", Time: "18:06:45"}},
			40,
		},
		{
			"japanese",
			[]pending.Entry{{Tab: "レビュー待ち", Message: "外部のレスポンスを待っています", Time: "18:06:45"}},
			40,
		},
		{
			"emoji",
			[]pending.Entry{{Tab: "release", Message: "🚀 waiting for deploy 🎉", Time: "18:06:45"}},
			40,
		},
		{
			"narrow pane",
			[]pending.Entry{{Tab: "review-pr42", Message: "Waiting for review", Time: "18:06:45"}},
			ui.MinBoxWidth,
		},
		{
			"wide pane",
			[]pending.Entry{{Tab: "review-pr42", Message: "Waiting for review", Time: "18:06:45"}},
			120,
		},
		{
			"empty message",
			[]pending.Entry{{Tab: "review-pr42", Message: "", Time: "18:06:45"}},
			40,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), tc.entries, tc.width, 0)
			want := max(tc.width, ui.MinBoxWidth)
			for i, line := range strings.Split(out, "\n") {
				if got := lipgloss.Width(line); got != want {
					t.Errorf("line %d width = %d, want %d\nline: %q", i, got, want, line)
				}
			}
		})
	}
}

func TestRenderShowsTitle(t *testing.T) {
	if out := Render(theme(), nil, 40, 0); !strings.Contains(out, "Waiting") {
		t.Errorf("output does not contain the title:\n%s", out)
	}
}

func TestRenderEmptyStateMessage(t *testing.T) {
	out := Render(theme(), nil, 40, 0)
	if !strings.Contains(out, "No waiting tasks") {
		t.Errorf("output does not contain the empty-state message:\n%s", out)
	}
}

func TestRenderShowsTabTimeAndMessage(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "review-pr42", Message: "Waiting for external response", Time: "18:06:45"},
	}
	out := Render(theme(), entries, 60, 0)

	for _, want := range []string{"review-pr42", "18:06:45", "Waiting for external response"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

// 件数は bash 版のフッター（Waiting: N）に相当する情報。
func TestRenderShowsCount(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "a", Message: "m", Time: "1"},
		{Tab: "b", Message: "m", Time: "2"},
		{Tab: "c", Message: "m", Time: "3"},
	}

	if out := Render(theme(), entries, 40, 0); !strings.Contains(out, "3 waiting") {
		t.Errorf("output does not contain the count:\n%s", out)
	}
}

func TestRenderCountIsSingularForOne(t *testing.T) {
	entries := []pending.Entry{{Tab: "a", Message: "m", Time: "1"}}

	if out := Render(theme(), entries, 40, 0); !strings.Contains(out, "1 waiting") {
		t.Errorf("output does not contain the count:\n%s", out)
	}
}

// 改行入りのメッセージで行数が増えると枠が崩れる。1行に潰すこと。
func TestRenderFlattensNewlinesInMessage(t *testing.T) {
	entries := []pending.Entry{
		{Tab: "t", Message: "first line\nsecond line\r\nthird", Time: "18:06:45"},
	}
	out := Render(theme(), entries, 60, 0)

	if strings.Contains(out, "second line\n") && !strings.Contains(out, "first line second line") {
		t.Errorf("newlines were not flattened:\n%s", out)
	}
	for i, line := range strings.Split(out, "\n") {
		if got := lipgloss.Width(line); got != 60 {
			t.Errorf("line %d width = %d, want 60\nline: %q", i, got, line)
		}
	}
}

// ペインの高さを超える件数でも、枠の中に収まること。代替画面に描くので
// はみ出した行は見えないまま失われる。
func TestRenderFitsWithinHeight(t *testing.T) {
	entries := make([]pending.Entry, 20)
	for i := range entries {
		entries[i] = pending.Entry{Tab: "task", Message: "waiting", Time: "18:06:45"}
	}

	for _, height := range []int{6, 10, 14, 25} {
		out := Render(theme(), entries, 44, height)
		if got := len(strings.Split(out, "\n")); got > height {
			t.Errorf("height %d: rendered %d lines\n%s", height, got, out)
		}
	}
}

// 省略しても件数だけは残す。何件待っているかが読めなくなると、
// ペインを開いている意味が薄れる。
func TestRenderKeepsCountWhenTrimmed(t *testing.T) {
	entries := make([]pending.Entry, 20)
	for i := range entries {
		entries[i] = pending.Entry{Tab: "task", Message: "waiting", Time: "18:06:45"}
	}

	out := Render(theme(), entries, 44, 8)
	if !strings.Contains(out, "20 waiting") {
		t.Errorf("count was dropped when trimming:\n%s", out)
	}
	if !strings.Contains(out, "more") {
		t.Errorf("output does not show that entries were omitted:\n%s", out)
	}
}

// 高さが分からない（0）ときは削らない。
func TestRenderWithoutHeightKeepsEveryEntry(t *testing.T) {
	entries := make([]pending.Entry, 5)
	for i := range entries {
		entries[i] = pending.Entry{Tab: "task", Message: "waiting", Time: "18:06:45"}
	}

	out := Render(theme(), entries, 44, 0)
	if strings.Contains(out, "more") {
		t.Errorf("entries were trimmed without a known height:\n%s", out)
	}
}

// タブ名は最後まで読めることを優先し、時刻より先に切られてはならない。
func TestRenderKeepsTimeWhenTabIsLong(t *testing.T) {
	entries := []pending.Entry{
		{Tab: strings.Repeat("x", 100), Message: "m", Time: "18:06:45"},
	}

	if out := Render(theme(), entries, 40, 0); !strings.Contains(out, "18:06:45") {
		t.Errorf("time was dropped for a long tab name:\n%s", out)
	}
}
