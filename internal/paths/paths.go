// Package paths は Conductor のインストール先とその配下を解決する。
//
// シェル側は各スクリプトで ${CONDUCTOR_HOME:-$HOME/.claude-conductor} を
// 展開している。同じ規則をここに一度だけ書く。
package paths

import (
	"os"
	"path/filepath"
)

// Home は Conductor のインストール先を返す。CONDUCTOR_HOME があれば
// それを使う（mdev-test などが差し替える）。
func Home() string {
	if h := os.Getenv("CONDUCTOR_HOME"); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, ".claude-conductor")
}

// News は取得済みニュースの置き場を返す。
func News() string { return filepath.Join(Home(), "news") }

// Daily は完了タスクの日次ログの置き場を返す。
func Daily() string { return filepath.Join(Home(), "daily") }

// Bin は conductor バイナリの置き場を返す。
func Bin() string { return filepath.Join(Home(), "bin") }

// Scripts はシェルスクリプトの置き場を返す。
func Scripts() string { return filepath.Join(Home(), "scripts") }

// Script はスクリプトのフルパスを返す。
func Script(name string) string { return filepath.Join(Scripts(), name) }
