# Emacs config — coding + notes

Layout: modules are `lisp/<category>/my-<category>-<module>.el`. Which ones load, and in what
order, is declared in `modules.el` (a Doom-style `(my! :ui theme font ... :lang eglot (format +onsave) ...)`
block). Personal overrides go in `config.el`, which loads after every module. `M-x my-modules-report`
shows what loaded and how long each module took.

| Category | Contents |
|---|---|
| core | package.el/use-package, defaults, backups, PATH, performance, Emacs 31 built-ins |
| ui | doom theme, font, nerd-icons, modeline, highlights |
| keys | evil (+collection, surround, …), `SPC` leader (`my/leader`, `my/local-leader`) |
| editing | undo (vundo), pairs, avy/ace-window, whitespace, yasnippet, multiple cursors (evil-multiedit + evil-mc) |
| completion | vertico, orderless, marginalia, consult, embark, corfu, cape |
| workspace | project.el + tabspaces: one tab per project with isolated buffers; ibuffer scoped to the workspace; popups (popper) per workspace |
| lang | eglot, built-in tree-sitter, flymake + diagnostics (`SPC e`), apheleia, dape (debugging, `SPC d`), envrc, Dart (`dart-ts-mode`) + Flutter (`SPC m` in Dart buffers), language modes |
| vc | magit, diff-hl |
| org | `~/org`: core, agenda (stock layout; + grouped task view, org-timegrid week calendar), capture, babel, modern look, evil-org, roam |
| ai | agent-shell |
| tools | which-key, helpful, dired, Ghostel terminal (libghostty), server, YouTube/music (empv), start-up dashboard (ez-dashboard) |

## Adding a plugin
1. Create `lisp/<category>/my-<category>-<name>.el` ending in `(provide 'my-<category>-<name>)`.
2. List `<name>` under `:<category>` in `modules.el`.

Disable a module: comment it out in `modules.el`. Flags: `(name +flag)` in `modules.el`, read with
`(my-module-flag-p :category 'name '+flag)`; `(my-module-p :category 'name)` asks whether a module is on.
New category: add a `:<cat>` keyword in `modules.el` and a `lisp/<cat>/` directory.
Bind keys with `(my/leader "xy" '(command :wk "label"))`.

## First run
- Install the external programs: see **[INSTALL.md](INSTALL.md)** (every binary the config uses, what needs it, the install command, and a check script).
- `M-x nerd-icons-install-fonts`
- `npm i -g @agentclientprotocol/claude-agent-acp` (Claude Code via agent-shell)
- Language servers are your own to install (eglot starts them when found).
- `SPC c G` installs all tree-sitter grammars (needs a C compiler and network); otherwise Emacs offers to install each when you open that language.

## Multiple cursors (`editing/multiple-cursors`)
Two tools: **evil-multiedit** edits every occurrence of a word at once, **evil-mc** places real
independent cursors (every command runs at each). evil-mc's own `gr` prefix is disabled because
`gr` is the LSP prefix here (`grn` rename, `gra` code action); its commands live under `gz`.

| Keys | Action |
|---|---|
| `M-d` (normal) | select the word at point; press again to add the next occurrence |
| `M-d` (visual) | use the selection, then the next occurrence |
| `M-D` | the same, going backwards |
| `R` (visual) | select all occurrences of the selection |
| `C-M-d` | restore the last multiedit selection |
| in multiedit: `M-d`/`C-n`, `M-D`/`C-p`, `RET` | next, previous, skip this occurrence (with a region: restrict to it) |
| `gzd` / `gzD` | cursor here + jump to next / previous match of the word |
| `gzs` / `gzS` | skip this match, go to the next / previous |
| `gzj` / `gzk` | add a cursor and move down / up a line |
| `gzz` | add a cursor right here |
| `gzm` | cursors on all matches |
| `gzI` / `gzA` (visual) | a cursor at the start / end of every selected line |
| `gzp` / `gzr` | pause / resume the extra cursors |
| `gzu` / `gzq` | remove the last cursor / all cursors |

