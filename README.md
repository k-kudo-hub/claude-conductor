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
- **Done pane** — Today's completed tasks. Restore one back to the dashboard with `r` + number, resuming its previous Claude Code conversation, to keep working on it.
- **Waiting pane** — Tasks blocked on an external response (e.g. PR review) can be moved to a separate Waiting pane so they don't crowd the Dashboard. They're excluded from the Dashboard's pending count.
- **Task tabs** — Each task runs Claude Code with a small control bar (`m`: go to Main, `w`: toggle Waiting, `dd`: delete tab).
- **Auto-routing** — When you respond to Claude, you're automatically returned to the dashboard. Permission approvals also auto-return.
- **Hooks integration** — Notification, Stop, PostToolUse, and UserPromptSubmit hooks keep the dashboard in sync.
- **Work log upload** (optional) — On tab deletion, push a summary + conversation log to a dedicated Git repo. Disabled by default; see [Uploading work logs](#uploading-work-logs-optional).

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
4. Record the installed version and update source (`~/.claude-conductor/VERSION`, `REPO_URL`)

## Updating

```bash
mdev update
```

`mdev update` downloads the latest release, extracts it, and re-runs `install.sh`
(your `config.json` is preserved). It follows the same approach as Claude Code's
native updater — it fetches the release archive rather than pulling git, so the
install directory does not need to be a git checkout.

When you start a session, `mdev` also checks once a day whether a newer release is
available and prints a short notice if so. The check is best-effort: it is cached
for the day, times out quickly, and stays silent on any network failure so it never
delays startup. Disable it by setting `update_check.enabled` to `false` in
`~/.claude-conductor/config.json`.

## Usage

### Start a session

```bash
mdev              # Multi-task dashboard session
dev               # Single dev session (Claude + Neovim + lazygit)
```

### Test a worktree in isolation

When developing Conductor itself across parallel worktrees, launch a throwaway
test session **in a new terminal window** without overwriting your installed
`~/.claude-conductor/`:

```bash
mdev-test <worktree-path>   # absolute or relative path to a worktree
mdev-test <branch-name>     # resolved under <repo>/.worktree/<name>
mdev-test                   # pick from .worktree/ with fzf
```

`mdev-test` points `CONDUCTOR_HOME` at the worktree, so its `scripts/`,
`layouts/`, and hook **scripts** run from the worktree copy. The session is
named `test-<worktree>` to keep its pending/daily data separate from your real
sessions. Re-running replaces any existing session of that name with a fresh one.

How the window opens depends on your terminal:

- **Warp** — a native new tab via a temporary Launch Configuration (opens in the
  worktree with the session auto-starting; no separate app).
- **iTerm** — a new window via iTerm's scripting API.
- **anything else** — a new Terminal.app window (via an opened `.command`).

> **Note:** Changes to `hooks.json`'s *structure* (adding events or swapping
> commands) are **not** covered by `mdev-test`, because hooks live in the global
> `~/.claude/settings.json`. Only changes to the hook *scripts* are reflected.
>
> **Note:** A worktree only gets *full* pane isolation once its `layouts/multi.kdl`
> references `${CONDUCTOR_HOME}` (this feature and later). For older worktrees whose
> layout hardcodes `~/.claude-conductor`, the Main-tab panes run the **installed**
> scripts — `mdev-test` prints a warning in that case. Data and hook scripts are
> still isolated via `CONDUCTOR_HOME`.

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

### Done pane controls

The Done pane lists today's completed tasks. Restore one back to the dashboard to keep working on it.

| Key | Action |
|-----|--------|
| `r` + `1`–`9` | Restore a Done task (recreates its Claude Code tab) |

A restored task is recreated in its original directory and task type, resuming its previous Claude Code conversation (`claude --resume`) when the session is still available — otherwise a fresh session starts. Once the tab is recreated, its daily-log entry is marked `restored` so it no longer appears in the Done pane. If the original directory no longer exists (e.g. the worktree was removed), the task stays in the Done pane instead of being lost.

