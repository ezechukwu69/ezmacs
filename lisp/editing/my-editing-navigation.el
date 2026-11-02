;;; my-editing-navigation.el --- Jumping around  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package avy
  :commands (avy-goto-char-timer avy-goto-line)
  :init
  (setq avy-all-windows nil
        avy-background t))

;; gs / gl and their Emacs-mode keys: lisp/keys/my-keys-table.el

(use-package ace-window
  :commands ace-window
  :init
  (setq aw-scope 'frame)
  (my/leader "ww" '(ace-window :wk "pick window")))

(provide 'my-editing-navigation)
