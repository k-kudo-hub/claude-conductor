package cli

import (
	"bytes"
	"strings"
	"testing"
)

func run(t *testing.T, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code = Run(args, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestVersionPrintsVersionToStdout(t *testing.T) {
	code, stdout, stderr := run(t, "version")

	if code != 0 {
		t.Errorf("exit code = %d, want 0 (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stdout, Version) {
		t.Errorf("stdout = %q, want it to contain %q", stdout, Version)
	}
}

// install.sh はバイナリの動作確認に `conductor version` を使う。改行以外の
// 余計な出力があると比較しづらいので、1 行に保つ。
func TestVersionOutputIsSingleLine(t *testing.T) {
	_, stdout, _ := run(t, "version")

	if got := strings.Count(strings.TrimSuffix(stdout, "\n"), "\n"); got != 0 {
		t.Errorf("stdout has %d extra newlines, want a single line: %q", got, stdout)
	}
}

func TestNoArgsPrintsUsageAndFails(t *testing.T) {
	code, _, stderr := run(t)

	if code == 0 {
		t.Error("exit code = 0, want non-zero when no subcommand is given")
	}
	if !strings.Contains(stderr, "usage") {
		t.Errorf("stderr = %q, want it to contain usage text", stderr)
	}
}

func TestUnknownSubcommandFails(t *testing.T) {
	code, _, stderr := run(t, "no-such-subcommand")

	if code == 0 {
		t.Error("exit code = 0, want non-zero for an unknown subcommand")
	}
	if !strings.Contains(stderr, "no-such-subcommand") {
		t.Errorf("stderr = %q, want it to name the unknown subcommand", stderr)
	}
}

func TestHelpGoesToStdoutAndSucceeds(t *testing.T) {
	for _, arg := range []string{"help", "-h", "--help"} {
		code, stdout, _ := run(t, arg)

		if code != 0 {
			t.Errorf("%s: exit code = %d, want 0", arg, code)
		}
		if !strings.Contains(stdout, "usage") {
			t.Errorf("%s: stdout = %q, want it to contain usage text", arg, stdout)
		}
	}
}

// usage には登録済みのサブコマンドがすべて並ぶこと。追加したのに
// help に出ないサブコマンドが生まれるのを防ぐ。
func TestUsageListsEverySubcommand(t *testing.T) {
	_, stdout, _ := run(t, "help")

	for name := range subcommands {
		if !strings.Contains(stdout, name) {
			t.Errorf("usage does not list subcommand %q:\n%s", name, stdout)
		}
	}
}
