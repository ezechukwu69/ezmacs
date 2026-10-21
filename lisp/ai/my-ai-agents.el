;;; my-ai-agents.el --- Terminal agents sidebar (ez-agents: Claude Code, Codex, Cursor, ...)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; Agents run in Ghostel buffers (`ez/agents-backend'); the sidebar lists them
;; per project with their sub-agents.  Unlike agent-shell (ACP chat buffers),
;; these are the agents' own TUIs.  For accurate status and sub-agent tracking
;; with Claude Code, accept the one-time per-project hook install prompt
;; (writes .claude/settings.local.json); other agents fall back to
;; process/activity heuristics.

(use-package ez-agents
  :ensure nil
  ;; `ez-agents-event' is called by the agents' hooks through emacsclient, possibly
  ;; before anything else has loaded the plugin: it must always be autoloadable.
  :commands (ez-agents-new ez-agents-switch ez-agents-goto-waiting ez-agents-event
             ez-agents-debug-report ez-agents-toggle-fullscreen
             ez-agents-install-hooks ez-agents-uninstall-hooks))

;; Fullscreen the agent terminal and back.  C-M-z is global and reaches Emacs
;; from inside a Ghostel terminal too (M-SPC a z works there as well).
(keymap-global-set "C-M-z" #'ez-agents-toggle-fullscreen)
(with-eval-after-load 'ghostel
  (setopt ghostel-keymap-exceptions
          (seq-union ghostel-keymap-exceptions '("C-M-z"))))

(use-package ez-agents-ui
  :ensure nil
  :commands (ez-agents-sidebar-toggle ez-agents-sidebar-show))

(use-package ez-agents-dashboard
  :ensure nil
  :commands (ez-agents-dashboard))

(use-package ez-agents-console
  :ensure nil
  :commands (ez-agents-console))

(use-package ez-agents-chats
  :ensure nil
  :commands (ez-agents-resume-chat))

(use-package ez-agents-review
  :ensure nil
  :commands (ez-agents-review))

(use-package ez-agents-worktree
  :ensure nil
  :commands (ez-agents-new-worktree ez-agents-worktree-finish))

;; Agents run in tmux so they survive Emacs closing; session state and
;; worktrees live outside the repo (worktrees: ~/.emacs-worktrees).
(use-package ez-agents-persist
  :ensure nil
  :commands (ez-agents-restore ez-agents-attach)
  :init
  (setq ez-agents-data-directory
        (expand-file-name "ez-agents/" (if (bound-and-true-p my/data-dir)
                                           my/data-dir
                                         user-emacs-directory)))
  ;; Pick up agents still running from a previous Emacs (detached until opened).
  (add-hook 'emacs-startup-hook
            (lambda () (run-with-idle-timer 2 nil #'ez-agents-restore t))))

;; These are read-mostly buffers with single-key commands: Emacs state.
;; Ediff's control buffer needs it too (used by the review's `e' / `E').
(with-eval-after-load 'evil
  (dolist (m '(ez-agents-mode ez-agents-dashboard-mode ez-agents-console-mode
               ez-agents-review-mode ediff-mode))
    (evil-set-initial-state m 'emacs)))

(my/leader
  "al" '(ez-agents-sidebar-toggle :wk "agents sidebar")
  "aD" '(ez-agents-dashboard :wk "agents dashboard")
  "aI" '(ez-agents-console :wk "agents console (C-u: pick target)")
  "aN" '(ez-agents-new :wk "new terminal agent")
  "az" '(ez-agents-toggle-fullscreen :wk "agent fullscreen (C-M-z)")
  "ar" '(ez-agents-resume-chat :wk "resume an existing chat here")
  "aW" '(ez-agents-new-worktree :wk "new agent in a worktree")
  "aR" '(ez-agents-review :wk "review agent changes")
  "aF" '(ez-agents-worktree-finish :wk "finish worktree (PR/merge/remove)")
  "aS" '(ez-agents-restore :wk "restore running agents")
  "aj" '(ez-agents-goto-waiting :wk "jump to waiting agent")
  "aJ" '(ez-agents-switch :wk "switch terminal agent")
  "aH" '(ez-agents-install-hooks :wk "install status hooks"))

(provide 'my-ai-agents)
