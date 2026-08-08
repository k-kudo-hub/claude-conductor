// Package paths は Conductor のインストール先とその配下を解決する。
//
// シェル側は各スクリプトで ${CONDUCTOR_HOME:-$HOME/.claude-conductor} を
// 展開している。同じ規則をここに一度だけ書く。
package paths

import (
	"os"
	"path/filepath"
)

// FallbackHome は HOME も CONDUCTOR_HOME も無い環境で使う退避先。
//
// os.UserHomeDir は Unix では HOME を読むだけなので、失敗したときに
// もう一度 HOME を読んでも必ず空になる。空のまま join すると相対パス
// （カレントディレクトリ配下）を指してしまい、ニュースや日次ログを
// 別の場所に読み書きし始める。絶対パスに倒しておく。
const FallbackHome = "/tmp/claude-conductor"

// Home は Conductor のインストール先を返す。CONDUCTOR_HOME があれば
// それを使う（mdev-test などが差し替える）。
func Home() string {
	if h := os.Getenv("CONDUCTOR_HOME"); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return FallbackHome
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
