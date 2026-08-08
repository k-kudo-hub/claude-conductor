package ui

import (
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// MinBoxWidth は Box が描ける最小の幅。これを下回る幅を渡された場合は
// ここまで広げる。Zellij のペインを極端に狭めても枠が崩れないようにする。
const MinBoxWidth = 12

// 枠に使う罫線。Nerd Font に依存しない標準 Unicode のみを使う。
const (
	cornerTopLeft     = "╭"
	cornerTopRight    = "╮"
	cornerBottomLeft  = "╰"
	cornerBottomRight = "╯"
	lineHorizontal    = "─"
	lineVertical      = "│"
)

// Pad は文字列の表示幅をちょうど width に揃える。長ければ切り、短ければ
// 右を空白で埋める。ANSI エスケープを含む文字列でも表示幅で判断する。
//
// 切り詰めに省略記号を付けないのは意図的。… のような East Asian Ambiguous
// 文字は端末によって幅 2 と解釈されるため、付けると幅が読めなくなる。
//
// 切り詰めたあとに必ず測り直して埋める。全角文字の途中で切ると、その文字は
// まるごと落ちるので結果は width より 1 桁狭くなる。ここで埋め直さないと
// 枠の右辺が日本語のときだけずれる。
func Pad(s string, width int) string {
	if width <= 0 {
		return ""
	}
	w := lipgloss.Width(s)
	if w > width {
		s = ansi.Truncate(s, width, "")
		w = lipgloss.Width(s)
	}
	return s + strings.Repeat(" ", width-w)
}

// Fit は本文を maxLines 行に収める。収まらない場合は末尾を削り、
// 最終行を「+N more」に差し替えて省略したことを示す。
//
// ペインは代替画面に描くので、はみ出した行は見えないまま失われる。
// 件数が読めなくなるより、省略されたと分かるほうがよい。
func Fit(body []string, maxLines int) []string {
	if maxLines <= 0 || len(body) <= maxLines {
		return body
	}
	if maxLines == 1 {
		return []string{moreLabel(len(body))}
	}

	out := make([]string, 0, maxLines)
	out = append(out, body[:maxLines-1]...)
	return append(out, moreLabel(len(body)-(maxLines-1)))
}

func moreLabel(n int) string {
	return "+" + strconv.Itoa(n) + " more"
}

// BoxOverhead は Box が本文に加える行数（上辺と下辺）。呼び出し側が
// 本文に割ける行数を計算するために使う。
const BoxOverhead = 2

// Rule は幅 width の区切り線を返す。
func Rule(th Theme, width int) string {
	if width <= 0 {
		return ""
	}
	return lipgloss.NewStyle().
		Foreground(th.Border).
		Render(strings.Repeat(lineHorizontal, width))
}

// Box はタイトル付きの枠にボディを収めて返す。返る文字列は各行の表示幅が
// ちょうど width（下限は MinBoxWidth）になる。
//
//	╭─ Current Tasks ──────────────╮
//	│ 1 ● api-feature      18:05   │
//	╰──────────────────────────────╯
func Box(th Theme, title string, body []string, width int) string {
	w := max(width, MinBoxWidth)
	border := lipgloss.NewStyle().Foreground(th.Border)
	// 内側の使用可能幅。左右の "│ " と " │" で 4 桁を使う。
	inner := w - 4

	lines := make([]string, 0, len(body)+2)
	lines = append(lines, boxTop(th, border, title, w))
	for _, line := range body {
		lines = append(lines,
			border.Render(lineVertical)+" "+Pad(line, inner)+" "+border.Render(lineVertical))
	}
	lines = append(lines, border.Render(
		cornerBottomLeft+strings.Repeat(lineHorizontal, w-2)+cornerBottomRight))

	return strings.Join(lines, "\n")
}

// boxTop は枠の上辺を組み立てる。タイトルは罫線に埋め込み、収まらなければ
// 切り詰める。タイトルが空なら罫線だけの上辺にする。
func boxTop(th Theme, border lipgloss.Style, title string, w int) string {
	if title == "" {
		return border.Render(
			cornerTopLeft + strings.Repeat(lineHorizontal, w-2) + cornerTopRight)
	}

	// "╭─ " (3) + タイトル + " " (1) + 埋めの罫線 + "╮" (1)
	const fixed = 5
	t := ansi.Truncate(title, w-fixed, "")
	fill := w - fixed - lipgloss.Width(t)

	return border.Render(cornerTopLeft+lineHorizontal+" ") +
		lipgloss.NewStyle().Foreground(th.Accent).Bold(true).Render(t) +
		border.Render(" "+strings.Repeat(lineHorizontal, fill)+cornerTopRight)
}
