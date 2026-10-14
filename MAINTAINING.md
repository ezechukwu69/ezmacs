# Maintaining this config

## Conventions
- One feature per file: `lisp/<cat>/my-<cat>-<feature>.el`, header `-*- lexical-binding: t; byte-compile-warnings: (not free-vars); -*-` (config files set variables of packages that aren't loaded yet, which makes the Flymake byte-compiler report false "free variable" warnings), ends with `(provide 'my-<cat>-<feature>)`.
- Each category's main file `my-<cat>.el` lists its features with `(require ...)`; `init.el` lists categories. Order matters (see below).
- Packages: `use-package` with `:ensure t` by default (`:ensure nil` for built-ins). Prefer `:custom`/`:config`; keep one package (and its keys) per file.
- Keys: `(my/leader "xy" '(command :wk "label"))` for global, `(my/local-leader :keymaps 'foo-mode-map ...)` for `SPC m`. Top-level `SPC` prefixes (labels only) are declared in `keys/my-keys-leader.el`; add a new prefix there first.
- Prefix files `my-` so nothing shadows built-ins (`org-agenda`, `eglot`, ...). Never name a file the same as a package feature.
- User/machine-specific settings go through `M-x customize` into `~/.local/share/emacs-ez/custom.el`, not into modules.

## Load order dependencies
`core` (package setup) → `ui` → `keys` (provides `my/leader`, `general`) → `editing` → `completion` → `workspace` → `lang` → `vc` → `org` → `ai` → `tools`.
- Any file calling `my/leader` must come after `keys`.
- `ui/my-ui-icons` and `workspace/my-workspace-consult` reference corfu/marginalia/consult via `:after`/`with-eval-after-load`, so they tolerate being loaded earlier.

## Adding / removing things
- **Plugin:** new file + one `require` (see README). To disable one, comment out its `require`; nothing else depends on it unless noted in its header.
- **Language server:** install the binary; eglot picks it up. For unknown ones add to `eglot-server-programs` in `lang/my-lang-eglot.el` (or a new `my-lang-<name>.el`).
- **Org capture/agenda:** edit `org/my-org-capture.el` / `my-org-agenda.el`. `~/org` is `my/org-dir` (defined in `my-org-core.el`).
- **Evil off by default:** `(setq my/evil-enabled nil)` via customize; runtime toggle `C-c t e` / `SPC t e`.

## Updating packages
No lockfile; packages live in `~/.local/share/emacs-ez/elpa/` from GNU/NonGNU/MELPA.
- `M-x package-upgrade-all` (or `package-refresh-contents` first). Restart Emacs afterwards.
- On a fresh machine, just start Emacs: `use-package` installs everything (first start is slow; native-comp runs in background).
- If an upgrade breaks something: delete the package dir in `elpa/` (under the data dir) and reinstall, or pin an older build by copying a known-good `<pkg>-<ver>` from backup. Commit the repo often; consider snapshotting `elpa/` before big upgrades (`cp -R ~/.local/share/emacs-ez/elpa{,.bak}`).
- After upgrading Emacs itself, run `M-x package-recompile-all` and `SPC c G` (`my/treesit-install-all`) if grammars misbehave.

## Verifying changes
Headless load check (catches syntax errors, missing requires, void variables):

    emacs --batch -l ~/.emacs.d/init.el </dev/null 2>&1 | grep -iv "^compiling\|obsolete"

Check a command exists after loading: `--eval '(princ (fboundp (quote some-command)))'`.
Note batch mode can't catch GUI-only problems (faces, fonts) — also launch Emacs normally.

## Debugging
- Diagnostics: `SPC e` (`b` buffer list, `w` workspace list, `c`/`C` consult versions). Eglot reports via Flymake; `lang/my-lang-diagnostics.el` also opts Pyright into workspace analysis (`my/eglot-workspace-wide-diagnostics`).
- `emacs --debug-init` shows a backtrace for startup errors.
- Bisect a bad module: comment `require`s in the category file, or use `M-x bisect-init`-style halving (disable half the categories in `init.el`).
- Start clean: `emacs -Q` to confirm a problem is from this config.
- Keys: `SPC h k` (helpful), `SPC h b` (embark bindings), `C-h e` for `*Messages*`.
- Eglot: `M-x eglot-events-buffer`, `M-x eglot-reconnect` (`SPC c R`). Event logging is off by default (`eglot-events-buffer-config`); re-enable temporarily when debugging.

## Known workarounds (revisit when upgrading)
- `keys/my-keys-evil.el`: `(defvar evil-mode-buffers nil)` — Emacs 31+ globalized modes don't define it, Evil 1.15 expects it. Remove once Evil fixes this upstream.
- Corfu needs no `corfu-terminal` on Emacs 31 (child frames work on TTYs).
- `completion/my-completion-cape.el`: eglot capf is wrapped with `cape-wrap-buster`/`cape-wrap-nonexclusive`.
- `agent-shell` needs ACP adapters installed via npm (see README); command names can change between agent-shell releases (`agent-shell-anthropic-claude-acp-command`).
- tabspaces provides the workspace isolation; if buffer lists look wrong, `M-x tabspaces-reset-buffer-list`.

## lisp/ (Emacs 31 `user-lisp-directory`)
`early-init.el` points `user-lisp-directory` at `lisp/` and sets `user-lisp-auto-scrape` to nil, so at startup Emacs only puts `lisp/` and its subdirectories on `load-path` (no manual load-path code in `init.el`). `lisp/core/my-core-userlisp.el` runs `prepare-user-lisp` once Emacs has been idle 3s after startup: it byte-compiles and native-compiles files whose timestamps changed and regenerates `lisp/.user-lisp-autoloads.el` (generated files are git-ignored).
- It must run **after** init, not before: modules use macros (`my/leader`, `use-package`) that only exist once their packages are loaded; compiling earlier would turn those into broken function calls.
- `load-prefer-newer` is set, so an edited `.el` always wins over a stale `.elc`. If something acts odd after a big change, `C-u M-x my/prepare-lisp` rebuilds everything, or delete `lisp/**/*.elc`.
- New standalone libraries: put them in `lisp/custom-plugins/`; add `;;;###autoload` to commands that should work without an explicit `require`.

