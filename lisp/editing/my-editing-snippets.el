;;; my-editing-snippets.el --- Snippets  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package yasnippet
  :defer t
  :init (my/load-when-file-opened 'yasnippet #'my/code-or-text-buffer-p)
  :config (yas-global-mode 1))

(use-package yasnippet-snippets
  :after yasnippet)

(provide 'my-editing-snippets)
