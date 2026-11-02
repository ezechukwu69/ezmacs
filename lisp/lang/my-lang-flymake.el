;;; my-lang-flymake.el --- Diagnostics  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-


(declare-function my/leader "my-keys-leader")

(use-package flymake
  :ensure nil
  :hook ((prog-mode . flymake-mode))
  :custom (flymake-show-diagnostics-at-end-of-line 'short))

;; ]e / [e and their Emacs-mode keys: lisp/keys/my-keys-table.el

(my/leader
  "en" '(flymake-goto-next-error :wk "next")
  "ep" '(flymake-goto-prev-error :wk "previous"))

(provide 'my-lang-flymake)
