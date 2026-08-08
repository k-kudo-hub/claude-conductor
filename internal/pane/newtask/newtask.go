// Package newtask は New Task ペインを描画し、タスク作成の流れを進める。
//
// ディレクトリ・タスク種別・エージェントの選択は fzf に任せ、タスク名だけ
// このペインで受け取る。作成そのものは task-lib.sh の create_task が行う。
package newtask

import (
	"path/filepath"
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/k-kudo-hub/claude-conductor/internal/ui"
)

// Title は枠に表示する見出し。
const Title = "New Task"

// DefaultName はディレクトリ名と種別から既定のタスク名を作る。
//
//	/home/user/myapp, dev -> myapp-dev
func DefaultName(dir, taskType string) string {
	return filepath.Base(filepath.Clean(dir)) + "-" + taskType
}

// ResolveName は入力を確定する。空なら候補をそのまま採用する。
func ResolveName(def, input string) string {
	if s := strings.TrimSpace(input); s != "" {
		return s
	}
	return def
}

// UniqueTabName は既存のタブ名と重ならない名前を返す。重なる場合は
// -2, -3... を付ける。同名タブがあるとジャンプや削除の対象が曖昧になる。
func UniqueTabName(base string, existing []string) string {
	taken := make(map[string]bool, len(existing))
	for _, e := range existing {
		taken[e] = true
	}

	candidate := base
	for n := 2; taken[candidate]; n++ {
		candidate = base + "-" + strconv.Itoa(n)
	}
	return candidate
}

// FormatChoice は fzf に並べる 1 行を作る。名前のあとに説明を添える。
func FormatChoice(name, description string) string {
	if description == "" {
		return name
	}
	return name + "  " + description
}

// ParseChoice は fzf が返した行から名前だけを取り出す。
func ParseChoice(line string) string {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// Render は待機中の案内を描く。status が空でなければ、その進行状況を出す。
func Render(th ui.Theme, session, status string, width, height int) string {
	w := max(width, 1)
	inner := w

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	accent := lipgloss.NewStyle().Foreground(th.Accent)

	line := accent.Render("[n]") + " " + muted.Render("Create task")
	if status != "" {
		line = lipgloss.NewStyle().Foreground(th.Text).Render(ui.Pad(status, inner))
	}

	_ = muted
	return ui.Screen(append(ui.Header(th, Title, session, w), line), w, height)
}

// renderNameInput はタスク名の入力欄を描く。field は textinput が描いた
// 行で、そのまま埋め込む（内部にカーソル位置の情報を含むため加工しない）。
func renderNameInput(th ui.Theme, field string, width, height int) string {
	w := max(width, 1)
	inner := w

	muted := lipgloss.NewStyle().Foreground(th.Muted)
	label := lipgloss.NewStyle().Foreground(th.Accent).Bold(true)

	body := []string{
		label.Render("Task name"),
		field,
		"",
		muted.Render(ui.SpaceBetween("enter: create", "esc: cancel", inner)),
	}
	return ui.Box(th, Title, body, w)
}
