;;; my-tools-dired.el --- Dired  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package dired
  :ensure nil
  :custom
  (dired-listing-switches "-alh --group-directories-first")
  (dired-dwim-target t)
  (dired-kill-when-opening-new-dired-buffer t)
  (dired-recursive-copies 'always)
  (dired-recursive-deletes 'top)
  (delete-by-moving-to-trash t)
  :config
  ;; BSD ls on macOS lacks --group-directories-first; use GNU ls if installed
  (when (and (eq system-type 'darwin) (executable-find "gls"))
    (setq insert-directory-program "gls")))

(my/leader "fd" '(dired-jump :wk "dired here")
           "fp" '(project-dired :wk "project root"))

(provide 'my-tools-dired)
