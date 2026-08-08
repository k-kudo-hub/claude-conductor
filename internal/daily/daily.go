// Package daily は完了タスクの日次ログを読む。
//
// ログは record-output.sh が
// $CONDUCTOR_HOME/daily/<zellij-session>/YYYY-MM-DD.jsonl に 1 行 1 タスクで
// 追記する。Done ペインはその日のぶんをセッション横断で読む。
package daily

import (
	"bufio"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Summary は 1 タスクの実行サマリ。record-output.sh が transcript から作る。
// トランスクリプトを解釈できなかった場合はレコードごと null になるため、
// 参照する側は nil を想定する必要がある。
type Summary struct {
	TotalTurns     int      `json:"total_turns"`
	TotalToolCalls int      `json:"total_tool_calls"`
	TotalCostUSD   *float64 `json:"total_cost_usd"`
}

// Markers はタスクに付く目印。PR をマージした、Slack に流した、
// ドキュメントを書いた、を表す。
type Markers struct {
	Merged bool `json:"merged"`
	Slack  bool `json:"slack"`
	Doc    bool `json:"doc"`
}

// String は目印を絵文字で並べた文字列を返す。
func (m Markers) String() string {
	var b strings.Builder
	if m.Merged {
		b.WriteString("🚀")
	}
	if m.Slack {
		b.WriteString("💬")
	}
	if m.Doc {
		b.WriteString("📝")
	}
	return b.String()
}

// Record は完了した 1 タスク。
type Record struct {
	Tab         string   `json:"tab"`
	Session     string   `json:"session"`
	CompletedAt string   `json:"completed_at"`
	Message     string   `json:"message"`
	Summary     *Summary `json:"summary"`
	Markers     Markers  `json:"markers"`
	Agent       string   `json:"agent"`
	// Restored は Dashboard へ戻したタスクに立つ。Done からは外れる。
	Restored bool `json:"restored"`
}

// Load は base 配下の全セッションから、その日のレコードを読む。
//
// 壊れた行は飛ばす。jsonl は追記で育つため、書き込み途中で切れた行を
// 掴むことがあり、そこで一覧を空にするより読めた分を出すほうがよい。
func Load(base, date string) []Record {
	sessions, err := os.ReadDir(base)
	if err != nil {
		return nil
	}

	var records []Record
	for _, s := range sessions {
		if !s.IsDir() {
			continue
		}
		records = append(records, loadFile(filepath.Join(base, s.Name(), date+".jsonl"))...)
	}
	return records
}

func loadFile(path string) []Record {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var records []Record
	scanner := bufio.NewScanner(f)
	// 1 行が既定の 64KB を超えることがある（tools_used が長い場合）。
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var r Record
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// Active は復元済みを除いたレコードを返す。復元されたタスクは Dashboard
// 側に戻っているため、Done に残すと二重に見える。
func Active(records []Record) []Record {
	out := make([]Record, 0, len(records))
	for _, r := range records {
		if !r.Restored {
			out = append(out, r)
		}
	}
	return out
}

// SortByCompletedAt は完了時刻の昇順に並べ替える。completed_at は
// 桁揃えされた ISO 8601 なので文字列比較で時系列になる。
func SortByCompletedAt(records []Record) {
	sort.SliceStable(records, func(i, j int) bool {
		return records[i].CompletedAt < records[j].CompletedAt
	})
}

// Totals はその日の合計。
type Totals struct {
	Count int
	Turns int
	Calls int
	Cost  float64
}

// Stats はレコード群を合計する。summary が無いレコードは件数だけ数える。
func Stats(records []Record) Totals {
	t := Totals{Count: len(records)}
	for _, r := range records {
		if r.Summary == nil {
			continue
		}
		t.Turns += r.Summary.TotalTurns
		t.Calls += r.Summary.TotalToolCalls
		if r.Summary.TotalCostUSD != nil {
			t.Cost += *r.Summary.TotalCostUSD
		}
	}
	return t
}

// FormatCost は金額を小数 2 桁で整形する。bash 版が jq で作っていた
// "$0.00" と同じ見え方を保つ。
func FormatCost(v float64) string {
	return fmt.Sprintf("$%.2f", math.Round(v*100)/100)
}

// ClockTime は completed_at から HH:MM を取り出す。解釈できない値は
// 空文字を返し、呼び出し側は時刻欄を空けて描く。
func ClockTime(completedAt string) string {
	// "2026-08-08T18:05:31+0900" の 11..16 が HH:MM。
	if len(completedAt) < 16 {
		return ""
	}
	return completedAt[11:16]
}
