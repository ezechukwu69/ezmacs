;;; my-lang-envrc.el --- direnv  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package envrc
  :if (executable-find "direnv")
  :defer t
  :init (my/load-when-file-opened 'envrc)  ; first file opened; Eglot waits 0.4s anyway
  :config (envrc-global-mode 1))

(provide 'my-lang-envrc)
