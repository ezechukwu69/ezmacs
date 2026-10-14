;;; my-vc-diff-hl.el --- Gutter diff indicators  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function general-define-key "general")

(use-package diff-hl
  :demand t
  :hook ((magit-post-refresh . diff-hl-magit-post-refresh)
         (dired-mode . diff-hl-dired-mode))
  :config
  (global-diff-hl-mode 1)
  ;; flydiff re-diffs on every edit; updating on save is much cheaper.
  (unless (display-graphic-p) (diff-hl-margin-mode 1))
  (general-define-key :states 'normal
                      "]h" 'diff-hl-next-hunk
                      "[h" 'diff-hl-previous-hunk)
  (my/leader "gs" '(diff-hl-show-hunk :wk "show hunk")
             "gr" '(diff-hl-revert-hunk :wk "revert hunk")))

(provide 'my-vc-diff-hl)
