// Package done は Done ペインを描画する。
//
// その日に完了したタスクを一覧し、r+番号 で Dashboard へ戻す。
package done

import (
	"fmt"
	"strconv"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/daily"
	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// Title は枠に表示する見出し。
const Title = "Done"

// RecordForIndex は表示順 i 番目のレコードを返す。範囲外は nil。
func RecordForIndex(records []daily.Record, i int) *daily.Record {
	if i < 0 || i >= len(records) {
		return nil
	}
	return &records[i]
}

// Render は完了タスクの一覧を枠付きで描く。records は表示順に並んでいる
// 前提で、番号は 1 起点で振る。awaitingRestore のときはフッターを
// 番号入力の案内に差し替える。
func Render(th ui.Theme, records []daily.Record, awaitingRestore bool, width int) string {
	w := max(width, ui.MinBoxWidth)
	inner := w - 4

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	accent := lipgloss.NewStyle().Foreground(th.Accent)
	name := lipgloss.NewStyle().Foreground(th.Text)

	if len(records) == 0 {
		return ui.Box(th, Title, []string{muted.Render("No tasks completed yet")}, w)
	}

	totals := daily.Stats(records)
	body := make([]string, 0, len(records)+4)
	body = append(body,
		ui.SpaceBetween(
			accent.Render(fmt.Sprintf("%d tasks", totals.Count)),
			muted.Render(fmt.Sprintf("%d turns · %d calls · %s",
				totals.Turns, totals.Calls, daily.FormatCost(totals.Cost))),
			inner),
		"")

	for i, r := range records {
		num := accent.Render(strconv.Itoa(i + 1))
		left := num + " " + ui.Badge(th, ui.StateDone) + " " + name.Render(r.Tab)
		body = append(body, ui.SpaceBetween(left, muted.Render(metrics(r)), inner))
	}

	footer := muted.Render("r+[num] restore")
	if awaitingRestore {
		footer = lipgloss.NewStyle().Foreground(th.Accent).Bold(true).
			Render("Restore which number?")
	}
	body = append(body, "", footer)

	return ui.Box(th, Title, body, w)
}

// markerWidth は目印欄の固定幅。目印は最大 3 つ（🚀💬📝）で、絵文字は
// 表示幅 2 なので 6 桁。欄を固定しないと、目印の有無で時刻や費用の桁が
// 行ごとにずれて読みにくくなる。
const markerWidth = 6

// metrics は 1 行の右側に置く「ターン数 / 費用 / 時刻 / 目印」。
// 縦に揃うよう各欄を右詰めの固定幅で組む。summary が取れなかった
// タスクは数値をプレースホルダにする。
func metrics(r daily.Record) string {
	turns, cost := "-", "-"
	if r.Summary != nil {
		turns = strconv.Itoa(r.Summary.TotalTurns)
		if r.Summary.TotalCostUSD != nil {
			cost = daily.FormatCost(*r.Summary.TotalCostUSD)
		}
	}

	return fmt.Sprintf("%4s t %8s  %s %s",
		turns, cost, daily.ClockTime(r.CompletedAt), ui.Pad(r.Markers.String(), markerWidth))
}
