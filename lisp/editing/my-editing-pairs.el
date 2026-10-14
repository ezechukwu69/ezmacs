;;; my-editing-pairs.el --- Auto pairs and structural editing  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(electric-pair-mode 1)
(show-paren-mode 1)
(setq show-paren-context-when-offscreen 'overlay)

(use-package expand-region
  :commands er/expand-region
  :init (my/leader "v" '(er/expand-region :wk "expand region")))

(provide 'my-editing-pairs)
