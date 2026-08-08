// Package ui は Conductor の各ペインが共有する描画部品を提供する。
//
// bash 版では色定義・区切り線・状態記号が 6 つのスクリプトに重複していた。
// 表示に関する決定はすべてこのパッケージに集約し、ペイン側は「何を出すか」
// だけを持つ。
package ui

import (
	"image/color"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
)

// DefaultThemeName は環境変数で指定が無いときに使うテーマ名。
const DefaultThemeName = "default"

// ThemeEnv はテーマ名を上書きする環境変数。
const ThemeEnv = "CONDUCTOR_THEME"

// Theme はペインの描画に使う色トークンの集合。
//
// 色は truecolor 前提の 16 進で定義する。実際の端末が 256 色や 16 色しか
// 扱えない場合は lipgloss が描画時にダウンサンプルするため、ここで端末の
// 能力を気にする必要はない。
type Theme struct {
	// Name は Themes のキーと一致する。
	Name string

	// Accent は見出しと選択番号に使う。
	Accent color.Color
	// Text は本文の既定色。
	Text color.Color
	// Muted は時刻やキーヒントなどの補助情報に使う。
	Muted color.Color
	// Border は枠線と区切り線に使う。
	Border color.Color

	// Pending は応答待ち（Notification）の状態色。
	Pending color.Color
	// Done は完了（Stop）の状態色。
	Done color.Color
	// Waiting は外部応答待ち（Waiting）の状態色。
	Waiting color.Color
	// Idle は待ちが無く実行中であることを示す状態色。
	Idle color.Color

	// Danger は削除など取り消せない操作の確認に使う。
	Danger color.Color
	// Success は処理の成功通知に使う。
	Success color.Color
}

// Themes は利用可能なテーマ。キーは Theme.Name と一致させる。
var Themes = map[string]Theme{
	"default": {
		Name:    "default",
		Accent:  lipgloss.Color("#7aa2f7"),
		Text:    lipgloss.Color("#c0caf5"),
		Muted:   lipgloss.Color("#565f89"),
		Border:  lipgloss.Color("#3b4261"),
		Pending: lipgloss.Color("#f7768e"),
		Done:    lipgloss.Color("#9ece6a"),
		Waiting: lipgloss.Color("#e0af68"),
		Idle:    lipgloss.Color("#7dcfff"),
		Danger:  lipgloss.Color("#db4b4b"),
		Success: lipgloss.Color("#9ece6a"),
	},
}

// Resolve は名前からテーマを引く。未知の名前や空文字は既定テーマに落とす。
// 描画を止めるより既定色で出し続けるほうが実用的なため、エラーは返さない。
func Resolve(name string) Theme {
	if th, ok := Themes[strings.ToLower(strings.TrimSpace(name))]; ok {
		return th
	}
	return Themes[DefaultThemeName]
}

// Current は環境変数 CONDUCTOR_THEME を見てテーマを決める。
func Current() Theme {
	return Resolve(os.Getenv(ThemeEnv))
}
