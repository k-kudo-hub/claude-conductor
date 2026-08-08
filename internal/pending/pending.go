// Package pending は ~/.claude-pending 配下のタスク状態ファイルを読む。
//
// これらのファイルは Claude Code の hooks（pending-notify.sh ほか）と
// スクリーン検出が書き、ペインが読む。書き込み側は当面シェルのままなので、
// ここでは読み取りだけを扱う。
package pending

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// Entry は 1 タスク分の待ち状態。
type Entry struct {
	Tab             string `json:"tab"`
	Session         string `json:"session"`
	ClaudeSessionID string `json:"claude_session_id"`
	Message         string `json:"message"`
	Event           string `json:"event"`
	Time            string `json:"time"`
	Agent           string `json:"agent"`
	// PrevEvent は Waiting に入る直前の event。解除時に復元される。
	PrevEvent string `json:"prev_event,omitempty"`

	// Path は読み取り元のファイル。ジャンプや削除で消す対象になる。
	Path string `json:"-"`
}

// SessionName は Zellij のセッション名を返す。Zellij の外で実行された
// 場合は bash 版と同じ unknown に倒し、同じディレクトリを指すようにする。
func SessionName() string {
	if s := os.Getenv("ZELLIJ_SESSION_NAME"); s != "" {
		return s
	}
	return "unknown"
}

// Dir はセッションの pending ディレクトリを返す。
func Dir(session string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, ".claude-pending", session)
}

// Load はディレクトリ内の *.json をファイル名順に読む。
//
// 読めないファイルや壊れた JSON は黙って飛ばす。hooks が書き込んでいる
// 最中のファイルを掴むことがあり、そこで描画全体を止めるより、読めた分を
// 出して次のポーリングで揃えるほうが実用的なため。
func Load(dir string) []Entry {
	matches, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil
	}
	sort.Strings(matches)

	entries := make([]Entry, 0, len(matches))
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var e Entry
		if err := json.Unmarshal(data, &e); err != nil {
			continue
		}
		e.Path = path
		entries = append(entries, e)
	}
	return entries
}

// FilterByEvent は event が一致するものだけを返す。
func FilterByEvent(entries []Entry, event string) []Entry {
	out := make([]Entry, 0, len(entries))
	for _, e := range entries {
		if e.Event == event {
			out = append(out, e)
		}
	}
	return out
}
