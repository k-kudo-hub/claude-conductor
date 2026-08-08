package done

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/daily"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

func cost(v float64) *float64 { return &v }

func sample() []daily.Record {
	return []daily.Record{
		{
			Tab:         "api-feature",
			Session:     "work",
			CompletedAt: "2026-08-08T18:05:31+0900",
			Summary:     &daily.Summary{TotalTurns: 12, TotalToolCalls: 80, TotalCostUSD: cost(0.42)},
			Markers:     daily.Markers{Merged: true},
		},
		{
			Tab:         "web-fix",
			Session:     "work",
			CompletedAt: "2026-08-08T19:20:01+0900",
			Summary:     &daily.Summary{TotalTurns: 8, TotalToolCalls: 40, TotalCostUSD: cost(0.31)},
		},
	}
}

func TestRenderEveryLineHasExactWidth(t *testing.T) {
	long := []daily.Record{{
		Tab:         strings.Repeat("very-long-tab-name-", 5),
		CompletedAt: "2026-08-08T18:05:31+0900",
		Summary:     &daily.Summary{TotalTurns: 999, TotalToolCalls: 9999, TotalCostUSD: cost(1234.56)},
		Markers:     daily.Markers{Merged: true, Slack: true, Doc: true},
	}}
	japanese := []daily.Record{{
		Tab:         "開発タスク",
		CompletedAt: "2026-08-08T18:05:31+0900",
		Summary:     &daily.Summary{TotalTurns: 3, TotalToolCalls: 9, TotalCostUSD: cost(0.05)},
	}}
	noSummary := []daily.Record{{
		Tab:         "crashed",
		CompletedAt: "2026-08-08T10:00:00+0900",
	}}

	cases := []struct {
		name    string
		records []daily.Record
		width   int
	}{
		{"empty", nil, 44},
		{"two records", sample(), 44},
		{"long tab and markers", long, 44},
		{"japanese", japanese, 44},
		{"missing summary", noSummary, 44},
		{"narrow", sample(), ui.MinBoxWidth},
		{"wide", sample(), 120},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), tc.records, false, tc.width)
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
	if out := Render(theme(), nil, false, 44); !strings.Contains(out, Title) {
		t.Errorf("output does not contain %q:\n%s", Title, out)
	}
}

func TestRenderEmptyState(t *testing.T) {
	if out := Render(theme(), nil, false, 44); !strings.Contains(out, "No tasks completed yet") {
		t.Errorf("output does not contain the empty-state message:\n%s", out)
	}
}

// 見出しの集計は bash 版の "N tasks  T turns / C calls / $X" に相当する。
func TestRenderShowsTotals(t *testing.T) {
	out := Render(theme(), sample(), false, 70)

	for _, want := range []string{"2 tasks", "20", "120", "$0.73"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

func TestRenderShowsEachTask(t *testing.T) {
	out := Render(theme(), sample(), false, 70)

	for _, want := range []string{"api-feature", "web-fix", "18:05", "19:20", "$0.42", "$0.31"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

func TestRenderNumbersTasksForRestore(t *testing.T) {
	out := Render(theme(), sample(), false, 70)

	if !strings.Contains(out, "restore") {
		t.Errorf("output does not contain the restore hint:\n%s", out)
	}
	// 番号は 1 起点。r+番号 で復元する対象と一致させる。
	if !strings.Contains(out, "1") || !strings.Contains(out, "2") {
		t.Errorf("output does not number the tasks:\n%s", out)
	}
}

func TestRenderShowsMarkers(t *testing.T) {
	if out := Render(theme(), sample(), false, 70); !strings.Contains(out, "🚀") {
		t.Errorf("output does not contain the merged marker:\n%s", out)
	}
}

// summary が取れなかったタスクも一覧には出す。数値はプレースホルダにする。
func TestRenderShowsPlaceholderWhenSummaryMissing(t *testing.T) {
	records := []daily.Record{{
		Tab:         "crashed",
		CompletedAt: "2026-08-08T10:00:00+0900",
	}}
	out := Render(theme(), records, false, 70)

	if !strings.Contains(out, "crashed") {
		t.Errorf("output does not list the task:\n%s", out)
	}
	if !strings.Contains(out, "-") {
		t.Errorf("output does not show a placeholder for the missing summary:\n%s", out)
	}
}

// r を押したあとは、次に押す数字を待っていることが分かる表示にする。
func TestRenderShowsRestorePrompt(t *testing.T) {
	out := Render(theme(), sample(), true, 70)

	if !strings.Contains(out, "Restore which") {
		t.Errorf("output does not contain the restore prompt:\n%s", out)
	}
	for i, line := range strings.Split(out, "\n") {
		if got := lipgloss.Width(line); got != 70 {
			t.Errorf("line %d width = %d, want 70\nline: %q", i, got, line)
		}
	}
}

// 復元は表示順の番号で指す。表示に使ったレコードと同じ並びであること。
func TestRecordForIndex(t *testing.T) {
	records := sample()

	if got := RecordForIndex(records, 0); got == nil || got.Tab != "api-feature" {
		t.Errorf("RecordForIndex(0) = %v, want api-feature", got)
	}
	if got := RecordForIndex(records, 1); got == nil || got.Tab != "web-fix" {
		t.Errorf("RecordForIndex(1) = %v, want web-fix", got)
	}
	for _, i := range []int{-1, 2, 99} {
		if got := RecordForIndex(records, i); got != nil {
			t.Errorf("RecordForIndex(%d) = %v, want nil", i, got)
		}
	}
}
