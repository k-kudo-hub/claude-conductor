package news

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

func writeNews(t *testing.T, dir, date, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, date+".json"), []byte(content), 0o644); err != nil {
		t.Fatalf("write news: %v", err)
	}
}

func TestLoadReadsItems(t *testing.T) {
	dir := t.TempDir()
	writeNews(t, dir, "2026-08-08", `{"items":[
		{"title":"Anthropic ships Claude 5","url":"https://example.com/a","description":"A new model family."},
		{"title":"Second story","url":"https://example.com/b","description":"More details."}
	]}`)

	got := Load(dir, "2026-08-08")
	if len(got) != 2 {
		t.Fatalf("Load returned %d items, want 2", len(got))
	}
	if got[0].Title != "Anthropic ships Claude 5" {
		t.Errorf("Title = %q", got[0].Title)
	}
	if got[0].URL != "https://example.com/a" {
		t.Errorf("URL = %q", got[0].URL)
	}
	if got[0].Description != "A new model family." {
		t.Errorf("Description = %q", got[0].Description)
	}
}

func TestLoadMissingFileIsEmpty(t *testing.T) {
	if got := Load(t.TempDir(), "2026-08-08"); len(got) != 0 {
		t.Errorf("Load returned %d items for a missing file, want 0", len(got))
	}
}

// fetch-news.sh は jq で検証してから保存するが、途中で落ちた書き込みを
// 掴む可能性は残る。壊れていても描画は続ける。
func TestLoadMalformedFileIsEmpty(t *testing.T) {
	dir := t.TempDir()
	writeNews(t, dir, "2026-08-08", `{not json`)

	if got := Load(dir, "2026-08-08"); len(got) != 0 {
		t.Errorf("Load returned %d items for a malformed file, want 0", len(got))
	}
}

func TestLoadEmptyItemsIsEmpty(t *testing.T) {
	dir := t.TempDir()
	writeNews(t, dir, "2026-08-08", `{"items":[]}`)

	if got := Load(dir, "2026-08-08"); len(got) != 0 {
		t.Errorf("Load returned %d items, want 0", len(got))
	}
}

func TestRenderEveryLineHasExactWidth(t *testing.T) {
	long := strings.Repeat("very long headline ", 20)

	cases := []struct {
		name    string
		items   []Item
		loading bool
		width   int
	}{
		{"empty", nil, false, 44},
		{"loading", nil, true, 44},
		{
			"single",
			[]Item{{Title: "Anthropic ships Claude 5", Description: "A new model family."}},
			false, 44,
		},
		{
			"five items",
			[]Item{
				{Title: "One", Description: "d1"},
				{Title: "Two", Description: "d2"},
				{Title: "Three", Description: "d3"},
				{Title: "Four", Description: "d4"},
				{Title: "Five", Description: "d5"},
			},
			false, 44,
		},
		{"long title", []Item{{Title: long, Description: long}}, false, 44},
		{
			"japanese",
			[]Item{{Title: "アンソロピックが新モデルを発表", Description: "詳細はこちらの記事を参照してください"}},
			false, 44,
		},
		{"emoji", []Item{{Title: "🚀 Launch day 🎉", Description: "🔥 hot"}}, false, 44},
		{"no description", []Item{{Title: "Headline only", Description: ""}}, false, 44},
		{"narrow", []Item{{Title: "Headline", Description: "desc"}}, false, ui.MinBoxWidth},
		{"wide", []Item{{Title: "Headline", Description: "desc"}}, false, 120},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), tc.items, "2026-08-08", tc.loading, tc.width)
			want := max(tc.width, ui.MinBoxWidth)
			for i, line := range strings.Split(out, "\n") {
				if got := lipgloss.Width(line); got != want {
					t.Errorf("line %d width = %d, want %d\nline: %q", i, got, want, line)
				}
			}
		})
	}
}

func TestRenderShowsTitleAndDate(t *testing.T) {
	out := Render(theme(), nil, "2026-08-08", false, 60)

	if !strings.Contains(out, Title) {
		t.Errorf("output does not contain %q:\n%s", Title, out)
	}
	if !strings.Contains(out, "2026-08-08") {
		t.Errorf("output does not contain the date:\n%s", out)
	}
}

func TestRenderEmptyState(t *testing.T) {
	out := Render(theme(), nil, "2026-08-08", false, 60)

	if !strings.Contains(out, "No news yet") {
		t.Errorf("output does not contain the empty-state message:\n%s", out)
	}
}

func TestRenderLoadingState(t *testing.T) {
	out := Render(theme(), nil, "2026-08-08", true, 60)

	if !strings.Contains(out, "Fetching news") {
		t.Errorf("output does not contain the loading message:\n%s", out)
	}
}

// 記事は番号で開くので、番号と本文が並んでいること。
func TestRenderNumbersItems(t *testing.T) {
	items := []Item{
		{Title: "First story", Description: "d1"},
		{Title: "Second story", Description: "d2"},
	}
	out := Render(theme(), items, "2026-08-08", false, 60)

	for _, want := range []string{"1", "First story", "2", "Second story", "d1", "d2"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

// キーヒントは実際に開ける件数を示す。3件なら [1-3]。
func TestRenderKeyHintMatchesItemCount(t *testing.T) {
	items := []Item{{Title: "a"}, {Title: "b"}, {Title: "c"}}

	if out := Render(theme(), items, "2026-08-08", false, 60); !strings.Contains(out, "1-3") {
		t.Errorf("output does not contain the key hint for 3 items:\n%s", out)
	}
}

func TestRenderSingleItemKeyHint(t *testing.T) {
	items := []Item{{Title: "only"}}

	out := Render(theme(), items, "2026-08-08", false, 60)
	if strings.Contains(out, "1-1") {
		t.Errorf("key hint should not be a range for a single item:\n%s", out)
	}
	if !strings.Contains(out, "reload") {
		t.Errorf("output does not contain the reload hint:\n%s", out)
	}
}

func TestURLForIndex(t *testing.T) {
	items := []Item{
		{Title: "a", URL: "https://example.com/a"},
		{Title: "b", URL: ""},
	}

	if got := URLForIndex(items, 0); got != "https://example.com/a" {
		t.Errorf("URLForIndex(0) = %q", got)
	}
	// URL が空の記事、範囲外は空を返し、呼び出し側は何もしない。
	if got := URLForIndex(items, 1); got != "" {
		t.Errorf("URLForIndex(1) = %q, want empty", got)
	}
	for _, i := range []int{-1, 2, 99} {
		if got := URLForIndex(items, i); got != "" {
			t.Errorf("URLForIndex(%d) = %q, want empty", i, got)
		}
	}
}
