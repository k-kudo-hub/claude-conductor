package ui

import (
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
// 切り詰めに省略記号を付けないのは意図的で、… のような East Asian
// Ambiguous 文字は端末によって幅 2 と解釈され、枠の右辺がずれるため。
func Pad(s string, width int) string {
	if width <= 0 {
		return ""
	}
	w := lipgloss.Width(s)
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	return s + strings.Repeat(" ", width-w)
}

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
