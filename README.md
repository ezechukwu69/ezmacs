# Emacs config — coding + notes

Layout: `init.el` requires one main file per category in `lisp/<category>/my-<category>.el`,
which in turn requires each `my-<category>-<feature>.el` in that folder.

| Category | Contents |
|---|---|
| core | package.el/use-package, defaults, backups, PATH, performance, Emacs 31 built-ins |
| ui | doom theme, font, nerd-icons, modeline, highlights |
| keys | evil (+collection, surround, …), `SPC` leader (`my/leader`, `my/local-leader`) |
| editing | undo (vundo), pairs, avy/ace-window, whitespace, yasnippet |
| completion | vertico, orderless, marginalia, consult, embark, corfu, cape |
| workspace | project.el + tabspaces: one tab per project with isolated buffers; ibuffer scoped to the workspace; popups (popper) per workspace |
| lang | eglot, built-in tree-sitter, flymake + diagnostics (`SPC e`), apheleia, dape (debugging, `SPC d`), envrc, Dart (`dart-ts-mode`) + Flutter (`SPC m` in Dart buffers), language modes |
| vc | magit, diff-hl |
| org | `~/org`: core, agenda (stock layout; + grouped task view, org-timegrid week calendar), capture, babel, modern look, evil-org, roam |
| ai | agent-shell |
| tools | which-key, helpful, dired, Ghostel terminal (libghostty), server |

## Adding a plugin
1. Create `lisp/<category>/my-<category>-<name>.el` ending in `(provide 'my-<category>-<name>)`.
2. Add `my-<category>-<name>` to the `(mapc #'require '(...))` list in `lisp/<category>/my-<category>.el`.

New category: create `lisp/<cat>/my-<cat>.el`, then add `my-<cat>` to the list in `init.el`.
Bind keys with `(my/leader "xy" '(command :wk "label"))`.

## First run
- `M-x nerd-icons-install-fonts`
- `npm i -g @agentclientprotocol/claude-agent-acp` (Claude Code via agent-shell)
- Language servers are your own to install (eglot starts them when found).
- `SPC c G` installs all tree-sitter grammars (needs a C compiler and network); otherwise Emacs offers to install each when you open that language.

## Workspaces (`SPC TAB`, `SPC p p`)
`SPC p p` opens a project in its own tab; `SPC b b` lists only that tab's buffers
(narrow with `b ` for all). `M-1…9` jump to workspace N. `SPC p D` registers repos under `~/development`.

See [MAINTAINING.md](MAINTAINING.md) for conventions, upgrades, debugging and known workarounds.

## lisp/ (Emacs 31 user lisp)
All code lives in `lisp/` — Emacs 31's `user-lisp-directory`. Emacs puts it and every subfolder on `load-path` itself, and
3 seconds after startup `my/prepare-lisp` byte-compiles/native-compiles changed files and collects `;;;###autoload` cookies into
`lisp/.user-lisp-autoloads.el`. Standalone libraries go in `lisp/custom-plugins/` (`ez-flutter.el` is there; see `lisp/lang/my-lang-flutter.el`).
Force a full rebuild with `C-u M-x my/prepare-lisp`.