evil-collection's own `gz` ("go to the REPL": ielm in Elisp, the shell in Python, ...) would shadow
`gz` in those modes, so the REPL jump is on **`gZ`** instead (`lisp/keys/my-keys-evil.el`). Two modes keep
their own `gz` on purpose: magit-status (stashes) and the agent-shell viewport (refresh).

Typical use: put the point on a word, `M-d` until the occurrences you want are highlighted, then
change them (`c`, `i`, `a`, ...) and `ESC`. For a column: `gzj` down the lines, then `A`, `I`, `cw`,
`x`, ... as usual.

## Evil on or off (`SPC t e`, `C-c t e`)
The toggle is **remembered across sessions**: the last choice you made with it wins at the next start (it is saved with your
theme and font); until you have toggled, `my/evil-enabled` decides. Everything this config adds on top of Vim's own keys also
works with Evil **off**, on Emacs-style keys. One rule: **Evil's `g` prefix is `C-c g`** in Emacs mode, and the whole `SPC`
leader menu is `M-SPC`.

**Configuring a key for both worlds, once.** Every Evil key and its Emacs-mode key is in `lisp/keys/my-keys-table.el`, side by side, one line per command, using `my/bind` (`lisp/keys/my-keys-dsl.el`):

```elisp
(my/bind
  (xref-find-definitions :g "d" :doc "definition")          ; Evil gd + Emacs C-c g d
  (my/eldoc-show :evil "K" :emacs "C-c g k")                 ; different keys per world
  (evil-numbers/inc-at-pt :both "C-c +")                     ; same key in both
  (my/select-font :leader "t F" :doc "font"))                ; SPC t F / M-SPC t F
```

Options: `:g`, `:evil`, `:emacs`, `:both`, `:leader`, `:states` (default `(normal)`), `:evil-map` / `:emacs-map` with
`:after FEATURE` for lazily loaded maps, `:doc`. Leading option pairs are defaults for every entry. Two commands on one
key give a warning at load; `M-x my/bind-describe` shows the live table.

| Evil | Emacs mode | Does |
|---|---|---|
| `C-o` / `C-i` | `C-c o` / `C-c i` | back / forward through your **jump list**, the same list in both modes |
| `gd` `gD` | `C-c g d` `C-c g D` | definition (also `M-.`) / declaration |
| `gra` `grn` `grr` `gri` `grt` | `C-c g r a` `n` `r` `i` `t` | code actions / rename / references / implementation / type definition |
| `g0` `gO` | `C-c g 0` `C-c g O` | symbols of the buffer |
| `gs` `gl` | `C-c g s` `C-c g l` | avy: jump to a character / a line |
| `gc` | `C-c g c` | comment (also `M-;`) |
| `K` | `C-c g k` | docs at point in a window |
| `]e` `[e` | `C-c g e` `C-c g E` | next / previous error |
| `]h` `[h` | `C-c g h` `C-c g H` | next / previous changed hunk |
| `M-d` `R` (multiedit) | `C-c g m` | edit every occurrence of the symbol at once (iedit) |
| `C-c +` `C-c -` | `C-c +` `C-c -` | increment / decrement the number at point |
| `SPC …` | `M-SPC …` | the leader menu |

