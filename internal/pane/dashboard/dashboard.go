// Package dashboard は Dashboard（Current Tasks）ペインを描画する。
//
// 応答待ち・完了のタスクを Zellij のタブ順に並べ、番号でジャンプ、
// d+番号 で削除する。外部応答待ち（Waiting）は Waiting ペインが持つ。
package dashboard

import (
	"fmt"
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/pending"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// Title は枠に表示する見出し。
const Title = "Current Tasks"

// EntryForIndex は表示順 i 番目のエントリを返す。範囲外は nil。
func EntryForIndex(entries []pending.Entry, i int) *pending.Entry {
	if i < 0 || i >= len(entries) {
		return nil
	}
	return &entries[i]
}

// OrderByTabs を Zellij のタブ順に並べ替え、Dashboard に出すものだけを残す。
//
// 除くのは 2 つ。外部応答待ち（Waiting ペインの担当）と、対応するタブが
// もう無いもの（閉じたタブに残った pending。ジャンプ先が無い）。
// タブ一覧が取れない場合は並べ替えを諦め、Waiting だけ除いて元の順で返す。
func OrderByTabs(entries []pending.Entry, tabs []string) []pending.Entry {
	active := make([]pending.Entry, 0, len(entries))
	for _, e := range entries {
		if e.Event == WaitingEvent {
			continue
		}
		active = append(active, e)
	}

	if len(tabs) == 0 {
		return active
	}

	ordered := make([]pending.Entry, 0, len(active))
	for _, tab := range tabs {
		for _, e := range active {
			if e.Tab == tab {
				ordered = append(ordered, e)
			}
		}
	}
	return ordered
}

// WaitingEvent は Waiting ペインが受け持つ event 値。
const WaitingEvent = "Waiting"

// Render はタスク一覧を枠付きで描く。prompt が空でなければ、キーヒントの
// 代わりにその案内を出す（削除の番号入力待ちなど）。
func Render(th ui.Theme, session string, entries []pending.Entry, prompt string, width int) string {
	w := max(width, ui.MinBoxWidth)
	inner := w - 4

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	accent := lipgloss.NewStyle().Foreground(th.Accent)
	name := lipgloss.NewStyle().Foreground(th.Text).Bold(true)

	if len(entries) == 0 {
		body := []string{
			lipgloss.NewStyle().Foreground(th.Done).Render("All tasks running"),
			"",
			muted.Render(ui.SpaceBetween("", session, inner)),
		}
		return ui.Box(th, Title, body, w)
	}

	body := make([]string, 0, len(entries)*3+2)
	for i, e := range entries {
		if i > 0 {
			body = append(body, "")
		}

		state := ui.StateFromEvent(e.Event)
		right := e.Time
		if state == ui.StateDone {
			// 色が読めない環境でも終了したターンだと分かるようにする。
			right = e.Time + " " + state.Label()
		}

		// 番号 + バッジ + 空白で 4 桁使う。
		head := accent.Render(strconv.Itoa(i+1)) + " " + ui.Badge(th, state) + " " +
			ui.SpaceBetween(name.Render(e.Tab), muted.Render(right), inner-4)
		body = append(body, head)

		if msg := flatten(e.Message); msg != "" {
			body = append(body, "    "+muted.Render(ui.Pad(msg, inner-4)))
		}
	}

	footer := muted.Render(ui.SpaceBetween(
		fmt.Sprintf("%d pending", len(entries)),
		"[num] jump · d+[num] delete", inner))
	if prompt != "" {
		footer = lipgloss.NewStyle().Foreground(th.Danger).Bold(true).Render(prompt)
	}
	body = append(body, "", footer)

	return ui.Box(th, Title, body, w)
}

// flatten は改行やタブを空白に潰す。1 タスクが複数行になると枠が崩れる。
func flatten(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	return strings.TrimSpace(s)
}
