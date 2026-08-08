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
