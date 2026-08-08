package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
)

// 枠の各行がちょうど指定幅になることを保証する。bash版の描画は区切り線が
// 26文字固定でペイン幅に追従しなかったため、ここが移行の要になる。
func TestBoxEveryLineHasExactWidth(t *testing.T) {
	th := Resolve(DefaultThemeName)

	cases := []struct {
		name  string
		title string
		body  []string
		width int
	}{
		{"ascii", "Current Tasks", []string{"1 api-feature", "needs permission"}, 40},
		{"japanese", "タスク一覧", []string{"1 開発タスク", "承認待ちです"}, 40},
		{"emoji", "Done", []string{"🚀 merged", "💬 slack 📝 doc"}, 30},
		{"narrow", "Waiting", []string{"external"}, MinBoxWidth},
		{"wide", "News", []string{"headline"}, 120},
		{"empty body", "Waiting", nil, 24},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Box(th, tc.title, tc.body, tc.width)
			for i, line := range strings.Split(out, "\n") {
				if w := lipgloss.Width(line); w != tc.width {
					t.Errorf("line %d width = %d, want %d\nline: %q", i, w, tc.width, line)
				}
			}
		})
	}
}

func TestBoxHasTopAndBottomBorder(t *testing.T) {
	th := Resolve(DefaultThemeName)
	lines := strings.Split(Box(th, "Title", []string{"body"}, 30), "\n")

	if len(lines) < 3 {
		t.Fatalf("Box produced %d lines, want at least 3", len(lines))
	}
	if !strings.Contains(lines[0], "╭") || !strings.Contains(lines[0], "╮") {
		t.Errorf("top line missing rounded corners: %q", lines[0])
	}
	last := lines[len(lines)-1]
	if !strings.Contains(last, "╰") || !strings.Contains(last, "╯") {
		t.Errorf("bottom line missing rounded corners: %q", last)
	}
}

func TestBoxRendersTitleAndBody(t *testing.T) {
	th := Resolve(DefaultThemeName)
	out := Box(th, "Current Tasks", []string{"api-feature"}, 40)

	if !strings.Contains(out, "Current Tasks") {
		t.Errorf("Box output does not contain the title:\n%s", out)
	}
	if !strings.Contains(out, "api-feature") {
		t.Errorf("Box output does not contain the body:\n%s", out)
	}
}

// タイトルが枠幅を超えても行が伸びてはならない。伸びるとZellijのペインで
// 折り返され、以降の行がすべてずれる。
func TestBoxTruncatesLongTitle(t *testing.T) {
	th := Resolve(DefaultThemeName)
	long := strings.Repeat("very-long-title-", 10)

	for _, line := range strings.Split(Box(th, long, nil, 30), "\n") {
		if w := lipgloss.Width(line); w != 30 {
			t.Fatalf("line width = %d, want 30\nline: %q", w, line)
		}
	}
}

func TestBoxTruncatesLongBodyLine(t *testing.T) {
	th := Resolve(DefaultThemeName)
	long := strings.Repeat("x", 200)

	for _, line := range strings.Split(Box(th, "T", []string{long}, 30), "\n") {
		if w := lipgloss.Width(line); w != 30 {
			t.Fatalf("line width = %d, want 30\nline: %q", w, line)
		}
	}
}

// 色付きの本文（ANSIエスケープ入り）でも表示幅の計算が崩れないこと。
func TestBoxHandlesStyledBodyLine(t *testing.T) {
	th := Resolve(DefaultThemeName)
	styled := lipgloss.NewStyle().Foreground(th.Accent).Render("colored-text")

	for _, line := range strings.Split(Box(th, "T", []string{styled}, 30), "\n") {
		if w := lipgloss.Width(line); w != 30 {
			t.Fatalf("line width = %d, want 30\nline: %q", w, line)
		}
	}
}

// 極端に狭いペインでも最小幅まで広げて描画を破綻させない。
func TestBoxClampsWidthToMinimum(t *testing.T) {
	th := Resolve(DefaultThemeName)

	for _, w := range []int{-10, 0, 1, MinBoxWidth - 1} {
		out := Box(th, "T", []string{"body"}, w)
		for _, line := range strings.Split(out, "\n") {
			if got := lipgloss.Width(line); got != MinBoxWidth {
				t.Errorf("width %d: line width = %d, want %d", w, got, MinBoxWidth)
			}
		}
	}
}

func TestRuleHasExactWidth(t *testing.T) {
	th := Resolve(DefaultThemeName)

	for _, w := range []int{1, 10, 40, 120} {
		if got := lipgloss.Width(Rule(th, w)); got != w {
			t.Errorf("Rule(%d) width = %d, want %d", w, got, w)
		}
	}
}

func TestRuleWithNonPositiveWidthIsEmpty(t *testing.T) {
	th := Resolve(DefaultThemeName)

	for _, w := range []int{0, -1} {
		if got := Rule(th, w); got != "" {
			t.Errorf("Rule(%d) = %q, want empty", w, got)
		}
	}
}

// 幅に満たない行は右側を空白で埋める。埋めないと枠の右辺が揃わない。
func TestPadPadsAndTruncates(t *testing.T) {
	cases := []struct {
		in    string
		width int
	}{
		{"short", 20},
		{"日本語テキスト", 20},
		{strings.Repeat("x", 50), 20},
		{"", 20},
	}

	for _, tc := range cases {
		if got := lipgloss.Width(Pad(tc.in, tc.width)); got != tc.width {
			t.Errorf("Pad(%q, %d) width = %d, want %d", tc.in, tc.width, got, tc.width)
		}
	}
}

