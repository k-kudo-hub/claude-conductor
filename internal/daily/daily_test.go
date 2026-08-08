package daily

import (
	"os"
	"path/filepath"
	"testing"
)

func writeLog(t *testing.T, base, session, date string, lines ...string) {
	t.Helper()
	dir := filepath.Join(base, session)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	content := ""
	for _, l := range lines {
		content += l + "\n"
	}
	if err := os.WriteFile(filepath.Join(dir, date+".jsonl"), []byte(content), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

const rec1 = `{"tab":"api-feature","session":"work","completed_at":"2026-08-08T18:05:31+0900","summary":{"total_turns":12,"total_tool_calls":80,"total_cost_usd":0.42},"markers":{"merged":true,"slack":false,"doc":false},"agent":"claude"}`
const rec2 = `{"tab":"web-fix","session":"work","completed_at":"2026-08-08T19:20:01+0900","summary":{"total_turns":8,"total_tool_calls":40,"total_cost_usd":0.31},"markers":{"merged":false,"slack":true,"doc":true},"agent":"codex"}`

func TestLoadReadsEveryField(t *testing.T) {
	base := t.TempDir()
	writeLog(t, base, "work", "2026-08-08", rec1)

	got := Load(base, "2026-08-08")
	if len(got) != 1 {
		t.Fatalf("Load returned %d records, want 1", len(got))
	}

	r := got[0]
	if r.Tab != "api-feature" {
		t.Errorf("Tab = %q", r.Tab)
	}
	if r.Session != "work" {
		t.Errorf("Session = %q", r.Session)
	}
	if r.CompletedAt != "2026-08-08T18:05:31+0900" {
		t.Errorf("CompletedAt = %q", r.CompletedAt)
	}
	if r.Summary == nil {
		t.Fatal("Summary is nil")
	}
	if r.Summary.TotalTurns != 12 {
		t.Errorf("TotalTurns = %d, want 12", r.Summary.TotalTurns)
	}
	if r.Summary.TotalToolCalls != 80 {
		t.Errorf("TotalToolCalls = %d, want 80", r.Summary.TotalToolCalls)
	}
	if r.Summary.TotalCostUSD == nil || *r.Summary.TotalCostUSD != 0.42 {
		t.Errorf("TotalCostUSD = %v, want 0.42", r.Summary.TotalCostUSD)
	}
	if !r.Markers.Merged {
		t.Error("Markers.Merged = false, want true")
	}
	if r.Agent != "claude" {
		t.Errorf("Agent = %q", r.Agent)
	}
}

// 日次ログはセッションごとのサブディレクトリに分かれている。Done ペインは
// その日のぶんを横断して見せる。
func TestLoadReadsEverySessionDirectory(t *testing.T) {
	base := t.TempDir()
	writeLog(t, base, "work", "2026-08-08", rec1)
	writeLog(t, base, "side-project", "2026-08-08", rec2)

	if got := Load(base, "2026-08-08"); len(got) != 2 {
		t.Fatalf("Load returned %d records, want 2", len(got))
	}
}

func TestLoadIgnoresOtherDates(t *testing.T) {
	base := t.TempDir()
	writeLog(t, base, "work", "2026-08-08", rec1)
	writeLog(t, base, "work", "2026-08-07", rec2)

	got := Load(base, "2026-08-08")
	if len(got) != 1 {
		t.Fatalf("Load returned %d records, want 1", len(got))
	}
	if got[0].Tab != "api-feature" {
		t.Errorf("Tab = %q, want api-feature", got[0].Tab)
	}
}

func TestLoadMissingDirectoryIsEmpty(t *testing.T) {
	if got := Load(filepath.Join(t.TempDir(), "nope"), "2026-08-08"); len(got) != 0 {
		t.Errorf("Load returned %d records, want 0", len(got))
	}
}

// 1 行が壊れていても残りは読む。jsonl は追記で育つので、途中で切れた行を
// 掴むことがある。
func TestLoadSkipsMalformedLines(t *testing.T) {
	base := t.TempDir()
	writeLog(t, base, "work", "2026-08-08", rec1, `{"tab": broken`, "", rec2)

	if got := Load(base, "2026-08-08"); len(got) != 2 {
		t.Fatalf("Load returned %d records, want 2", len(got))
	}
}

func TestLoadHandlesNullSummary(t *testing.T) {
	base := t.TempDir()
	writeLog(t, base, "work", "2026-08-08",
		`{"tab":"crashed","session":"work","completed_at":"2026-08-08T10:00:00+0900","summary":null,"markers":{"merged":false,"slack":false,"doc":false}}`)

	got := Load(base, "2026-08-08")
	if len(got) != 1 {
		t.Fatalf("Load returned %d records, want 1", len(got))
	}
	if got[0].Summary != nil {
		t.Error("Summary should stay nil so the pane can show a placeholder")
	}
}

// 復元済みのタスクは Dashboard に戻っているので Done には出さない。
func TestActiveExcludesRestored(t *testing.T) {
	records := []Record{
		{Tab: "a"},
		{Tab: "b", Restored: true},
		{Tab: "c"},
	}

	got := Active(records)
	if len(got) != 2 {
		t.Fatalf("Active returned %d records, want 2", len(got))
	}
	if got[0].Tab != "a" || got[1].Tab != "c" {
		t.Errorf("Active returned %q and %q, want a and c", got[0].Tab, got[1].Tab)
	}
}

func TestSortByCompletedAt(t *testing.T) {
	records := []Record{
		{Tab: "later", CompletedAt: "2026-08-08T19:00:00+0900"},
		{Tab: "earlier", CompletedAt: "2026-08-08T09:00:00+0900"},
		{Tab: "middle", CompletedAt: "2026-08-08T13:00:00+0900"},
	}

	SortByCompletedAt(records)
	want := []string{"earlier", "middle", "later"}
	for i, w := range want {
		if records[i].Tab != w {
			t.Errorf("record %d: Tab = %q, want %q", i, records[i].Tab, w)
		}
	}
}

func TestStatsSumsSummaries(t *testing.T) {
	c1, c2 := 0.42, 0.31
	records := []Record{
		{Summary: &Summary{TotalTurns: 12, TotalToolCalls: 80, TotalCostUSD: &c1}},
		{Summary: &Summary{TotalTurns: 8, TotalToolCalls: 40, TotalCostUSD: &c2}},
	}

	got := Stats(records)
	if got.Count != 2 {
		t.Errorf("Count = %d, want 2", got.Count)
	}
	if got.Turns != 20 {
		t.Errorf("Turns = %d, want 20", got.Turns)
	}
	if got.Calls != 120 {
		t.Errorf("Calls = %d, want 120", got.Calls)
	}
	if got.Cost < 0.729 || got.Cost > 0.731 {
		t.Errorf("Cost = %v, want ~0.73", got.Cost)
	}
}

// summary が null のレコードが混ざっても合計は壊れない。
func TestStatsTreatsNullSummaryAsZero(t *testing.T) {
	c := 0.5
	records := []Record{
		{Summary: &Summary{TotalTurns: 10, TotalToolCalls: 20, TotalCostUSD: &c}},
		{Summary: nil},
		{Summary: &Summary{TotalTurns: 5, TotalToolCalls: 5, TotalCostUSD: nil}},
	}

	got := Stats(records)
	if got.Count != 3 {
		t.Errorf("Count = %d, want 3", got.Count)
	}
	if got.Turns != 15 {
		t.Errorf("Turns = %d, want 15", got.Turns)
	}
	if got.Calls != 25 {
		t.Errorf("Calls = %d, want 25", got.Calls)
	}
	if got.Cost != 0.5 {
		t.Errorf("Cost = %v, want 0.5", got.Cost)
	}
}

func TestStatsOfNothing(t *testing.T) {
	got := Stats(nil)
	if got.Count != 0 || got.Turns != 0 || got.Calls != 0 || got.Cost != 0 {
		t.Errorf("Stats(nil) = %+v, want all zero", got)
	}
}

// bash 版は jq で小数2桁の "$0.00" を作っていた。同じ見え方を保つ。
func TestFormatCost(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "$0.00"},
		{0.42, "$0.42"},
		{1, "$1.00"},
		{1.5, "$1.50"},
		{0.005, "$0.01"},
		{0.004, "$0.00"},
		{12.345, "$12.35"},
		{123.456, "$123.46"},
	}

	for _, tc := range cases {
		if got := FormatCost(tc.in); got != tc.want {
			t.Errorf("FormatCost(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// 時刻は completed_at の HH:MM 部分。bash 版は文字列を [11:16] で切っていた。
func TestClockTime(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"2026-08-08T18:05:31+0900", "18:05"},
		{"2026-08-08T09:00:00+0900", "09:00"},
		{"", ""},
		{"short", ""},
	}

	for _, tc := range cases {
		if got := ClockTime(tc.in); got != tc.want {
			t.Errorf("ClockTime(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestMarkerString(t *testing.T) {
	cases := []struct {
		markers Markers
		want    string
	}{
		{Markers{}, ""},
		{Markers{Merged: true}, "🚀"},
		{Markers{Slack: true}, "💬"},
		{Markers{Doc: true}, "📝"},
		{Markers{Merged: true, Slack: true, Doc: true}, "🚀💬📝"},
	}

	for _, tc := range cases {
		if got := tc.markers.String(); got != tc.want {
			t.Errorf("Markers%+v.String() = %q, want %q", tc.markers, got, tc.want)
		}
	}
}
