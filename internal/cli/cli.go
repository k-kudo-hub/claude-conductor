// Package cli は conductor のサブコマンドを振り分ける。
//
// 各ペイン（dashboard / waiting / done / news / new-task / task-bar）は
// このパッケージにサブコマンドとして登録され、Zellij のレイアウトから
// それぞれ独立したプロセスとして起動される。
package cli

import (
	"fmt"
	"io"
	"sort"

	"github.com/k-kudo-hub/claude-conductor/internal/pane/news"
	"github.com/k-kudo-hub/claude-conductor/internal/pane/waiting"
)

// Version はビルド時に -ldflags で埋める。埋めずにビルドした場合は dev。
//
//	go build -ldflags "-X github.com/k-kudo-hub/claude-conductor/internal/cli.Version=v1.2.3"
var Version = "dev"

// subcommand は 1 つのサブコマンドの実装。
type subcommand struct {
	// summary は help に並べる 1 行説明。
	summary string
	// run は引数（サブコマンド名を除く）を受け取り終了コードを返す。
	run func(args []string, stdout, stderr io.Writer) int
}

// subcommands は登録済みのサブコマンド。ペインを移行するたびにここへ追加する。
var subcommands = map[string]subcommand{
	"news": {
		summary: "render the AI Tech News pane",
		run:     news.Run,
	},
	"waiting": {
		summary: "render the Waiting pane",
		run:     waiting.Run,
	},
	"version": {
		summary: "print the conductor version",
		run: func(_ []string, stdout, _ io.Writer) int {
			fmt.Fprintln(stdout, Version)
			return 0
		},
	},
}

// Run はサブコマンドを実行し、プロセスの終了コードを返す。
// 出力先を引数で受けるのはテストから検証できるようにするため。
func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "help", "-h", "--help":
		printUsage(stdout)
		return 0
	}

	cmd, ok := subcommands[args[0]]
	if !ok {
		fmt.Fprintf(stderr, "conductor: unknown subcommand %q\n\n", args[0])
		printUsage(stderr)
		return 2
	}

	return cmd.run(args[1:], stdout, stderr)
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: conductor <subcommand> [args]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "subcommands:")

	names := make([]string, 0, len(subcommands))
	for name := range subcommands {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		fmt.Fprintf(w, "  %-12s %s\n", name, subcommands[name].summary)
	}
}
