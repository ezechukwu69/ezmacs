;;; my-completion-marginalia.el --- Annotations in the minibuffer  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package marginalia
  :demand t
  :bind (:map minibuffer-local-map ("M-A" . marginalia-cycle))
  :config (marginalia-mode 1))

(provide 'my-completion-marginalia)
