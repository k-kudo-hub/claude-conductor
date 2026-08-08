// Package news は AI Tech News ペインを描画する。
//
// 記事は fetch-news.sh が RSS から取得して
// $CONDUCTOR_HOME/news/YYYY-MM-DD.json に置く。ここでは読み取りと表示、
// および記事を開く／取り直す操作を担う。
package news

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// Title は枠に表示する見出し。
const Title = "AI Tech News"

// Item は記事 1 件。fetch-news.sh が書く JSON の要素に対応する。
type Item struct {
	Title       string `json:"title"`
	URL         string `json:"url"`
	Description string `json:"description"`
}

type file struct {
	Items []Item `json:"items"`
}

// Load はその日のニュースを読む。ファイルが無い・壊れている場合は空を返し、
// 「まだ取得していない」状態として描画側で扱う。
func Load(dir, date string) []Item {
	data, err := os.ReadFile(filepath.Join(dir, date+".json"))
	if err != nil {
		return nil
	}
	var f file
	if err := json.Unmarshal(data, &f); err != nil {
		return nil
	}
	return f.Items
}

// URLForIndex は i 番目の記事の URL を返す。範囲外や URL 未設定は空文字を
// 返し、呼び出し側は何もしない。
func URLForIndex(items []Item, i int) string {
	if i < 0 || i >= len(items) {
		return ""
	}
	return items[i].URL
}

// Render は記事一覧を枠付きで描く。loading 中は取得中の表示に差し替える。
//
// height が正のときは、その高さに収まるよう記事を削る。
func Render(th ui.Theme, items []Item, date string, loading bool, width, height int) string {
	w := max(width, ui.MinBoxWidth)
	inner := w - 4

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	accent := lipgloss.NewStyle().Foreground(th.Accent)
	headline := lipgloss.NewStyle().Foreground(th.Text)

	switch {
	case loading:
		return ui.Box(th, Title, []string{
			muted.Render("Fetching news..."),
			"",
			muted.Render(ui.SpaceBetween("", date, inner)),
		}, w)
	case len(items) == 0:
		return ui.Box(th, Title, []string{
			muted.Render("No news yet. Press [r] to reload."),
			"",
			muted.Render(ui.SpaceBetween("", date, inner)),
		}, w)
	}

	body := make([]string, 0, len(items)*3+2)
	for i, it := range items {
		if i > 0 {
			body = append(body, "")
		}

		// 番号 + 空白で 2 桁使い、残りに見出しを収める。
		num := accent.Render(strconv.Itoa(i + 1))
		body = append(body, num+" "+headline.Render(ui.Pad(flatten(it.Title), inner-2)))

		if d := flatten(it.Description); d != "" {
			body = append(body, "  "+muted.Render(ui.Pad(d, inner-2)))
		}
	}

	// キーヒントと日付は必ず残す。省略はその前で行う。
	footer := muted.Render(ui.SpaceBetween(keyHint(len(items)), date, inner))
	if lines := ui.BodyLines(height); lines > 0 {
		body = ui.Fit(body, lines-2)
	}
	body = append(body, "", footer)

	return ui.Box(th, Title, body, w)
}

// keyHint は開ける記事番号の案内。1 件だけのときに [1-1] とは出さない。
func keyHint(n int) string {
	if n == 1 {
		return "[1] open · [r] reload"
	}
	return "[1-" + strconv.Itoa(n) + "] open · [r] reload"
}

// flatten は改行やタブを空白に潰す。1 記事が複数行になると枠の行数が狂う。
func flatten(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\t", " ")
	return strings.TrimSpace(s)
}
