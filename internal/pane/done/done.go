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

// MaxSelectable は番号で復元できる件数。キー入力は 1 打鍵で受けるため
// 2 桁を待てず、10 以上は指定できない。番号を振るのもここまでにして、
// 選べない番号が並ばないようにする。
const MaxSelectable = 9

// RecordForIndex は表示順 i 番目のレコードを返す。範囲外、および番号で
// 選べない位置（MaxSelectable 以降）は nil。
func RecordForIndex(records []daily.Record, i int) *daily.Record {
	if i < 0 || i >= len(records) || i >= MaxSelectable {
		return nil
	}
	return &records[i]
}

// Render は完了タスクの一覧を枠付きで描く。records は表示順に並んでいる
// 前提で、番号は 1 起点で振る。awaitingRestore のときはフッターを
// 番号入力の案内に差し替える。
func Render(th ui.Theme, records []daily.Record, awaitingRestore bool, width, height int) string {
	w := max(width, 1)
	inner := w

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	accent := lipgloss.NewStyle().Foreground(th.Accent)
	name := lipgloss.NewStyle().Foreground(th.Text)

	if len(records) == 0 {
		body := []string{muted.Render("No tasks completed yet")}
		// 最後の 1 件を復元した直後もここに来る。プロンプトを捨てると
		// 何が起きたのか分からないまま画面が変わる。
		if awaitingRestore {
			body = append(body, "",
				lipgloss.NewStyle().Foreground(th.Accent).Bold(true).Render("Restore which number?"))
		}
		return ui.Section(th, Title, "", body, w, height)
	}

	totals := daily.Stats(records)
	summary := ui.SpaceBetween(
		accent.Render(fmt.Sprintf("%d tasks", totals.Count)),
		muted.Render(fmt.Sprintf("%d turns · %d calls · %s",
			totals.Turns, totals.Calls, daily.FormatCost(totals.Cost))),
		inner)
	body := make([]string, 0, len(records)+4)

	for i, r := range records {
		// 番号で選べない位置は空欄にする。押しても何も起きない番号を
		// 見せないため。
		num := muted.Render(" ")
		if i < MaxSelectable {
			num = accent.Render(strconv.Itoa(i + 1))
		}
		left := num + " " + ui.Badge(th, ui.StateDone) + " " + name.Render(r.Tab)
		body = append(body, ui.SpaceBetween(left, muted.Render(metrics(r)), inner))
	}

	hint := "r+[num] restore"
	if len(records) > MaxSelectable {
		hint = "r+[num] restore (first 9)"
	}
	footer := muted.Render(hint)
	if awaitingRestore {
		footer = lipgloss.NewStyle().Foreground(th.Accent).Bold(true).
			Render("Restore which number?")
	}
	// 見出し2行（タイトル+罫線）、集計+空行の2行、末尾の空行+フッターの
	// 2行を除いた分が一覧に使える。
	body = ui.FitTo(body, height, 6)
	body = append([]string{summary, ""}, body...)
	body = append(body, "", footer)

	return ui.Section(th, Title, "", body, w, 0)
}

// markerWidth は目印欄の固定幅。目印は最大 3 つ（🚀💬📝）で、絵文字は
// 表示幅 2 なので 6 桁。欄を固定しないと、目印の有無で時刻や費用の桁が
// 行ごとにずれて読みにくくなる。
const markerWidth = 6

// clockWidth は時刻欄の固定幅（HH:MM）。
const clockWidth = 5

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

	// 時刻も固定幅にする。completed_at が読めないレコードで空になると、
	// 目印の欄が左へずれて桁が揃わなくなる。
	return fmt.Sprintf("%4s t %8s  %s %s",
		turns, cost,
		ui.Pad(daily.ClockTime(r.CompletedAt), clockWidth),
		ui.Pad(r.Markers.String(), markerWidth))
}
