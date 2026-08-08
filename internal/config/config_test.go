package config

import (
	"os"
	"path/filepath"
	"testing"
)

const sample = `{
  "search_dirs": ["~/projects", "~/works"],
  "search_depth": 2,
  "skip_task_name_input": true,
  "agents": {
    "claude": {"command": "claude", "detection": "hooks"},
    "codex": {"command": "codex", "detection": "screen"}
  },
  "task_types": {
    "dev": {"description": "Claude Code + LazyVim + lazygit"},
    "review": {"description": "Claude Code only"},
    "k8s": {"description": "Claude Code + k9s"}
  }
}`

func writeConfig(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

func TestLoadReadsConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", sample)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if len(cfg.SearchDirs) != 2 || cfg.SearchDirs[0] != "~/projects" {
		t.Errorf("SearchDirs = %v", cfg.SearchDirs)
	}
	if cfg.SearchDepth != 2 {
		t.Errorf("SearchDepth = %d, want 2", cfg.SearchDepth)
	}
	if !cfg.SkipTaskNameInput {
		t.Error("SkipTaskNameInput = false, want true")
	}
}

// install.sh は config.json をユーザーのものとして保護するので、まだ
// 無い場合は config.default.json を読む（bash 版の load_config と同じ）。
func TestLoadFallsBackToDefaultConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.default.json", sample)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.SearchDepth != 2 {
		t.Errorf("SearchDepth = %d, want 2", cfg.SearchDepth)
	}
}

func TestLoadMissingConfigIsAnError(t *testing.T) {
	t.Setenv("CONDUCTOR_HOME", t.TempDir())

	if _, err := Load(); err == nil {
		t.Error("Load returned no error when no config exists")
	}
}

func TestLoadMalformedConfigIsAnError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", "{not json")

	if _, err := Load(); err == nil {
		t.Error("Load returned no error for a malformed config")
	}
}

// タスクタイプとエージェントは選択肢として並べるので、ユーザーが
// config.json に書いた順のまま出す。map の反復順やアルファベット順に
// なると、慣れた並びが実行のたびに変わってしまう。
func TestTaskTypeNamesKeepFileOrder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", sample)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	want := []string{"dev", "review", "k8s"}
	got := cfg.TaskTypeNames()
	if len(got) != len(want) {
		t.Fatalf("TaskTypeNames = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("TaskTypeNames[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestAgentNamesKeepFileOrder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", sample)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	want := []string{"claude", "codex"}
	got := cfg.AgentNames()
	if len(got) != len(want) {
		t.Fatalf("AgentNames = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("AgentNames[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestAgentNamesEmptyWhenUnset(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", `{"search_dirs":[],"task_types":{}}`)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := cfg.AgentNames(); len(got) != 0 {
		t.Errorf("AgentNames = %v, want empty", got)
	}
}

func TestTaskTypeDescription(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", sample)

	cfg, _ := Load()
	if got := cfg.TaskTypes["dev"].Description; got != "Claude Code + LazyVim + lazygit" {
		t.Errorf("Description = %q", got)
	}
}

// search_dirs の ~ はシェルが展開していた。Go 側でも同じように解く。
func TestExpandSearchDirs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	t.Setenv("HOME", "/home/tester")
	writeConfig(t, home, "config.json", `{"search_dirs":["~/projects","/abs/path","~"],"task_types":{}}`)

	cfg, _ := Load()
	got := cfg.ExpandedSearchDirs()
	want := []string{"/home/tester/projects", "/abs/path", "/home/tester"}

	if len(got) != len(want) {
		t.Fatalf("ExpandedSearchDirs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("dir %d = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestSearchDepthDefaultsToOne(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CONDUCTOR_HOME", home)
	writeConfig(t, home, "config.json", `{"search_dirs":[],"task_types":{}}`)

	cfg, _ := Load()
	if got := cfg.Depth(); got != 1 {
		t.Errorf("Depth() = %d, want 1", got)
	}
}
