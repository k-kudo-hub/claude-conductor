# Claude Conductor

Orchestrate multiple Claude Code sessions with an interactive dashboard in [Zellij](https://zellij.dev/).

```
┌─ Main ───────────────────────────────────────────┐
│  Current Tasks [session-name]                    │
│                                                  │
│  [1] ■ api-feature [18:05:31]                    │
│      Claude needs your permission to use Bash    │
│                                                  │
│  Pending: 1  [num]: jump / d+[num]: delete       │
├──────────────────────────────────────────────────┤
│  Waiting [external]                              │
│  ■ review-pr42 [18:06:45]                        │
│      Waiting for external response               │
│  Waiting: 1                                      │
├──────────────────────────────────────────────────┤
│  New Task [session-name]                         │
│  [n] Create task                                 │
└──────────────────────────────────────────────────┘
```

## Features

- **Dashboard** — Real-time view of all Claude Code sessions. Jump to a tab by pressing its number. Delete a tab with `d` + number.
- **Waiting pane** — Tasks blocked on an external response (e.g. PR review) can be moved to a separate Waiting pane so they don't crowd the Dashboard. They're excluded from the Dashboard's pending count.
- **Task tabs** — Each task runs Claude Code with a small control bar (`m`: go to Main, `w`: toggle Waiting, `dd`: delete tab).
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
```

### Create tasks (in the dashboard)

Press `n` in the bottom pane to start the task creation flow:

1. Select a working directory (fzf, searches `~/projects` and `~/works`)
2. Select a task type (dev, review, docs, survey, k8s)
3. Confirm the task name — a default of `{directory-name}-{type}` is pre-filled, so just press Enter to accept, or edit it inline

If the resulting name collides with an existing tab, a numeric suffix (`-2`, `-3`, …) is appended to keep tab names unique.

Set `"skip_task_name_input": true` in `~/.claude-conductor/config.json` to skip step 3 entirely and use the default name automatically.

### Dashboard controls

| Key | Action |
|-----|--------|
| `1`–`9` | Jump to pending tab |
| `d` + `1`–`9` | Delete a task tab |

### Task tab controls

| Key | Action |
|-----|--------|
| `m` | Go to Main tab |
| `w` | Toggle Waiting (move to / from the Waiting pane) |
| `dd` | Delete this tab |

## How it works

```
Claude Code (task tab)
  ├─ Notification hook  → creates pending file → dashboard shows it
  ├─ Stop hook          → creates pending file → dashboard shows it
  ├─ PostToolUse hook   → clears Notification pending → auto-return to Main
  └─ UserPromptSubmit   → clears pending → auto-return to Main

Task tab control bar
  └─ w key → waiting-toggle.sh flips event between Waiting and Notification

Dashboard (Main tab)
  ├─ Reads ~/.claude-pending/{session}/*.json every 2 seconds
  ├─ Dashboard pane → shows pending tasks, excludes Waiting
  └─ Waiting pane   → shows only Waiting tasks
```

A task's state lives in its pending file's `event` field: `Notification`
(needs your attention), `Stop` (done), or `Waiting` (blocked on an external
response). Pressing `w` in a task tab toggles between `Waiting` and
`Notification`. Waiting is also cleared automatically when you send Claude your
next prompt (via the UserPromptSubmit hook).

Pending files are stored per Zellij session at `~/.claude-pending/{session_name}/`, keyed by Claude Code's `session_id`.

## Uninstall

```bash
cd claude-conductor
./uninstall.sh
```

## License

MIT
