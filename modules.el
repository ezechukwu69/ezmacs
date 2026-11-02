;;; modules.el --- Which modules are enabled, and in what order  -*- lexical-binding: t; -*-

;;; Commentary:

;; This is the one place that decides what loads, like Doom's `doom!' block.
;; Loaded by init.el through `my-modules' (lisp/my-modules.el).
;;
;;   Disable a module:  comment it out or delete it (its file is never loaded).
;;   Add a module:      create lisp/<category>/my-<category>-<name>.el ending in
;;                      (provide 'my-<category>-<name>), then list <name> under
;;                      :<category> here.  A new category is just a new keyword
;;                      with a lisp/<category>/ directory.
;;   Flags:             (name +flag ...) hands flags to a module; it reads them
;;                      with (my-module-flag-p :category 'name '+flag).
;;   Ask about another module: (my-module-p :lang 'dart).
;;   See what loaded:   M-x my-modules-report
;;
;; Order matters, both between categories and inside one: later modules may
;; rely on earlier ones.  Personal tweaks that are not a module go in config.el.

;;; Code:

(my!
 ;; Package manager, sane defaults, file hygiene.  The rest of the config
 ;; depends on `packages' (use-package) and `environment' (PATH); leave them on.
 :core
 packages
 defaults
 files
 performance
 modern
 userlisp
 environment

 ;; Theme, fonts, modeline, icons.
 :ui
 prefs
 theme
 font
 icons
 modeline
 highlights

 ;; Order matters: evil first, then `dsl' (the `my/bind' macro), `jumps' (the jump
 ;; list machinery behind C-o / C-i), `table' (EVERY Evil key next to its
 ;; Emacs-mode key: edit keys there), then the leader definer other modules use.
 :keys
 evil
 dsl
 jumps
 table
 leader

 ;; Undo, pairs, navigation, whitespace, snippets, multiple cursors.
 :editing
 undo
 pairs
 navigation
 whitespace
 snippets
 multiple-cursors

 ;; Minibuffer: vertico + orderless + marginalia + consult + embark
 ;; In-buffer:  corfu + cape
 :completion
 vertico
 orderless
 marginalia
 consult
 embark
 corfu
 cape

 ;; One workspace (tab) per project; each workspace only sees its own buffers.
 :workspace
 project
 tabspaces
 start
 consult
 ibuffer
 popups

 ;; Eglot, tree-sitter, formatting, debugging, language modes.
 :lang
 eglot
 treesit
 flymake
 diagnostics
 format
 vite-plus
 dape
 envrc
 modes
 markdown
 dart
 flutter

 ;; Magit, in-forge review, diff-hl.
 :vc
 magit
 review
 diff-hl

 ;; Org, agenda, capture, roam.
 :org
 core
 agenda
 agenda-ui
 capture
 babel
 appearance
 evil
 roam

 ;; agent-shell (ACP chat buffers) and ez-agents (terminal agent sidebar).
 :ai
 agent-shell
 agents

 ;; which-key, helpful, terminal, dired, servers, YouTube/music (empv), and the
 ;; start-up dashboard.  Keep `dashboard' last: it links to everything above.
 :tools
 which-key
 help
 dired
 terminal
 server
 media
 dashboard)

;;; modules.el ends here
