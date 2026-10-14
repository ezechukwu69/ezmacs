;;; my-lang-envrc.el --- direnv  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package envrc
  :if (executable-find "direnv")
  :hook (after-init . envrc-global-mode))

(provide 'my-lang-envrc)
