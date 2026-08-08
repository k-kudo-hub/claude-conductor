// Package waiting は Waiting ペインを描画する。
//
// 外部の応答（PR レビューなど）を待っているタスクだけを扱う。Dashboard から
// 切り離すことで、進行中の作業が待ちタスクで埋もれないようにする。
package waiting

import (
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// Title は枠に表示する見出し。
const Title = "Waiting"

// Event は Waiting ペインが拾う pending の event 値。
const Event = "Waiting"

// Render は待ちタスクの一覧を枠付きで描く。返る文字列は全行の表示幅が
// ちょうど width（下限は ui.MinBoxWidth）になる。
//
// height が正のときは、その高さに収まるよう本文を削る。代替画面に描く
// ため、はみ出した行は見えないまま失われるので、件数だけでも残す。
func Render(th ui.Theme, entries []pending.Entry, width, height int) string {
	w := max(width, 1)
	inner := w

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	name := lipgloss.NewStyle().Foreground(th.Text).Bold(true)

	if len(entries) == 0 {
		return ui.Section(th, Title, "", []string{muted.Render("No waiting tasks")}, w, height)
	}

	body := make([]string, 0, len(entries)*3+1)
	for i, e := range entries {
		if i > 0 {
			body = append(body, "")
		}

		// バッジ + 空白で 2 桁使う。残りにタブ名と時刻を両端で並べる。
		head := ui.Badge(th, ui.StateWaiting) + " " +
			ui.SpaceBetween(name.Render(e.Tab), muted.Render(e.Time), inner-2)
		body = append(body, head)

		if msg := flatten(e.Message); msg != "" {
			body = append(body, "  "+muted.Render(ui.Pad(msg, inner-2)))
		}
	}

	// 件数は必ず残したいので、省略は件数行より前で行う。
	count := muted.Render(countLabel(len(entries)))
	// 見出し2行（タイトル+罫線）と、末尾の空行+件数で 4 行使う。
	body = ui.FitTo(body, height, 4)
	body = append(body, "", count)

	return ui.Section(th, Title, "", body, w, 0)
}

// countLabel は件数表示。bash 版のフッター "Waiting: N" に相当する。
func countLabel(n int) string {
	if n == 1 {
		return "1 waiting"
	}
	return strconv.Itoa(n) + " waiting"
}

// flatten は改行を空白に潰す。メッセージが複数行だと枠の行数が狂うため、
// 表示は必ず 1 行に収める。
func flatten(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	return strings.TrimSpace(s)
}