// 全角文字の途中で切ると、その文字はまるごと落ちて幅が 1 桁足りなくなる。
// 切ったあとに埋め直していないと、日本語のときだけ枠の右辺がずれる。
func TestPadRefillsAfterWideCharTruncation(t *testing.T) {
	cases := []struct {
		in    string
		width int
	}{
		{"あいうえお", 5},
		{"あいうえお", 7},
		{"あいうえお", 9},
		{"日本語テキスト", 9},
		{"🚀🚀🚀", 5},
		{"aあiいuう", 5},
		{"あ", 1},
	}

	for _, tc := range cases {
		got := Pad(tc.in, tc.width)
		if w := lipgloss.Width(got); w != tc.width {
			t.Errorf("Pad(%q, %d) width = %d, want %d (got %q)", tc.in, tc.width, w, tc.width, got)
		}
	}
}

// 同じ崩れは Box 経由でも起きてはならない。
func TestBoxKeepsWidthWhenWideCharIsCut(t *testing.T) {
	th := Resolve(DefaultThemeName)

	for _, w := range []int{13, 14, 15, 21, 30} {
		out := Box(th, "T", []string{"あいうえおかきくけこ", "混在 mixed テキスト"}, w)
		for i, line := range strings.Split(out, "\n") {
			if got := lipgloss.Width(line); got != w {
				t.Errorf("width %d: line %d = %d\nline: %q", w, i, got, line)
			}
		}
	}
}

// 表示できる行数を超えた本文は、末尾を削って省略されたと分かるようにする。
func TestFit(t *testing.T) {
	body := []string{"a", "b", "c", "d", "e"}

	cases := []struct {
		name     string
		maxLines int
		want     []string
	}{
		{"fits exactly", 5, []string{"a", "b", "c", "d", "e"}},
		{"more room than needed", 10, []string{"a", "b", "c", "d", "e"}},
		{"trims the tail", 3, []string{"a", "b", "+3 more"}},
		{"single line", 1, []string{"+5 more"}},
		{"no room", 0, []string{"a", "b", "c", "d", "e"}},
		{"negative", -1, []string{"a", "b", "c", "d", "e"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Fit(body, tc.maxLines)
			if len(got) != len(tc.want) {
				t.Fatalf("Fit(_, %d) = %v, want %v", tc.maxLines, got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Errorf("line %d = %q, want %q", i, got[i], tc.want[i])
				}
			}
		})
	}
}

// 省略した件数の合計が元の行数と一致すること。数え間違いは
// 「何件隠れているか」を誤って伝える。
func TestFitReportsEveryDroppedLine(t *testing.T) {
	for total := 1; total <= 20; total++ {
		body := make([]string, total)
		for i := range body {
			body[i] = "line"
		}
		for maxLines := 1; maxLines <= total; maxLines++ {
			got := Fit(body, maxLines)
			if len(got) > maxLines {
				t.Fatalf("Fit(%d lines, %d) returned %d lines", total, maxLines, len(got))
			}
			if len(got) == total {
				continue
			}
			dropped := total - (len(got) - 1)
			want := moreLabel(dropped)
			if last := got[len(got)-1]; last != want {
				t.Errorf("Fit(%d lines, %d) last = %q, want %q", total, maxLines, last, want)
			}
		}
	}
}

// タブ名を左、時刻を右に置く行の組み立て。幅は常にちょうど width になる。
func TestSpaceBetweenHasExactWidth(t *testing.T) {
	cases := []struct {
		name  string
		left  string
		right string
		width int
	}{
		{"fits", "api-feature", "18:05:31", 40},
		{"exact fit", "abc", "de", 5},
		{"left too long", strings.Repeat("x", 100), "18:05:31", 30},
		{"right alone too long", "tab", strings.Repeat("y", 100), 20},
		{"japanese left", "開発タスク", "18:05:31", 30},
		{"japanese cut mid-char", "開発タスクの続き", "18:05:31", 21},
		{"empty left", "", "18:05:31", 20},
		{"empty right", "api-feature", "", 20},
		{"both empty", "", "", 20},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := lipgloss.Width(SpaceBetween(tc.left, tc.right, tc.width)); got != tc.width {
				t.Errorf("SpaceBetween(%q, %q, %d) width = %d, want %d",
					tc.left, tc.right, tc.width, got, tc.width)
			}
		})
	}
}

func TestSpaceBetweenPutsRightAtTheEnd(t *testing.T) {
	got := SpaceBetween("tab", "18:05", 20)

	if !strings.HasPrefix(got, "tab") {
		t.Errorf("SpaceBetween = %q, want it to start with the left text", got)
	}
	if !strings.HasSuffix(got, "18:05") {
		t.Errorf("SpaceBetween = %q, want it to end with the right text", got)
	}
}

// 右の情報（時刻）は残し、左（タブ名）を削る。時刻が消えると
// いつからの待ちか分からなくなる。
func TestSpaceBetweenTruncatesLeftNotRight(t *testing.T) {
	got := SpaceBetween(strings.Repeat("x", 100), "18:05", 20)

	if !strings.HasSuffix(got, "18:05") {
		t.Errorf("SpaceBetween = %q, want the right text preserved", got)
	}
}

func TestSpaceBetweenWithNonPositiveWidthIsEmpty(t *testing.T) {
	for _, w := range []int{0, -1} {
		if got := SpaceBetween("a", "b", w); got != "" {
			t.Errorf("SpaceBetween(width=%d) = %q, want empty", w, got)
		}
	}
}