## Using a different agent CLI (optional)

By default, task tabs and the `dev` session launch `claude`. Set `agent.command` in
`~/.claude-conductor/config.json` to launch any other CLI instead (e.g. Codex):

```json
{
  "agent": {
    "command": "codex",
    "resume_args": "resume"
  }
}
```

| Key | Description |
|-----|-------------|
| `command` | Command used to launch the agent (default `claude`). The string is word-split, so wrapper invocations like `"fdev secrets exec my-header -- claude"` work |
| `resume_args` | Argument(s) inserted between the command and the session id when restoring a Done task (default `--resume`, i.e. `claude --resume <id>`; Codex uses `resume`) |

> **Note:** The dashboard's pending/waiting states, Done-task restore, and cost
> tracking are driven by Claude Code's hooks (`session_id`, transcript, etc.).
> With a non-Claude agent the tabs and layouts still work, but those
> hook-driven features stay inactive.

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

## Uploading work logs (optional)

When a task tab is deleted (`dd` / `d`+number), the work log can be uploaded to a
dedicated Git repository so it can be shared and reviewed later. This is **disabled
by default**.

Enable it in `~/.claude-conductor/config.json`:

```json
{
  "upload": {
    "enabled": true,
    "repo": "your-name/work-logs",
    "base_dir": "work-log",
    "branch": "main"
  }
}
```

| Key | Description |
|-----|-------------|
| `enabled` | Turn uploading on/off (default `false`) |
| `repo` | Target repository. `owner/name` (cloned over SSH) or a full Git URL |
| `base_dir` | First-level directory inside the repo (default `work-log`) |
| `branch` | Branch to commit to (default `main`) |

The log is stored at `{base_dir}/YYYY/MM/DD/{TIMESTAMP}_{taskname}.md` and contains
the session summary (turns, tool calls, cost, markers) plus a conversation summary
generated by the `claude` CLI.

Notes:

- Upload runs **synchronously**. If the summary generation or `git push` fails, the
  tab is **not** deleted so the log is never lost — retry the `dd`.
- Known secret patterns (Anthropic / OpenAI / GitHub / AWS / Slack tokens, `Bearer`
  tokens) are masked before upload. Detection is best-effort and **not guaranteed** —
  do not enable uploading if the conversation may contain credentials that must never
  leave your machine.
- You need push access to `repo`, and `git` / `claude` available on your `PATH`.

## Releasing

Versioning is driven by pull request labels. Every PR **must** carry one of the bump
labels below, and the version is tagged automatically on merge. If more than one is
present, the highest bump wins (`major` > `minor` > `patch`).

- `bump:patch` — backwards-compatible fixes (`v1.2.3` → `v1.2.4`)
- `bump:minor` — backwards-compatible features (`v1.2.3` → `v1.3.0`)
- `bump:major` — breaking changes (`v1.2.3` → `v2.0.0`)

Workflow:

1. Open a PR and add one `bump:*` label. The **Bump label check** workflow fails the PR
   until a label is present (`.github/workflows/bump-label-check.yml`).
2. On merge to `main`, the **Tag on merge** workflow computes the next version with
   `scripts/bump-version.sh`, pushes the tag, and creates a GitHub Release
   (`.github/workflows/tag.yml`).
3. The base version when no tag exists yet is `v0.0.0`, so the first `bump:minor` merge
   produces `v0.1.0`.

`install.sh` records the installed version (from the nearest git tag) into
`~/.claude-conductor/VERSION`.

The bump labels are created once with:

```bash
gh label create bump:major --color B60205 --description "Breaking change (x.0.0)"
gh label create bump:minor --color FBCA04 --description "New feature (0.x.0)"
gh label create bump:patch --color 0E8A16 --description "Bug fix (0.0.x)"
```

## Uninstall

```bash
cd claude-conductor
./uninstall.sh
```

## License

MIT
