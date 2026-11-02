# External programs this config needs

Emacs packages install themselves (`use-package` fetches them from MELPA/GNU/NonGNU on first
start). The **programs** below are not Emacs packages and are never installed for you. Commands
assume macOS on Apple Silicon with [Homebrew](https://brew.sh). Everything is optional except where
marked **required**; a missing optional program only disables the feature that uses it.

Quick start (what most people want, in two commands):

```sh
xcode-select --install     # git, cc, make, clangd  (required, see "Toolchain")
brew install ripgrep fd coreutils git-delta gh glab direnv tmux mpv yt-dlp cmark-gfm node deno
brew install --cask font-aporetic font-iosevka font-symbols-only-nerd-font
```

Then pick from the sections below for AI agents, languages and formatters. Run the
[check script](#check-what-is-missing) at the end to see what is still missing.

---

## Emacs itself (required)

Emacs **31 or newer** (developed on 32.0.50, Homebrew `emacs-plus-app@master`, from the
[d12frosted/emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus) tap). The build must have:

| Feature | Used for | Check |
|---|---|---|
| tree-sitter | `*-ts-mode`, `treesit-enabled-modes` | `(treesit-available-p)` |
| native compilation | background native-comp of `lisp/` | `(native-comp-available-p)` |
| SQLite | org-roam database | `(sqlite-available-p)` |
| xwidgets | Markdown live preview inside Emacs (falls back to the browser) | `(featurep 'xwidget-internal)` |
| JSON | eglot, ez-agents, empv | `(fboundp 'json-parse-string)` |

```sh
emacs --batch --eval '(message "ts=%s nc=%s sql=%s xw=%s" (treesit-available-p) (native-comp-available-p) (sqlite-available-p) (featurep (quote xwidget-internal)))'
```

## Toolchain (required)

```sh
xcode-select --install
```

Provides `git`, `cc`/`clang`, `make` and `clangd`. Needed by: magit and everything git-based,
compiling tree-sitter grammars (`M-x treesit-install-language-grammar` builds them from source with
`cc`), installing `dart-ts-mode` straight from GitHub (`package-vc`), and the C language server.

## Search, files and dired

| Program | Used by | Install |
|---|---|---|
| `rg` ripgrep | `consult-ripgrep` (`SPC /`, `SPC s r`, `SPC p g`) | `brew install ripgrep` |
| `fd` | `consult-fd` (`SPC s f`) | `brew install fd` |
| `gls` GNU ls | dired on macOS (falls back to BSD `ls` without it) | `brew install coreutils` |

## Git and code review

| Program | Used by | Install |
|---|---|---|
| `git` | magit, project.el, ez-agents worktrees | Xcode tools (above) |
| `delta` | ez-agents review "delta" view (`D`) | `brew install git-delta` |
| `gh` | ez-review (GitHub PRs), ez-agents "finish worktree" | `brew install gh`, then `gh auth login` |
| `glab` | ez-review (GitLab MRs) | `brew install glab`, then `glab auth login` |

## Environment

| Program | Used by | Install |
|---|---|---|
| `direnv` | `envrc` (per-project environments; the module is skipped when missing) | `brew install direnv`, hook it into your shell per the direnv docs |
| `emacsclient` | `server` module, agent hooks | ships with Emacs |

Emacs reads your PATH from a login shell (cached, refreshed in the background by
`core/my-core-environment.el`), so tools installed with mise/asdf/bun/npm-global are found as long
as your shell startup files put them on PATH. `M-x my/shell-env-refresh` re-reads it.

## JavaScript runtimes

| Program | Used by | Install |
|---|---|---|
| `node` + `npm` | the ACP adapters, many language servers/formatters | `brew install node`, or `mise use -g node@latest` |
| `deno` | empv's bundled YouTube search server (`ivjs`) | `brew install deno`, or `mise use -g deno@latest` |
| `bun` | optional alternative for global JS tools | `brew install oven-sh/bun/bun` |

## AI agents

Two separate integrations; install what you use.

**ez-agents** (terminal agents in a sidebar, `SPC a ...`) runs each agent's own CLI inside `tmux`:

| Program | Install |
|---|---|
| `tmux` (required for persistent sessions) | `brew install tmux` |
| `claude` Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` (or `npm i -g @anthropic-ai/claude-code`), then run `claude` once to log in |
| `codex` | `brew install --cask codex` (or `npm i -g @openai/codex`) |
| `gemini` | `npm i -g @google/gemini-cli` |
| `cursor-agent` | `curl https://cursor.com/install -fsS \| bash` |

**agent-shell** (ACP chat buffers) needs each agent's ACP adapter *and* the agent CLI above:

```sh
npm i -g @agentclientprotocol/claude-agent-acp    # Claude Code
npm i -g @zed-industries/codex-acp                # Codex
npm i -g @google/gemini-cli                       # Gemini (speaks ACP itself)
```

## Media: YouTube and music (empv, `SPC y`)

| Program | Used by | Install |
|---|---|---|
| `mpv` (required) | the player; empv drives it over IPC | `brew install mpv` |
| `yt-dlp` (required) | lets mpv play YouTube URLs | `brew install yt-dlp` |
| `deno` | search through empv's local `ivjs` server (see below) | `brew install deno` |

Search (`SPC y y`) needs an Invidious API. With `deno` installed the config uses empv's bundled
local server (`ivjs`); without it, it falls back to the public instance set in
`lisp/tools/my-tools-media.el`, which can stop working at any time. The first `ivjs` start downloads
YouTube.js and can take longer than empv waits: if it says "Failed to start ivjs", run the command
again. Keep `yt-dlp` current (`brew upgrade yt-dlp`): YouTube changes break old versions.

## Markdown preview

One converter on PATH (the first found of `cmark-gfm`, `comrak`, `pandoc` is used):

```sh
brew install cmark-gfm        # smallest
brew install pandoc           # or this
```

## Languages

**Dart / Flutter** (`dart-ts-mode`, `SPC m` in Dart buffers, debugging through `flutter debug_adapter`):

```sh
brew install --cask flutter           # includes the Dart SDK (`dart`, `dart format`, `dart language-server`)
# standalone Dart only:  brew tap dart-lang/dart && brew install dart
```

**Vite+** (`vp`, only active inside a project whose `package.json` mentions `vite-plus`):

```sh
npm i -g vite-plus
```

**Language servers** (eglot starts one automatically when it is on PATH; none are required):

| Language | Server | Install |
|---|---|---|
| TypeScript / JavaScript | `typescript-language-server` | `npm i -g typescript-language-server typescript` |
| Python | `ruff` (`ruff server`), `pyright` | `brew install ruff`, `npm i -g pyright` |
| Go | `gopls` | `brew install gopls` |
| Rust | `rust-analyzer` | `brew install rust-analyzer` |
| C / C++ | `clangd` | Xcode tools (above) |
| JSON / CSS / HTML | `vscode-json-language-server` etc. | `npm i -g vscode-langservers-extracted` |
| YAML | `yaml-language-server` | `npm i -g yaml-language-server` |
| Shell | `bash-language-server` | `npm i -g bash-language-server` |
| Dart | `dart language-server` | Dart SDK (above) |

**Formatters** (Apheleia formats on save with whichever fits the mode; must be on PATH):

| Language | Formatter | Install |
|---|---|---|
| JS / TS / CSS / JSON / Markdown | `prettier` | `npm i -g prettier` |
| Vite+ projects | `vp fmt` | `npm i -g vite-plus` |
| Python | `ruff format` or `black` | `brew install ruff` / `brew install black` |
| Go | `gofmt` | ships with Go (`brew install go`) |
| Rust | `rustfmt` | `brew install rustfmt` (or `rustup`) |
| Shell | `shfmt` | `brew install shfmt` |
| C / C++ | `clang-format` | `brew install clang-format` |
| Dart | `dart format` | Dart SDK (above) |

**Debug adapters** (dape, `SPC d`) are installed separately per language: `debugpy`
(`pip install debugpy`), `js-debug`, `codelldb`, `dlv` (`brew install delve`). Dart/Flutter needs
nothing extra (it uses `flutter debug_adapter`). See `M-x dape` for the supported list.

## Fonts

| Font | Used by | Install |
|---|---|---|
| Aporetic (first choice) | the default face (`ui/my-ui-font.el`; falls back to Iosevka, then Menlo) | `brew install --cask font-aporetic` |
| Iosevka | fallback | `brew install --cask font-iosevka` |
| Nerd symbols | icons in the modeline, dired, completion, ez-agents | `brew install --cask font-symbols-only-nerd-font`, or `M-x nerd-icons-install-fonts` |

## Org (optional)

PDF export (`org-export-backends` includes `latex`) needs a TeX distribution:
`brew install --cask mactex-no-gui`. Plain org, agenda, capture, roam and HTML/Markdown export need
nothing extra (org-roam uses Emacs' built-in SQLite).

## Downloaded automatically (no action needed)

- **Emacs packages**: fetched by `use-package` on first start; if one is reported as
  `Cannot open load file`, run `M-x package-quickstart-refresh` and restart (see MAINTAINING.md).
- **Ghostel terminal module** (libghostty): downloaded as a prebuilt binary the first time a
  terminal is opened.
- **Tree-sitter grammars**: Emacs offers to build each one the first time you open a file in that
  language (needs `git` and `cc`).
- **`dart-ts-mode`**: cloned from GitHub by `package-vc` (needs `git`).
- **empv `ivjs` dependencies**: downloaded by `deno` on its first run.

---

## Check what is missing

Prints `MISSING` for each program not on PATH. It uses a login, non-interactive shell
(`zsh -l -c`) because that is exactly how Emacs reads your PATH, so a tool reported missing here is
also invisible to Emacs even if your interactive terminal finds it (fix that in `~/.zprofile` /
`~/.zshenv`, not `~/.zshrc`). Programs you do not use are fine to leave missing.

```sh
zsh -lc '
for b in git cc make clangd rg fd gls delta gh glab direnv tmux node npm deno \
         mpv yt-dlp cmark-gfm claude codex gemini cursor-agent claude-agent-acp codex-acp \
         dart flutter vp prettier ruff gopls rust-analyzer typescript-language-server \
         shfmt emacsclient; do
  command -v "$b" >/dev/null 2>&1 || echo "MISSING  $b"
done'
```
