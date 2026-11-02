;;; my-vc-diff-hl.el --- Gutter diff indicators  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package diff-hl
  :defer t                              ; loaded from the idle queue; the keys below autoload it
  :commands (diff-hl-next-hunk diff-hl-previous-hunk diff-hl-show-hunk diff-hl-revert-hunk)
  :hook ((magit-post-refresh . diff-hl-magit-post-refresh)
         (dired-mode . diff-hl-dired-mode))
  :init
  ;; Compute the diff in a subprocess instead of blocking on every buffer change.
  (setq diff-hl-update-async t)
  (my/load-when-file-opened 'diff-hl (lambda () (and buffer-file-name (vc-backend buffer-file-name))))
  :config
  (global-diff-hl-mode 1)
  ;; flydiff re-diffs on every edit; updating on save is much cheaper.
  (unless (display-graphic-p) (diff-hl-margin-mode 1)))

;; ]h / [h and their Emacs-mode keys: lisp/keys/my-keys-table.el
(my/leader "gs" '(diff-hl-show-hunk :wk "show hunk")
           "gr" '(diff-hl-revert-hunk :wk "revert hunk"))

(provide 'my-vc-diff-hl)
