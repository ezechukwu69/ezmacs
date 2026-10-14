;;; my-core-environment.el --- Shell environment (PATH for LSP servers, node, ...)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package exec-path-from-shell
  :if (memq window-system '(mac ns x pgtk))
  :demand t
  :config
  (setq exec-path-from-shell-arguments '("-l"))
  (dolist (var '("PATH" "MANPATH" "ANTHROPIC_API_KEY" "OPENAI_API_KEY" "GEMINI_API_KEY"))
    (add-to-list 'exec-path-from-shell-variables var))
  (exec-path-from-shell-initialize))

(provide 'my-core-environment)
