package ui

import (
	"image/color"

	"charm.land/lipgloss/v2"
)

// StateGlyph は状態インジケータの記号。bash 版は ■ / ⚡ / ● / ⟳ が
// ペインごとに散らばっていたため、1 文字に統一して区別は色で行う。
const StateGlyph = "●"

// State はタスクの表示上の状態。
type State int

const (
	// StatePending はユーザーの応答を待っている状態。
	StatePending State = iota
	// StateDone はターンが終了した状態。
	StateDone
	// StateWaiting は PR レビューなど外部の応答を待っている状態。
	StateWaiting
	// StateIdle は待ちが無く実行中の状態。
	StateIdle
)

// Label は状態の短い英語ラベルを返す。色を判別できない環境でも
// 状態が読み取れるように、記号と併記して使う。
func (s State) Label() string {
	switch s {
	case StateDone:
		return "done"
	case StateWaiting:
		return "waiting"
	case StateIdle:
		return "running"
	default:
		return "pending"
	}
}

// StateFromEvent は pending ファイルの event 値を状態に変換する。
//
// event に入りうる値は hooks（pending-notify.sh）が書く Notification / Stop、
// waiting-toggle.sh が書く Waiting、そして hook_event_name を取得できなかった
// ときの unknown。bash 版の Dashboard は Stop 以外をすべて応答待ちとして
// 描いていたため、未知の値も StatePending に倒す。
func StateFromEvent(event string) State {
	switch event {
	case "Stop":
		return StateDone
	case "Waiting":
		return StateWaiting
	default:
		return StatePending
	}
}

// Color は状態に対応する色を返す。
func (s State) Color(th Theme) color.Color {
	switch s {
	case StateDone:
		return th.Done
	case StateWaiting:
		return th.Waiting
	case StateIdle:
		return th.Idle
	default:
		return th.Pending
	}
}

// Badge は状態インジケータを色付きで描く。
func Badge(th Theme, s State) string {
	return lipgloss.NewStyle().Foreground(s.Color(th)).Render(StateGlyph)
}
