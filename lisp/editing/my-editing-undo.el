;;; my-editing-undo.el --- Undo history  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package vundo
  :commands vundo
  :config (setq vundo-glyph-alist vundo-unicode-symbols))

(use-package undo-fu-session
  :demand t
  :config (undo-fu-session-global-mode 1))

(my/leader "bu" '(vundo :wk "undo tree"))

(provide 'my-editing-undo)
