package ui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

// raw モードでは ^C が SIGINT にならないため、各ペインが自分で
// 終了を扱う必要がある。
func TestIsQuitAcceptsCtrlC(t *testing.T) {
	msg := tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}

	if !IsQuit(msg) {
		t.Errorf("IsQuit(%q) = false, want true", msg.String())
	}
}

// 常駐するペインを、通常の操作キーで閉じてしまわないこと。
func TestIsQuitRejectsOrdinaryKeys(t *testing.T) {
	for _, key := range []string{"q", "d", "r", "n", "1", "esc"} {
		msg := tea.KeyPressMsg{Code: rune(key[0]), Text: key}
		if IsQuit(msg) {
			t.Errorf("IsQuit(%q) = true, want false", key)
		}
	}
}

func TestBodyLines(t *testing.T) {
	cases := []struct {
		height int
		want   int
	}{
		{0, 0},   // 高さ不明 -> 制限しない
		{-1, 0},  //
		{1, 1},   // 枠だけで埋まっても最低 1 行は返す
		{2, 1},   //
		{3, 1},   //
		{10, 8},  // 上辺と下辺で 2 行使う
		{24, 22}, //
	}

	for _, tc := range cases {
		if got := BodyLines(tc.height); got != tc.want {
			t.Errorf("BodyLines(%d) = %d, want %d", tc.height, got, tc.want)
		}
	}
}
