package newtask

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

func theme() ui.Theme { return ui.Resolve(ui.DefaultThemeName) }

// 既定のタスク名はディレクトリ名と種別から作る。
func TestDefaultName(t *testing.T) {
	cases := []struct {
		dir      string
		taskType string
		want     string
	}{
		{"/home/user/myapp", "dev", "myapp-dev"},
		{"/home/user/myapp/", "dev", "myapp-dev"},
		{"/myapp", "review", "myapp-review"},
		{"myapp", "docs", "myapp-docs"},
	}

	for _, tc := range cases {
		if got := DefaultName(tc.dir, tc.taskType); got != tc.want {
			t.Errorf("DefaultName(%q, %q) = %q, want %q", tc.dir, tc.taskType, got, tc.want)
		}
	}
}

// 入力が空なら候補をそのまま採用する（Enter だけで確定できる）。
func TestResolveName(t *testing.T) {
	cases := []struct {
		def   string
		input string
		want  string
	}{
		{"myapp-dev", "", "myapp-dev"},
		{"myapp-dev", "custom", "custom"},
		{"myapp-dev", "  ", "myapp-dev"},
		{"myapp-dev", " spaced ", "spaced"},
	}

	for _, tc := range cases {
		if got := ResolveName(tc.def, tc.input); got != tc.want {
			t.Errorf("ResolveName(%q, %q) = %q, want %q", tc.def, tc.input, got, tc.want)
		}
	}
}

// タブ名が重なるとジャンプや削除の対象が曖昧になる。-2, -3... を付けて避ける。
func TestUniqueTabName(t *testing.T) {
	cases := []struct {
		name     string
		base     string
		existing []string
		want     string
	}{
		{"no conflict", "myapp-dev", []string{"other"}, "myapp-dev"},
		{"one conflict", "myapp-dev", []string{"myapp-dev"}, "myapp-dev-2"},
		{"two conflicts", "myapp-dev", []string{"myapp-dev", "myapp-dev-2"}, "myapp-dev-3"},
		{"gap is reused", "myapp-dev", []string{"myapp-dev", "myapp-dev-3"}, "myapp-dev-2"},
		{"no existing tabs", "myapp-dev", nil, "myapp-dev"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := UniqueTabName(tc.base, tc.existing); got != tc.want {
				t.Errorf("UniqueTabName(%q, %v) = %q, want %q", tc.base, tc.existing, got, tc.want)
			}
		})
	}
}

// タスク種別は「名前 + 説明」で選ばせる。選択結果から名前だけを取り出す。
func TestTaskTypeChoiceRoundTrip(t *testing.T) {
	choice := FormatChoice("dev", "Claude Code + LazyVim + lazygit")

	if !strings.Contains(choice, "dev") {
		t.Errorf("choice %q does not contain the name", choice)
	}
	if !strings.Contains(choice, "LazyVim") {
		t.Errorf("choice %q does not contain the description", choice)
	}
	if got := ParseChoice(choice); got != "dev" {
		t.Errorf("ParseChoice(%q) = %q, want dev", choice, got)
	}
}

func TestParseChoiceHandlesPlainAndEmpty(t *testing.T) {
	if got := ParseChoice("review"); got != "review" {
		t.Errorf("ParseChoice(\"review\") = %q, want review", got)
	}
	if got := ParseChoice(""); got != "" {
		t.Errorf("ParseChoice(\"\") = %q, want empty", got)
	}
	if got := ParseChoice("   dev   extra  "); got != "dev" {
		t.Errorf("ParseChoice with padding = %q, want dev", got)
	}
}

func TestRenderEveryLineHasExactWidth(t *testing.T) {
	cases := []struct {
		name   string
		status string
		width  int
	}{
		{"idle", "", 44},
		{"status", "Creating dev task 'myapp-dev'...", 44},
		{"long status", strings.Repeat("very long status ", 20), 44},
		{"narrow", "", ui.MinBoxWidth},
		{"wide", "", 120},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := Render(theme(), "my-session", tc.status, tc.width)
			want := max(tc.width, ui.MinBoxWidth)
			for i, line := range strings.Split(out, "\n") {
				if got := lipgloss.Width(line); got != want {
					t.Errorf("line %d width = %d, want %d\nline: %q", i, got, want, line)
				}
			}
		})
	}
}

func TestRenderShowsTitleSessionAndHint(t *testing.T) {
	out := Render(theme(), "my-session", "", 60)

	for _, want := range []string{Title, "my-session", "[n]"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q:\n%s", want, out)
		}
	}
}

func TestRenderShowsStatus(t *testing.T) {
	out := Render(theme(), "s", "Creating task...", 60)

	if !strings.Contains(out, "Creating task...") {
		t.Errorf("output does not contain the status:\n%s", out)
	}
}
