;;; my-editing-navigation.el --- Jumping around  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function general-define-key "general")

(use-package avy
  :commands (avy-goto-char-timer avy-goto-line)
  :init
  (setq avy-all-windows nil
        avy-background t)
  (general-define-key :states '(normal visual motion)
                      "gs" 'avy-goto-char-timer
                      "gl" 'avy-goto-line))

(use-package ace-window
  :commands ace-window
  :init
  (setq aw-scope 'frame)
  (my/leader "ww" '(ace-window :wk "pick window")))

(provide 'my-editing-navigation)
