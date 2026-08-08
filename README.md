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
- [Zellij](https://zellij.dev/) ≥ 0.40 (≥ 0.44 for screen-based agent state
  detection — codex approval waits on the dashboard need `zellij action
  list-panes`, added in 0.44)
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
2. Install the `conductor` binary to `~/.claude-conductor/bin/` (see below)
3. Merge hooks into `~/.claude/settings.json`
4. Add `source` line to `~/.zshrc` (with confirmation)
5. Record the installed version and update source (`~/.claude-conductor/VERSION`, `REPO_URL`)

### The conductor binary

The panes are rendered by `conductor`, a small Go program built with
[Bubble Tea](https://github.com/charmbracelet/bubbletea). The installer downloads
the release asset matching your platform (macOS/Linux × amd64/arm64), so a Go
toolchain is **not** required to install or update.

When the download fails — most commonly on a git checkout whose version has no
matching release yet — the installer falls back to building from source with a
locally installed Go. If neither path works, installation stops rather than
leaving a half-configured session behind.

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
mdev              # Multi-task dashboard session (attach-or-create)
dev               # Single dev session (Claude + Neovim + lazygit)
```

`mdev` is **attach-or-create**: the default session is named after the current
directory (no timestamp), so running `mdev` again from the same place always
brings you back to the same session instead of piling up new ones.

```bash
mdev              # attach to (or create) the <dir> session
mdev <name>       # attach to (or create) the named session
mdev --new        # force a fresh timestamped session (old behavior)
```

### Session persistence and restore

Two layers keep your tasks alive:

1. **Closing the terminal** — Zellij is client-server: the session and every
   task keep running detached. `mdev` (or `zs`) reattaches.
2. **Machine restart / dead session** — the session's processes are gone, but
   Conductor keeps a **task registry** (`$CONDUCTOR_HOME/tasks/<session>/`)
   that the Claude/Codex hooks update on every event. When `mdev` finds the
   session dead (`EXITED`), it rebuilds it from the layout, and the dashboard
   restores each registered task tab with the agent's own resume
   (`claude --resume <id>` / `codex resume <id>`), so conversations survive
   the reboot.

Restore is best-effort and automatic:

- a task whose working directory vanished (e.g. a removed worktree) is dropped
- a task whose transcript is gone restarts fresh instead of a broken `--resume`
- deleted tasks (`dd`) never come back — deletion clears their registry entries

> **Note:** a task that has emitted **no hook event yet** (created, but you
> never sent it a prompt and it never stopped) has no registry entry and is
> not restored.

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

## Agents: Claude Code and Codex

Task tabs can run either Claude Code or [Codex CLI](https://developers.openai.com/codex/cli).
The default config defines both under `agents` in `~/.claude-conductor/config.json`:

```json
{
  "agents": {
    "claude": { "command": "claude", "resume_args": "--resume", "detection": "hooks" },
    "codex":  {
      "command": "codex", "resume_args": "resume", "detection": "screen",
      "patterns": {
        "neutral": [],
        "blocked": ["Would you like to run the following command\\?", "..."],
        "working": [" to interrupt"]
      }
    }
  }
}
```

When two or more agents are configured, task creation asks which one to use
(fzf) after the task type; with a single entry it is picked automatically.
Tasks with different agents can coexist in one session. `command` is word-split,
so wrapper invocations like `"fdev secrets exec my-header -- claude"` work;
`resume_args` sits between the command and the session id when a Done task is
restored (`claude --resume <id>` / `codex resume <id>`).

Codex integration is wired at install time: `install.sh` registers
`codex-notify.sh` as `notify` in `~/.codex/config.toml` (user-global — codex
ignores project-local `notify`). The bridge converts each `agent-turn-complete`
event into the same pending file the Claude hooks write, so the Dashboard,
Waiting pane, Done pane (with turn/token/cost stats parsed from the codex
rollout), and restore all work for codex tasks. If `notify` is already set by
another tool, the installer leaves it untouched and prints how to chain the
bridge manually.

**Screen-based state detection** — codex has no lifecycle hooks, so its state
is detected from the screen instead (`"detection": "screen"`): every dashboard
poll snapshots the agent pane (`zellij action dump-screen`, no focus change)
and matches its bottom lines against the agent's `patterns`:

- A line matching `patterns.neutral` marks the screen as one the agent does not
  own (a full-screen viewer, a picker). The tab's state and pending entries are
  left exactly as they were — on such a screen the spinner is hidden (which
  would read as a false done) and scrolled-back log lines may quote approval
  prompts (which would read as a false approval). Empty by default. Anchor
  these patterns to the viewer's own chrome (a footer line, a scroll hint) and
  keep them tight: a pattern loose enough to match a normal screen removes that
  tab from the dashboard for as long as it matches, silently.
- A line matching `patterns.blocked` (a known approval prompt) surfaces the
  tab as `Notification` — approval waits show up on the dashboard just like
  Claude Code permission prompts. Approvals are never delayed: they appear on
  the first poll that sees them.
- A line matching `patterns.working` (default: the codex `esc to interrupt`
  spinner) clears the tab's pending entries — the turn is running again. When
  this is a transition from blocked/idle (you approved or submitted a prompt
  inside the tab), focus auto-returns to Main like the Claude Code hooks do,
  within one poll (up to 2 seconds).
- Anything else counts as idle. A screen that stops matching `working` becomes
  a `Stop` (done) entry, unless the `notify` bridge already recorded one.
  Unknown dialogs deliberately fall back to idle, never to blocked, so a new
  codex UI screen cannot spam the dashboard with false approvals.
- **done needs idle to hold.** The codex spinner disappears for a frame between
  tool calls, so a single idle observation is not a turn end. The first one
  parks the tab with a timestamp; a later poll confirms it once at least a
  second of real time has passed, or cancels it if the turn resumed. The clock
  is real time rather than a count of polls, because pressing keys on the
  dashboard can make polls fire back to back. Without this, a poll landing on
  that frame reports the task as done while it is still running.
- Flicker never moves you. A tab parked this way that resumes does **not** pull
  focus back to Main — nothing was shown to you, so there is nothing to return
  from. Auto-return still happens after an answered approval and after a prompt
  sent to a finished task.

**Codex limitations** — codex has no prompt-submit hook, so compared to
Claude Code tasks:

- Auto-return to Main and pending cleanup ride on screen detection instead of
  hooks: they happen on the next dashboard poll (up to 2 seconds) after the
  turn visibly resumes, not instantly. Like a claude permission prompt, a
  screen-detected approval stays listed until you actually answer it —
  jumping to the tab alone does not clear it. (Entries for agents with
  neither hooks nor screen detection are still cleared by the jump itself.)

The legacy single-agent form (`agent.command` / `agent.resume_args`) is still
honored when `agents` is absent.

## How it works

```
Claude Code (task tab)
  ├─ Notification hook  → creates pending file → dashboard shows it
  ├─ Stop hook          → creates pending file → dashboard shows it
  ├─ PostToolUse hook   → clears Notification pending → auto-return to Main
  └─ UserPromptSubmit   → clears pending → auto-return to Main

Codex (task tab)
  ├─ notify (agent-turn-complete) → codex-notify.sh → pending file (Stop)
  │  cleared when you jump to the tab from the dashboard
  └─ screen detection (dashboard poll) → dump-screen + pattern match
       viewer/picker  → nothing changes (neutral)
       approval prompt → pending file (Notification), no delay
       spinner        → clears the tab's pending files; auto-return to Main
                        when the user just answered (blocked/idle → working)
       turn end       → pending file (Stop) after two consecutive idle polls,
                        unless notify already wrote one

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

Separately from pending files (which exist only while a task waits for you),
the same hooks maintain the **task registry** at
`$CONDUCTOR_HOME/tasks/{session_name}/{session_id}.json` for every task tab's
whole lifetime. It records the tab, working directory, task type, agent, and
transcript path; `restore-session.sh` (run at dashboard startup) uses it to
rebuild task tabs with the agent's resume after the session dies, and task
deletion removes the entries. Only Conductor-created task tabs are registered —
the hooks skip Claude sessions running outside a task tab.

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
