// conductor は Claude Conductor のペインを描画するコマンド。
// Zellij のレイアウトから各ペインがサブコマンドとして起動される。
package main

import (
	"os"

	"github.com/k-kudo-hub/claude-conductor/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