The jump list records where you were before the usual long moves: `M-.` `M-,` `M-?`, the LSP lookups, `C-s` and the other
searches, `M-<` `M->`, `goto-line`, imenu / consult / avy jumps, `next-error`, opening another file or buffer
(`M-x customize-variable RET my/jump-commands` for the full list). Like Vim it only records buffers that visit a file.
Emacs mode leaves `C-o` (`open-line`) and `C-i` (Tab) alone; `M-,` / `C-M-,` (xref back / forward) also work. Not available with Evil off: the `gz` multiple
cursors (they run on Evil's states) and the surround / text-object operators.

## Dashboard (`tools/dashboard`, plugin `custom-plugins/ez-dashboard`)
Emacs opens on a dashboard (any time: `SPC b h`). Top row: **startup time** (with GC count), **packages**
(installed / active), **config modules** (with failures flagged), **custom plugins**, the Emacs build, **agents**.
Below: your **agents** (counts, each agent's own usage limits with bars and reset times, running sessions),
**recent projects** (git branch, running agents, ★ the last one), **recent conversations** (Claude Code and Codex,
across projects), **recent files**, **what is running right now** (buffers, workspaces, LSP servers, processes),
and the **configuration** (modules per category, shortcuts to `modules.el`, the module report and `INSTALL.md`).

| Keys | Action |
|---|---|
| `RET` / click | open the item: a project (menu: open / start an agent / resume / worktree / terminal), resume a conversation, jump to an agent, open a file |
| `j` `k` / `TAB` | next / previous item, one section at a time |
| `a` `p` `c` `f` `s` `m` | jump to Agents, Projects, Conversations, Files, Right now, Configuration |
| `g` / `q` / `?` | refresh / close / help |

Settings (put them in `config.el`): `ez-dashboard-name` (the greeting, set there already),
`ez-dashboard-fetch-usage` (nil: never ask the agents for usage), `ez-dashboard-list-length`,
`ez-dashboard-chat-ignore-regexp` (conversations from temp directories are hidden by default),
`ez-dashboard-layout` (rows of sections; `cards` is the tile row). Add your own section with
`(ez-dashboard-define-section 'id "Title" icon #'fn "k")` where `fn` takes the width and returns lines, then
list `id` in the layout. Files named on the command line, or `my/start-in-last-project`, skip the dashboard.

## Modeline (`ui/modeline`, plugin `custom-plugins/ez-modeline`)
A quiet modeline with **one thin bar** between it and the buffer and nothing between its segments. Left: Evil
state tag, file icon and project-relative path (● unsaved, lock read-only), VC branch, selection, macro marker.
Right: process, other packages' entries (org-clock, time, battery ... via `mode-line-misc-info` and
`global-mode-string`), flymake counts, LSP, direnv, mode, line:column and percent. Unselected windows fade to grey;
when a window is narrow the least important right-hand segments drop first (`ez-modeline-priority`).

- **Where it sits:** `SPC t m` moves it between the **bottom** (the bar is its top edge) and the **top** (it becomes the
  header line, the bar is its bottom edge); the choice is remembered. In `config.el`: `(setopt ez-modeline-position 'top)`
  (`setopt`, not `setq`, so a modeline that is already showing moves).
- **Spacing:** `ez-modeline-padding` is the empty space above and below the text, in pixels each side (default **8**; the
  bar is taller by twice that). Tune it in `config.el` with `(setopt ez-modeline-padding 12)` (4 compact, 8 roomy, 12 airy,
  0 none); `setopt` updates a modeline that is already showing.
- **Options** (`M-x customize-group RET ez-modeline`): `ez-modeline-bar`, `ez-modeline-padding`, `ez-modeline-left` /
  `-right` (which segments, in order), `ez-modeline-icons`, `ez-modeline-manage-faces` (nil keeps your theme's faces),
  `ez-modeline-misc-exclude`.
- **Your own segment:** `(ez-modeline-define-segment agents "Agent count." (when (> n 0) (format "%d agents" n)))`, then add
  `agents` to `ez-modeline-right`.
- Buffers that set their own `mode-line-format` or `header-line-format` (agents UI, dashboard, review) keep it.

## Workspaces (`SPC TAB`, `SPC p p`)
`SPC p p` opens a project in its own tab; `SPC b b` lists only that tab's buffers
(narrow with `b ` for all). `M-1…9` jump to workspace N. `SPC p D` registers repos under `~/development`.

See [MAINTAINING.md](MAINTAINING.md) for conventions, upgrades, debugging and known workarounds.

## lisp/ (Emacs 31 user lisp)
All code lives in `lisp/` — Emacs 31's `user-lisp-directory`. Emacs puts it and every subfolder on `load-path` itself, and
3 seconds after startup `my/prepare-lisp` byte-compiles/native-compiles changed files and collects `;;;###autoload` cookies into
`lisp/.user-lisp-autoloads.el`. Standalone libraries go in `lisp/custom-plugins/` (`ez-flutter.el` is there; see `lisp/lang/my-lang-flutter.el`).
Force a full rebuild with `C-u M-x my/prepare-lisp`.
