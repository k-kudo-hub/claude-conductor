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
			out := Render(theme(), tc.records, false, tc.width, 0)
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
	if out := Render(theme(), nil, false, 44, 0); !strings.Contains(out, Title) {
		t.Errorf("output does not contain %q:\n%s", Title, out)
	}
}

func TestRenderEmptyState(t *testing.T) {
	if out := Render(theme(), nil, false, 44, 0); !strings.Contains(out, "No tasks completed yet") {
		t.Errorf("output does not contain the empty-state message:\n%s", out)
	}
}

// 見出しの集計は bash 版の "N tasks  T turns / C calls / $X" に相当する。
func TestRenderShowsTotals(t *testing.T) {
	out := Render(theme(), sample(), false, 70, 0)

	for _, want := range []string{"2 tasks", "20", "120", "$0.73"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

func TestRenderShowsEachTask(t *testing.T) {
	out := Render(theme(), sample(), false, 70, 0)

	for _, want := range []string{"api-feature", "web-fix", "18:05", "19:20", "$0.42", "$0.31"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

func TestRenderNumbersTasksForRestore(t *testing.T) {
	out := Render(theme(), sample(), false, 70, 0)

	if !strings.Contains(out, "restore") {
		t.Errorf("output does not contain the restore hint:\n%s", out)
	}
	// 番号は 1 起点。r+番号 で復元する対象と一致させる。
	if !strings.Contains(out, "1") || !strings.Contains(out, "2") {
		t.Errorf("output does not number the tasks:\n%s", out)
	}
}

func TestRenderShowsMarkers(t *testing.T) {
	if out := Render(theme(), sample(), false, 70, 0); !strings.Contains(out, "🚀") {
		t.Errorf("output does not contain the merged marker:\n%s", out)
	}
}

// summary が取れなかったタスクも一覧には出す。数値はプレースホルダにする。
func TestRenderShowsPlaceholderWhenSummaryMissing(t *testing.T) {
	records := []daily.Record{{
		Tab:         "crashed",
		CompletedAt: "2026-08-08T10:00:00+0900",
	}}
	out := Render(theme(), records, false, 70, 0)

	if !strings.Contains(out, "crashed") {
		t.Errorf("output does not list the task:\n%s", out)
	}
	if !strings.Contains(out, "-") {
		t.Errorf("output does not show a placeholder for the missing summary:\n%s", out)
	}
}

// r を押したあとは、次に押す数字を待っていることが分かる表示にする。
func TestRenderShowsRestorePrompt(t *testing.T) {
	out := Render(theme(), sample(), true, 70, 0)

	if !strings.Contains(out, "Restore which") {
		t.Errorf("output does not contain the restore prompt:\n%s", out)
	}
	for i, line := range strings.Split(out, "\n") {
		if got := lipgloss.Width(line); got != 70 {
			t.Errorf("line %d width = %d, want 70\nline: %q", i, got, line)
		}
	}
}

// 番号は 1 打鍵で受けるため 10 以上は指定できない。選べない番号を
// 見せないよう、9 件目までにしか番号を振らない。
func TestRenderNumbersOnlySelectableTasks(t *testing.T) {
	records := make([]daily.Record, 12)
	for i := range records {
		records[i] = daily.Record{Tab: "task", CompletedAt: "2026-08-08T10:00:00+0900"}
	}

	out := Render(theme(), records, false, 80, 0)
	if !strings.Contains(out, "first 9") {
		t.Errorf("output does not tell that only the first 9 are restorable:\n%s", out)
	}
	// 全件は一覧に出す（見えなくなるほうが困る）。
	if got := strings.Count(out, "task"); got < 12 {
		t.Errorf("only %d of 12 tasks listed:\n%s", got, out)
	}
}

// 9 件以下なら注記は出さない。
func TestRenderOmitsLimitNoteWhenAllSelectable(t *testing.T) {
	records := make([]daily.Record, 9)
	for i := range records {
		records[i] = daily.Record{Tab: "task", CompletedAt: "2026-08-08T10:00:00+0900"}
	}

	if out := Render(theme(), records, false, 80, 0); strings.Contains(out, "first 9") {
		t.Errorf("limit note shown for 9 records:\n%s", out)
	}
}

// completed_at が読めないレコードで時刻欄が空になっても、目印の桁が
// ずれないこと。欄を固定していないと 5 桁ぶん左へ寄る。
func TestRenderKeepsMarkerColumnWhenClockIsMissing(t *testing.T) {
	records := []daily.Record{
		{Tab: "normal", CompletedAt: "2026-08-08T18:05:31+0900",
			Summary: &daily.Summary{TotalTurns: 1, TotalCostUSD: cost(0.1)},
			Markers: daily.Markers{Merged: true}},
		{Tab: "noclock", CompletedAt: "",
			Summary: &daily.Summary{TotalTurns: 1, TotalCostUSD: cost(0.1)},
			Markers: daily.Markers{Merged: true}},
	}

	lines := strings.Split(Render(theme(), records, false, 70, 0), "\n")
	var cols []int
	for _, line := range lines {
		plain := stripANSI(line)
		if i := strings.Index(plain, "🚀"); i >= 0 {
			cols = append(cols, i)
		}
	}
	if len(cols) != 2 {
		t.Fatalf("expected the marker on 2 lines, found %d", len(cols))
	}
	if cols[0] != cols[1] {
		t.Errorf("marker column differs: %d vs %d\n%s", cols[0], cols[1],
			strings.Join(lines, "\n"))
	}
}

// 最後の1件を復元した直後も、番号入力待ちだったことが分かること。
func TestRenderShowsPromptWhenListBecomesEmpty(t *testing.T) {
	if out := Render(theme(), nil, true, 60, 0); !strings.Contains(out, "Restore which") {
		t.Errorf("prompt dropped for an empty list:\n%s", out)
	}
}

func TestRenderFitsWithinHeight(t *testing.T) {
	records := make([]daily.Record, 20)
	for i := range records {
		records[i] = daily.Record{Tab: "task", CompletedAt: "2026-08-08T10:00:00+0900"}
	}

	for _, height := range []int{6, 10, 14} {
		out := Render(theme(), records, false, 60, height)
		if got := len(strings.Split(out, "\n")); got > height {
			t.Errorf("height %d: rendered %d lines\n%s", height, got, out)
		}
	}
}

// ANSI エスケープを除いた素の文字列を返す（桁位置の比較用）。
func stripANSI(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] == 0x1b {
			for i < len(s) && s[i] != 'm' {
				i++
			}
			i++
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
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

// 10 件目以降は番号で選べない。番号は 1 打鍵で受けるため 2 桁を待てない。
func TestRecordForIndexStopsAtTheSelectableLimit(t *testing.T) {
	records := make([]daily.Record, 12)
	for i := range records {
		records[i] = daily.Record{Tab: "task"}
	}

	if got := RecordForIndex(records, MaxSelectable-1); got == nil {
		t.Errorf("RecordForIndex(%d) = nil, want the 9th record", MaxSelectable-1)
	}
	for _, i := range []int{MaxSelectable, MaxSelectable + 1, 11} {
		if got := RecordForIndex(records, i); got != nil {
			t.Errorf("RecordForIndex(%d) = %v, want nil (not selectable)", i, got)
		}
	}
}
