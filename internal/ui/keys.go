package ui

import tea "charm.land/bubbletea/v2"

// IsQuit は終了を指示するキーかを返す。
//
// Bubble Tea は端末を raw モードにするため、^C は SIGINT ではなく
// キー入力として届く。各ペインがこれを扱わないと、Zellij の外で直接
// 起動したときに別の端末から kill するしかなくなる。
//
// q は割り当てない。ペインは常駐が前提で、タスク名やニュース番号を
// 打とうとした指が触れただけで消えると復帰の手間が大きい。
func IsQuit(msg tea.KeyPressMsg) bool {
	switch msg.String() {
	case "ctrl+c":
		return true
	default:
		return false
	}
}

// BodyLines は枠の中で本文に使える行数を返す。height はペイン全体の
// 高さ。分からない（0 以下）ときは制限しない意味で 0 を返す。
func BodyLines(height int) int {
	if height <= 0 {
		return 0
	}
	n := height - BoxOverhead
	if n < 1 {
		return 1
	}
	return n
}
