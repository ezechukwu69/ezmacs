# ez-agents

Run several terminal coding agents (Claude Code, Codex, Cursor CLI, Gemini CLI)
in [Ghostel](https://github.com/dakra/ghostel) terminals and watch them from a
sidebar: **project → session → sub-agents**, with live status.

```
 AGENTS   ⠋ 1  ◐ 1

 ▾  emacs.d                          2
 ▾ ⠋ ✱ Claude Code              working 2m
       ⠋ explore auth flow              41s
       ✓ run the tests                   9s
   ◐ ⬡ Codex                    waiting 6m
```

## Requirements

- Emacs 29.1+
- `ghostel` (terminal backend; others can be added, see `ez-agents-backend.el`)
- `magit-section` (the sidebar)
- optional: `nerd-icons`
- `git` 2.5+ (worktrees), and for persistence `tmux` 3.2+
- optional viewers: `delta`
- the agent CLIs you want on `PATH` (`claude`, `codex`, `cursor-agent`, `gemini`)
- `emacsclient` + a running server (`(server-start)`) for hook-based status

## Install

```elisp
;; Emacs 30+ from a git repo
(use-package ez-agents
  :vc (:url "https://github.com/YOU/ez-agents" :rev :newest)
  :commands (ez-agents-new ez-agents-sidebar-toggle ez-agents-goto-waiting
             ez-agents-switch ez-agents-install-hooks))

;; or copy this folder somewhere and:
(add-to-list 'load-path "/path/to/ez-agents")
(require 'ez-agents-ui)
```

Suggested keys:

```elisp
(keymap-global-set "C-c a l" #'ez-agents-sidebar-toggle)
(keymap-global-set "C-c a n" #'ez-agents-new)
(keymap-global-set "C-c a j" #'ez-agents-goto-waiting)
(keymap-global-set "C-c a s" #'ez-agents-switch)
```

## Use

| Command | What |
|---|---|
| `ez-agents-new` | start an agent in the current project (prefix: pick project) |
| `ez-agents-sidebar-toggle` | show/hide the sidebar |
| `ez-agents-goto-waiting` | jump to a session waiting for input |
| `ez-agents-dashboard` | full-window overview: status cards, every project, session output tails, sub-agents |
| `ez-agents-console` | separate buffer to talk to agents (prefix: pick target) |
| `ez-agents-new-worktree` | start an agent in a new git worktree |
| `ez-agents-review` | review the changes an agent made |
| `ez-agents-worktree-finish` | PR / merge / remove a worktree |
| `ez-agents-restore` / `ez-agents-resume` | bring back running agents / restart an ended one |
| `ez-agents-toggle-fullscreen` | give an agent's terminal the whole frame; run it again to restore the layout (`z` in the dashboard) |
| `ez-agents-resume-chat` | start an agent resuming an existing chat in a directory |
| `ez-agents-switch` | completing-read over all sessions |
| `ez-agents-install-hooks` / `-uninstall-hooks` | manage Claude Code status hooks |

Sidebar keys: `RET` jump, `TAB` fold, `c` new, `x` kill, `r` rename,
`s` send prompt, `w` jump to waiting, `g` refresh, `q` close.

### Dashboard and console

Dashboard keys (`?` shows them in Emacs):

| | |
|---|---|
| move | `n`/`p` session, `W` next waiting, `TAB` fold, `SPC` peek more output, mouse click on a row or a status card |
| mark | `m` mark, `u` unmark, `t` toggle, `M` mark all waiting, `U` clear |
| act (on marked, else at point) | `a` approve (Enter), `d` deny (Esc), `!` Ctrl-C, `S` send prompt, `K` kill |
| single | `x` kill, `r` rename, `c` new, `RET` jump to terminal, `w` first waiting |
| filter | `f` by status (or click a card), `/` by text, `C` clear |
| console | `i` on the marked set, else the agent or project at point; `b` broadcast |

The console shows a live preview of its **target** (one session, a project, all agents
waiting for input, or everyone) above a prompt. `RET` sends the prompt to every agent in the
target (asking for confirmation when more than one), `M-RET` inserts a newline,
`C-c C-t` changes target, `C-c C-r` sends a raw key (enter, escape, ctrl-c, arrows, y/n,
1-3: use it to answer permission prompts), `C-c C-k` sends Ctrl-C, `C-c C-j` jumps to the
terminal, `M-p`/`M-n` walk prompt history.

## Resuming an existing chat

Agents keep their chats on disk per directory. Starting an agent where chats already exist
(`ez-agents-new`, `c` in the dashboard) first asks: **New chat**, **Continue most recent**, or an older
one, listed newest first with their age and title (`ez-agents-resume-prompt`: `ask`, `latest` to always
continue the most recent, `never` for a blank chat every time).

`ez-agents-resume-chat` (`SPC a r`, `h` in the dashboard) goes straight to the list for this project, or
for the directory at point; with a prefix argument it asks for the directory.

| Agent | Where chats are read from | Resumes with |
|---|---|---|
| Claude Code | `~/.claude/projects/<dir>/*.jsonl` (honours `CLAUDE_CONFIG_DIR`) | `claude --resume <id>` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl`, matched by working directory (honours `CODEX_HOME`) | `codex resume <id>` |
| Cursor, Gemini | not listable | `cursor-agent resume`, `gemini --resume latest` (only on request, never prompted) |

History files are only read, never changed. Chats are per directory, so a fresh git worktree starts with none.
Claude sessions report their conversation id through the hooks, so restarting an ended agent
(`ez-agents-resume`, `Z`) goes back to that exact chat instead of "the latest".

## Agents that survive Emacs closing

By default (`ez-agents-persistence`) every agent runs in a detached **tmux** session on a private
socket (`tmux -L ez-agents`, with its own config: no prefix key, no status bar). Ghostel just attaches
to it, so quitting Emacs or killing the terminal buffer only *detaches*; the agent keeps working.

- After a restart, `ez-agents-restore` (run automatically a couple of seconds after startup in this
  config) rebuilds the sessions from `<data dir>/ez-agents/sessions.eld`. Agents still running show as
  *detached*; `RET` on one reattaches. Their latest output is read with `tmux capture-pane`.
- `ez-agents-kill` kills the tmux session; closing the buffer by hand does not.
- Restore also **adopts** running `ez-*` agent sessions that have no record (Emacs ended before saving,
  or the state file was lost), so a running agent is never out of reach.
- If a terminal's `tmux attach` client dies while its agent keeps running, the dead buffer is kept (it shows
  tmux's last output), a message gives the exit reason, and `RET` on the agent reattaches.
- An agent that really ended shows as done. `ez-agents-resume` (`Z` in the dashboard) restarts it with
  the agent's own resume command (`claude --continue`, `codex resume --last`): the conversation
  continues, work that was in flight is lost.
- Set `ez-agents-persistence` to nil (or `ez-agents-backend` to `ghostel`) to run agents directly under
  Ghostel, where they die with Emacs.
- Status hooks after a restart reach the new Emacs through the same `emacsclient` socket.

## Branches and worktrees

`ez-agents-new` in a git repository asks where the agent runs (`ez-agents-spawn-mode`): **in place**,
a **new worktree**, or an **existing worktree**. `ez-agents-new-worktree` (`B` in the dashboard) skips the
question.

- New worktrees go **outside the repo**, in `ez-agents-worktree-root` (default `~/.emacs-worktrees`):
  `~/.emacs-worktrees/<repo>/<branch-slug>`, on a branch `agent/<kind>/<task>` created from the base you pick.
- Sessions stay grouped under the original project and show their branch (`⎇`).
- `ez-agents-worktree-copy-files` copies files such as `.env` into new worktrees and
  `ez-agents-worktree-post-create` runs a command (e.g. `npm install`); both are off by default.
- `ez-agents-worktree-finish` (`P`): open a PR with `gh`, merge into the repo's current branch, remove the
  worktree, or remove it and delete the branch. **Nothing is deleted automatically**; removal refuses to
  discard uncommitted work or an unmerged branch without an explicit extra confirmation. Killing a
  session leaves its worktree in place.

## Reviewing what an agent changed

`ez-agents-review` (`R` in the dashboard) lists every file the agent changed since its **base commit**
(the commit it started from; committed, uncommitted and untracked work all count) with the hunks
expanded. Your index and the agent's tree are never touched.

| Key | |
|---|---|
| `RET` | open the file at that line |
| `m` / `u` | mark the file reviewed / not (the mark is void if the agent changes the file again) |
| `;` / `k` | add a note to the line or file at point / delete it |
| `F` | send all notes to the agent as one prompt (confirmation first), then clear them |
| `A` / `X` | approve / request changes (new changes void an approval) |
| `v` | open the file in `ez-agents-review-viewer` (`magit`, `ediff`, `delta` or `eshell`) |
| `d` `e` `D` `$` | magit diff against the base / ediff / `git diff \| delta` in Ghostel / eshell |
| `E` | ediff every unreviewed file in turn, offering to mark each reviewed |
| `S` | magit-status in the agent's checkout (stage, commit) |

Ediff opens the base on the left and the working tree on the right, **read-only** (the agent may still be
writing; `C-x C-q` makes it editable), in plain same-frame windows. The dashboard shows each agent's
diffstat, has a *Review* card and a `needs-review` filter, and a session whose changes are unapproved
counts toward it.

### Dashboard as a sidebar, chat on the right

Opening a chat from the dashboard (`RET` on an agent, or `c` to start one) turns the frame into the
**dashboard as a narrow sidebar on the left** (`ez-agents-workspace-width`, 44 columns) with the **agent's
chat filling the right**. The list switches to a compact form (status counts, one line per agent, branch
and diffstat underneath, the open chat marked `▶`) and keeps updating live. Picking another agent in
the sidebar swaps the chat. `l` expands the sidebar back to the full dashboard (and again to return);
`q` closes the layout and restores the windows from before it. `ez-agents-workspace-trigger` controls
when this happens: `dashboard` (default), `always` (also when you start or jump to an agent from any
buffer) or `never`.

### Fullscreen

`ez-agents-toggle-fullscreen` saves the window layout, closes every other window (the sidebar and
other side windows included) and shows only the agent's terminal; calling it again puts the saved layout
back. It works on the agent in the current buffer, or on the one at point in the dashboard (`z`), or asks.
In this config it is `C-M-z` (also works inside Ghostel) and `SPC a z`. Set `ez-agents-fullscreen-frame`
to also make the whole frame fullscreen while zoomed.

## How status works (strongest first)

1. **Hooks (Claude Code).** On first launch in a project you are asked to write
   `.claude/settings.local.json` (project-local, normally git-ignored). The hooks run
   `ez-agents-hook.sh`, which reports to Emacs through `emacsclient`. This gives
   accurate *working / waiting / idle* and **sub-agents** (Task/Agent tool calls).
   The script does nothing outside sessions started by ez-agents.
   Set `ez-agents-install-hooks-policy` to `always` or `never` to skip the prompt.
2. **Process tree.** Agent binaries running under a session show up as sub-agents.
3. **Terminal activity.** Output in the last 1.5 s means *working*.

Codex, Cursor and Gemini have no hook integration here, so they use 2 and 3 only.

## Customize

- `ez-agents-definitions`: add or change agents (`:name :command :icon :hooks`).
- `ez-agents-notify-function`: called when a session starts waiting.
- `ez-agents-project-chooser`: a function returning the directory to start in, used when you start an
  agent from a buffer that is not inside a project (e.g. `*scratch*` in `~/`), so the directory is
  chosen at the moment you start the agent. Nil uses the current directory.
- `ez-agents-ui-width`, `ez-agents-ui-spinner`, faces `ez-agents-*`.
- `ez-agents-backend`: terminal backend (only `ghostel` is implemented; add
  `cl-defmethod`s for `ez-agents-backend-start/-send/-alive-p/-install-exit-hook`).

## Tests

```sh
emacs --batch -L . -L /path/to/magit-section -l test/ez-agents-test.el \
      -f ert-run-tests-batch-and-exit
```
