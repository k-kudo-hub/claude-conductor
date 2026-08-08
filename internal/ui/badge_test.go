package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
)

// pendingファイルの event 値と状態の対応。hooks（pending-notify.sh）と
// スクリーン検出（screen-detect-lib.sh）が書く値、および waiting-toggle.sh の
// Waiting をすべて含む。
func TestStateFromEvent(t *testing.T) {
	cases := []struct {
		event string
		want  State
	}{
		{"Stop", StateDone},
		{"Waiting", StateWaiting},
		{"Notification", StatePending},
		// hook_event_name が取れなかった場合のフォールバック。bash版の
		// Dashboard は Stop 以外をすべて赤（応答待ち）で描いていた。
		{"unknown", StatePending},
		{"", StatePending},
		{"SomeFutureEvent", StatePending},
	}

	for _, tc := range cases {
		if got := StateFromEvent(tc.event); got != tc.want {
			t.Errorf("StateFromEvent(%q) = %v, want %v", tc.event, got, tc.want)
		}
	}
}

// 記号は全状態で同じ1文字に統一する。bash版は ■ / ⚡ / ● / ⟳ が混在していた。
func TestBadgeUsesOneGlyphForEveryState(t *testing.T) {
	th := Resolve(DefaultThemeName)

	for _, s := range []State{StatePending, StateDone, StateWaiting, StateIdle} {
		badge := Badge(th, s)
		if w := lipgloss.Width(badge); w != 1 {
			t.Errorf("Badge(%v) width = %d, want 1", s, w)
		}
		if !strings.Contains(badge, StateGlyph) {
			t.Errorf("Badge(%v) = %q, want it to contain %q", s, badge, StateGlyph)
		}
	}
}

// 状態の区別は色で行う。同じ色になる状態があると Dashboard 上で
// 完了と応答待ちが見分けられなくなる。
func TestBadgeColorsDifferPerState(t *testing.T) {
	th := Resolve(DefaultThemeName)

	seen := map[string]State{}
	for _, s := range []State{StatePending, StateDone, StateWaiting, StateIdle} {
		rendered := Badge(th, s)
		if prev, dup := seen[rendered]; dup {
			t.Errorf("Badge(%v) renders identically to Badge(%v): %q", s, prev, rendered)
		}
		seen[rendered] = s
	}
}

func TestStateLabel(t *testing.T) {
	cases := []struct {
		state State
		want  string
	}{
		{StatePending, "pending"},
		{StateDone, "done"},
		{StateWaiting, "waiting"},
		{StateIdle, "running"},
	}

	for _, tc := range cases {
		if got := tc.state.Label(); got != tc.want {
			t.Errorf("%v.Label() = %q, want %q", tc.state, got, tc.want)
		}
	}
}
