// Package config は ~/.claude-conductor/config.json を読む。
//
// 書き込みは行わない。install.sh がユーザーの設定を保護しつつ既定値を
// 補完する役目を持っているため、ここでは読み取りに徹する。
package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/k-kudo-hub/claude-conductor/internal/paths"
)

// TaskType はタスクの種類。layout はタブ作成時にシェル側が解釈するので
// ここでは持たない。
type TaskType struct {
	Description string `json:"description"`
}

// Agent はエージェントの設定。
type Agent struct {
	Command    string `json:"command"`
	ResumeArgs string `json:"resume_args"`
	Detection  string `json:"detection"`
}

// Config は読み取る範囲の設定。
type Config struct {
	SearchDirs        []string            `json:"search_dirs"`
	SearchDepth       int                 `json:"search_depth"`
	SkipTaskNameInput bool                `json:"skip_task_name_input"`
	TaskTypes         map[string]TaskType `json:"task_types"`
	Agents            map[string]Agent    `json:"agents"`

	// 選択肢は設定ファイルに書かれた順で見せる。map は順序を保たないため、
	// 生の JSON からキーの並びを取っておく。
	taskTypeOrder []string
	agentOrder    []string
}

// Load は config.json を読む。まだ無い場合は config.default.json を読む
// （install.sh は初回だけ default をコピーし、以後ユーザーの設定を守る）。
func Load() (*Config, error) {
	home := paths.Home()

	path := filepath.Join(home, "config.json")
	data, err := os.ReadFile(path)
	if err != nil {
		path = filepath.Join(home, "config.default.json")
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("config not found under %s", home)
		}
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}

	cfg.taskTypeOrder = objectKeys(data, "task_types")
	cfg.agentOrder = objectKeys(data, "agents")

	return &cfg, nil
}

// TaskTypeNames はタスク種別を設定ファイルの並び順で返す。
func (c *Config) TaskTypeNames() []string { return c.taskTypeOrder }

// AgentNames はエージェント名を設定ファイルの並び順で返す。空の場合、
// タスクは従来どおり単一エージェント（.agent）の経路で作られる。
func (c *Config) AgentNames() []string { return c.agentOrder }

// Depth は fd に渡す探索の深さ。未設定なら 1。
func (c *Config) Depth() int {
	if c.SearchDepth <= 0 {
		return 1
	}
	return c.SearchDepth
}

// ExpandedSearchDirs は search_dirs の ~ を解いて返す。シェル側は展開を
// シェルに任せていたので、同じ結果になるようにする。
func (c *Config) ExpandedSearchDirs() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}

	dirs := make([]string, 0, len(c.SearchDirs))
	for _, d := range c.SearchDirs {
		switch {
		case d == "~":
			d = home
		case strings.HasPrefix(d, "~/"):
			d = filepath.Join(home, d[2:])
		}
		dirs = append(dirs, d)
	}
	return dirs
}

// objectKeys は JSON のトップレベルにある名前付きオブジェクトのキーを、
// 書かれた順で返す。encoding/json は map に入れた時点で順序を失うため、
// 生のトークン列から取り直す。
func objectKeys(data []byte, field string) []string {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil
	}
	obj, ok := raw[field]
	if !ok {
		return nil
	}

	dec := json.NewDecoder(bytes.NewReader(obj))
	// 開き波括弧。オブジェクトでなければキーは無い。
	tok, err := dec.Token()
	if err != nil {
		return nil
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil
	}

	var keys []string
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return keys
		}
		key, ok := tok.(string)
		if !ok {
			return keys
		}
		keys = append(keys, key)

		// 値は読み飛ばす。
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			return keys
		}
	}
	return keys
}
