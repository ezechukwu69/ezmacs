;;; my-org-core.el --- Org basics  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function my/local-leader "my-keys-leader")

(defconst my/org-dir (expand-file-name "~/org/") "Main org directory.")
(make-directory my/org-dir t)

(use-package org
  :ensure nil
  :custom
  (org-directory my/org-dir)
  (org-default-notes-file (expand-file-name "notes.org" my/org-dir))
  (org-startup-indented t)
  (org-startup-folded 'content)
  (org-return-follows-link t)
  (org-edit-src-content-indentation 0)
  (org-src-tab-acts-natively t)
  (org-src-preserve-indentation t)
  (org-src-window-setup 'current-window)
  (org-confirm-babel-evaluate nil)
  (org-todo-keywords
   '((sequence "TODO(t)" "NEXT(n)" "WAIT(w@/!)" "|" "DONE(d!)" "CANCELLED(c@)")))
  (org-log-done 'time)
  (org-log-into-drawer t)
  (org-use-fast-todo-selection 'auto)
  (org-refile-targets '((org-agenda-files :maxlevel . 2)))
  (org-refile-use-outline-path 'file)
  (org-outline-path-complete-in-steps nil)
  (org-tags-column 0)
  (org-use-speed-commands t)
  (org-id-link-to-org-use-id 'create-if-interactive)
  (org-export-with-toc t)
  (org-export-backends '(html md latex ascii))
  :hook ((org-mode . visual-line-mode)
         (org-mode . my/org-setup))
  :config
  (require 'org-tempo)                   ; <s TAB, <el TAB, ...
  (defun my/org-setup ()
    (setq-local fill-column 100
                display-line-numbers nil
                tab-width 8)
    (electric-indent-local-mode -1))

  ;; Save org buffers after refile/todo changes
  (advice-add 'org-refile :after (lambda (&rest _) (org-save-all-org-buffers)))
  (advice-add 'org-todo :after (lambda (&rest _) (org-save-all-org-buffers))))

(my/leader
  "oo" '((lambda () (interactive) (dired my/org-dir)) :wk "org dir")
  "of" '((lambda () (interactive)
           (consult-find my/org-dir)) :wk "find org file")
  "os" '((lambda () (interactive)
           (consult-ripgrep my/org-dir)) :wk "search org")
  "ol" '(org-store-link :wk "store link")
  "oi" '(org-insert-link :wk "insert link"))

(my/local-leader :keymaps 'org-mode-map
  "t" '(org-todo :wk "todo state")
  "s" '(org-schedule :wk "schedule")
  "d" '(org-deadline :wk "deadline")
  "r" '(org-refile :wk "refile")
  "e" '(org-export-dispatch :wk "export")
  "p" '(org-priority :wk "priority")
  "q" '(org-set-tags-command :wk "tags")
  "i" '(org-insert-link :wk "link")
  "x" '(org-toggle-checkbox :wk "checkbox")
  "T" '(org-babel-tangle :wk "tangle")
  "'" '(org-edit-special :wk "edit special"))

(provide 'my-org-core)
