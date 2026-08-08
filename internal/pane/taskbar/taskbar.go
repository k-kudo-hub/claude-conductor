// Package taskbar はタスクタブの下に置く 1 行の制御バーを描画する。
//
// m: Main へ / w: Waiting の切り替え / dd: タブの削除。
package taskbar

import (
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// WaitingEvent は Waiting 状態を表す pending の event 値。
const WaitingEvent = "Waiting"

// Render は制御バーを 1 行で描く。waiting のときは状態表示を前置し、
// prompt があればキーヒントの代わりにそれを出す。
//
// 常に 1 行に収める。折り返すとタスクタブのペイン割りが崩れる。
func Render(th ui.Theme, waiting bool, prompt string, width int) string {
	muted := lipgloss.NewStyle().Foreground(th.Muted)

	var line string
	switch {
	case prompt != "":
		line = lipgloss.NewStyle().Foreground(th.Danger).Bold(true).Render(prompt)
	case waiting:
		line = lipgloss.NewStyle().Foreground(th.Waiting).Bold(true).Render(ui.StateGlyph+" WAITING") +
			muted.Render("  m: Main · w: Resume · dd: Delete tab")
	default:
		line = muted.Render("m: Main · w: Waiting · dd: Delete tab")
	}

	line = " " + line
	if width > 0 {
		line = ansi.Truncate(line, width, "")
	}
	return line
}
