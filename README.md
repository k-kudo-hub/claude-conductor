# Claude Conductor

Orchestrate multiple Claude Code sessions with an interactive dashboard in [Zellij](https://zellij.dev/).

```
┌─ Main (Dashboard) ──────────────────────────────┐
│  Claude Conductor [session-name]                 │
│                                                  │
│  [1] ■ api-feature [18:05:31]                    │
│      Claude needs your permission to use Bash    │
│                                                  │
│  [2] ■ review-pr42 [18:06:45] done               │
│      Code review completed                       │
│                                                  │
│  Pending: 2  [num]: jump / d+[num]: delete       │
├──────────────────────────────────────────────────┤
│  Control: $ task dev api  / $ task review pr42   │
└──────────────────────────────────────────────────┘
```

## Features

- **Dashboard** — Real-time view of all Claude Code sessions. Jump to a tab by pressing its number. Delete a tab with `d` + number.
- **Task tabs** — Each task runs Claude Code with a small control bar (`m`: go to Main, `dd`: delete tab).
- **Auto-routing** — When you respond to Claude, you're automatically returned to the dashboard. Permission approvals also auto-return.
- **Hooks integration** — Notification, Stop, PostToolUse, and UserPromptSubmit hooks keep the dashboard in sync.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [Zellij](https://zellij.dev/) ≥ 0.40
- [jq](https://jqlang.github.io/jq/)
- [fzf](https://github.com/junegunn/fzf)
- [terminal-notifier](https://github.com/julienXX/terminal-notifier) (macOS, optional)

## Install

```bash
git clone https://github.com/your-username/claude-conductor.git
cd claude-conductor
./install.sh
```

The installer will:

1. Copy scripts and layouts to `~/.claude-conductor/`
2. Merge hooks into `~/.claude/settings.json`
3. Add `source` line to `~/.zshrc` (with confirmation)

## Usage

### Start a session

```bash
mdev              # Multi-task dashboard session
dev               # Single dev session (Claude + Neovim + lazygit)
pdev              # Select a project directory, then start dev session
```

### Manage tasks (inside Zellij)

```bash
task dev api      # Add a "dev" task tab named "api"
task review pr42  # Add a "review" task tab named "pr42"
task docs guide   # Add a "docs" task tab named "guide"
task survey data  # Add a "survey" task tab named "data"
```

### Dashboard controls

| Key | Action |
|-----|--------|
| `1`–`9` | Jump to pending tab |
| `d` + `1`–`9` | Delete a task tab |

### Task tab controls

| Key | Action |
|-----|--------|
| `m` | Go to Main tab |
| `dd` | Delete this tab |

## How it works

```
Claude Code (task tab)
  ├─ Notification hook  → creates pending file → dashboard shows it
  ├─ Stop hook          → creates pending file → dashboard shows it
  ├─ PostToolUse hook   → clears Notification pending → auto-return to Main
  └─ UserPromptSubmit   → clears pending → auto-return to Main

Dashboard (Main tab)
  └─ Reads ~/.claude-pending/{session}/*.json every 2 seconds
```

Pending files are stored per Zellij session at `~/.claude-pending/{session_name}/`, keyed by Claude Code's `session_id`.

## Uninstall

```bash
cd claude-conductor
./uninstall.sh
```

## License

MIT