## Compile hygiene
- Category mains and `init.el` load features with `(mapc #'require '(...))` rather than separate `(require ...)` forms: the byte-compiler *evaluates* top-level `require`s, so compiling a category main (e.g. under Flymake, which runs `emacs -Q`) would otherwise load and run every feature file and fail.
- `my/leader` / `my/local-leader` are plain functions for the same reason (general's definer macros do not exist in an isolated compile).
- File headers carry `byte-compile-warnings: (not free-vars unresolved)`: modules set variables and call functions of packages that are not loaded when a single file is compiled in isolation.
- `elisp-flymake-byte-compile-load-path` is set to the real `load-path` (core/my-core-modern.el) so `require`s resolve.

## Performance notes
- Tree-sitter is Emacs-native (31+): `lang/my-lang-treesit.el` sets `treesit-enabled-modes` (via `setopt`, its setter fills the remap) and `treesit-auto-install-grammar` (`ask`). The `treesit-auto` package was removed: its global mode probed every grammar on each file open (~3s). Grammars live in `~/.local/share/emacs-ez/tree-sitter/`; `SPC c G` installs all missing ones.
- `core/my-core-performance.el` holds global tuning and the large-file guard: buffers over `my/large-file-threshold` (512K) switch off the modes in `my/large-file-disabled-modes`; Eglot is skipped and otherwise starts on an idle timer so opening never blocks. Add expensive new minor modes to that list.
- Prefer `:hook`/`:commands`/`:defer` over `:demand t` for new packages. Avoid `diff-hl-flydiff-mode` and indent-guide packages (re-render on every edit).
- Profile slow opens: `M-x profiler-start RET cpu`, open the file, `M-x profiler-report` (expand with `E`). For startup: `emacs --debug-init` and `M-x emacs-init-time`.

## Dart / Flutter
- `dart-ts-mode` is the community package, installed from GitHub with `package-vc` (`use-package :vc`); update with `M-x package-vc-upgrade`. Grammar source is registered in `lang/my-lang-dart.el`; install it with `SPC c G` or accept the prompt. Without the grammar, files fall back to `dart-mode`.
- `custom-plugins/ez-flutter.el` is your plugin; `lang/my-lang-flutter.el` autoloads its commands and binds `SPC m s/q/r/R/d/e/b` in Dart buffers. It keys sessions by perspective (persp-mode) if present; with tabspaces the key is just the project root.

## If generated folders reappear in ~/.emacs.d
- A running Emacs started before a path change keeps its old paths (and `M-x load-file init.el` does not re-run `early-init.el`): restart it.
- Async native-compilation spawns child Emacsen that ignore our paths; `early-init.el` sets `native-comp-async-env-modifier-form` so they use `~/.local/share/emacs-ez/native-comp-home/` instead. Any new process that loads packages the same way needs similar treatment.

## Org calendar (org-timegrid)
`org/my-org-agenda-ui.el`: `SPC o C` opens the SVG week calendar (needs an Emacs with SVG; GUI). It reads events from `org-agenda-files` (timed active timestamps) and writes new ones to `~/org/calendar.org`. The week buffer starts in Evil *emacs* state so its own keys work (`n`/`p` select, `t` time, `e` rename, `d` remove, `b`/`f` day/week, `j` jump, `.` today, `C-h m` for all). The regular agenda is left exactly as org ships it. An optional read-only day strip for the agenda is off by default (`my/org-agenda-day-strip`, toggle with `M-x my/org-agenda-day-strip-toggle`); when on, two advices make it show today and only appear when the agenda range includes today. `SPC o g` is a grouped open-task view (org-super-agenda groups apply only to that command).

## Popups
`workspace/my-workspace-popups.el` uses popper: buffers matching `popper-reference-buffers` (names or major modes) open as a bottom popup, grouped per tabspaces workspace. To make another kind of buffer a popup, add its name regexp or major mode to that list; `SPC b P` toggles one buffer between popup and normal.

## Terminal (Ghostel)
`tools/my-tools-terminal.el`: Ghostel + evil-ghostel + consult-ghostel. The native module (libghostty) is downloaded once to `~/.local/share/emacs-ez/ghostel/` (`M-x ghostel-download-module` re-fetches it, `ghostel-module-compile` builds from source with zig). In full-screen TUIs `ESC` goes to the app; `C-c C-r` toggles that, `C-c ESC` is a one-shot switch to normal state.

## Housekeeping
- `~/.emacs.d` holds config only. Generated state lives in `~/.local/share/emacs-ez/` (`elpa/`, `var/` history/backups/org-roam db, `etc/`, `custom.el`) and `~/.cache/emacs-ez/eln-cache/`; paths are set in `early-init.el` (honours `XDG_DATA_HOME`/`XDG_CACHE_HOME`). Backups and auto-saves go to `var/backup` and `var/auto-save` (never next to the file). Delete `var/` to reset state, the cache dir to force recompilation.
- Back up `~/org` separately; nothing in this repo stores notes.
