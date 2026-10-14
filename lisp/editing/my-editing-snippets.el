;;; my-editing-snippets.el --- Snippets  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package yasnippet
  :demand t
  :config (yas-global-mode 1))

(use-package yasnippet-snippets
  :after yasnippet)

(provide 'my-editing-snippets)
