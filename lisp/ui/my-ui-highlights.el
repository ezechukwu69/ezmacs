;;; my-ui-highlights.el --- Visual helpers  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(use-package hl-todo
  :hook ((prog-mode text-mode) . hl-todo-mode))

(use-package rainbow-mode
  :commands rainbow-mode)

(provide 'my-ui-highlights)
