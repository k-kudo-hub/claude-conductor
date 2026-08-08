package taskbar

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

// 制御バーは 1 行。複数行になるとタスクタブのペイン割りが崩れる。
func TestRenderIsAlwaysOneLine(t *testing.T) {
	cases := []struct {
		name    string
		waiting bool
		prompt  string
		width   int
	}{
		{"normal", false, "", 80},
		{"waiting", true, "", 80},
		{"prompt", false, "Press d again to delete", 80},
		{"narrow", true, "", 20},
		{"very narrow", true, "", 8},
		{"wide", false, "", 200},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), tc.waiting, tc.prompt, tc.width)
			if strings.Contains(out, "\n") {
				t.Errorf("output contains a newline: %q", out)
			}
			if got := lipgloss.Width(out); got > tc.width {
				t.Errorf("width = %d, want at most %d\nline: %q", got, tc.width, out)
			}
		})
	}
}

func TestRenderShowsKeyHints(t *testing.T) {
	out := Render(theme(), false, "", 80)

	for _, want := range []string{"m", "Main", "w", "Waiting", "dd"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q: %q", want, out)
		}
	}
}

// Waiting 中はタスクタブからもその状態が分かるようにする。
func TestRenderShowsWaitingIndicator(t *testing.T) {
	out := Render(theme(), true, "", 80)

	if !strings.Contains(out, "WAITING") {
		t.Errorf("output does not show the waiting indicator: %q", out)
	}
	// 解除できることが読み取れる文言にする。
	if !strings.Contains(out, "Resume") {
		t.Errorf("output does not offer to resume: %q", out)
	}
}

func TestRenderShowsPrompt(t *testing.T) {
	out := Render(theme(), false, "Press d again to delete", 80)

	if !strings.Contains(out, "Press d again to delete") {
		t.Errorf("output does not contain the prompt: %q", out)
	}
}
