package paths

import (
	"path/filepath"
	"testing"
)

func TestHomeUsesConductorHomeWhenSet(t *testing.T) {
	t.Setenv("CONDUCTOR_HOME", "/custom/conductor")

	if got, want := Home(), "/custom/conductor"; got != want {
		t.Errorf("Home() = %q, want %q", got, want)
	}
}

// CONDUCTOR_HOME はテスト（mdev-test）などで差し替えられる。設定が無い
// ときだけ既定の ~/.claude-conductor に落ちる。
func TestHomeFallsBackToDotClaudeConductor(t *testing.T) {
	t.Setenv("CONDUCTOR_HOME", "")
	t.Setenv("HOME", "/home/tester")

	if got, want := Home(), "/home/tester/.claude-conductor"; got != want {
		t.Errorf("Home() = %q, want %q", got, want)
	}
}

func TestSubdirectories(t *testing.T) {
	t.Setenv("CONDUCTOR_HOME", "/ch")

	cases := []struct {
		name string
		got  string
		want string
	}{
		{"News", News(), "/ch/news"},
		{"Daily", Daily(), "/ch/daily"},
		{"Bin", Bin(), "/ch/bin"},
		{"Scripts", Scripts(), "/ch/scripts"},
	}

	for _, tc := range cases {
		if tc.got != tc.want {
			t.Errorf("%s() = %q, want %q", tc.name, tc.got, tc.want)
		}
	}
}

func TestScriptBuildsPath(t *testing.T) {
	t.Setenv("CONDUCTOR_HOME", "/ch")

	if got, want := Script("fetch-news.sh"), filepath.Join("/ch", "scripts", "fetch-news.sh"); got != want {
		t.Errorf("Script(\"fetch-news.sh\") = %q, want %q", got, want)
	}
}
