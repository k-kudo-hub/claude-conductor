// Package zellij は Zellij の CLI を呼び、その出力を読む。
package zellij

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// CommandTimeout は zellij コマンドを待つ上限。
//
// zellij は指定されたセッションが見つからない場合などに応答を返さない
// ことがある。ペインの描画はこの結果を待つので、上限を設けないと
// ダッシュボードごと止まってしまう。
const CommandTimeout = 3 * time.Second

// Tab は Zellij のタブ。
type Tab struct {
	ID   string
	Name string
}

// ParseTabs は `zellij action list-tabs` の出力を解釈する。
//
// 出力は 1 行目がヘッダーで、以降が "<id> <position> <name>"。名前は
// 空白を含みうるので、3 列目以降をすべて名前として扱う。
func ParseTabs(out string) []Tab {
	lines := strings.Split(out, "\n")
	if len(lines) <= 1 {
		return nil
	}

	tabs := make([]Tab, 0, len(lines)-1)
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		// id と position を落とした残りが名前。元の空白を保つため、
		// Fields ではなく元行から前 2 列ぶんを削る。
		rest := line
		for i := 0; i < 2; i++ {
			rest = strings.TrimLeft(rest, " ")
			if idx := strings.IndexByte(rest, ' '); idx >= 0 {
				rest = rest[idx:]
			}
		}
		name := strings.TrimLeft(rest, " ")
		if name == "" {
			continue
		}
		tabs = append(tabs, Tab{ID: fields[0], Name: name})
	}
	return tabs
}

// FindByName は名前の一致するタブを返す。見つからなければ nil。
func FindByName(tabs []Tab, name string) *Tab {
	for i := range tabs {
		if tabs[i].Name == name {
			return &tabs[i]
		}
	}
	return nil
}

// Names はタブ名をタブ順に返す。
func Names(tabs []Tab) []string {
	names := make([]string, 0, len(tabs))
	for _, t := range tabs {
		names = append(names, t.Name)
	}
	return names
}

// ListTabs は現在のタブをタブ順で返す。Zellij の外で実行された場合など、
// コマンドが失敗したときは空を返す（描画側はタブ順を諦めて素の順で出す）。
func ListTabs() []Tab {
	ctx, cancel := context.WithTimeout(context.Background(), CommandTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, "zellij", "action", "list-tabs").Output()
	if err != nil {
		return nil
	}
	return ParseTabs(string(out))
}

// QueryTabNames は現在のタブ名を 1 行 1 件で返す。取れない場合は空。
func QueryTabNames() []string {
	ctx, cancel := context.WithTimeout(context.Background(), CommandTimeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, "zellij", "action", "query-tab-names").Output()
	if err != nil {
		return nil
	}

	var names []string
	for _, line := range strings.Split(string(out), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names
}

// GoToTab は名前でタブを切り替える。
func GoToTab(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), CommandTimeout)
	defer cancel()

	return exec.CommandContext(ctx, "zellij", "action", "go-to-tab-name", name).Run()
}
