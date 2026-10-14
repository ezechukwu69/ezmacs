;;; my-vc-magit.el --- Magit  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package transient
  :defer t)

(use-package magit
  :commands (magit-status magit-dispatch magit-file-dispatch magit-project-status)
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  (magit-bury-buffer-function #'magit-restore-window-configuration)
  (magit-diff-refine-hunk t)
  (magit-save-repository-buffers 'dontask))

(my/leader
  "gg" '(magit-status :wk "status")
  "gG" '(magit-dispatch :wk "dispatch")
  "gb" '(magit-blame :wk "blame")
  "gl" '(magit-log-current :wk "log")
  "gL" '(magit-log-buffer-file :wk "file log")
  "gf" '(magit-file-dispatch :wk "file actions")
  "gc" '(magit-commit :wk "commit")
  "gp" '(magit-push :wk "push")
  "gP" '(magit-pull :wk "pull")
  "gd" '(magit-diff-buffer-file :wk "diff file")
  "gF" '(magit-fetch :wk "fetch"))

(provide 'my-vc-magit)
