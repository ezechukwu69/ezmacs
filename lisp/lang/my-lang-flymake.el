;;; my-lang-flymake.el --- Diagnostics  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function general-define-key "general")

(use-package flymake
  :ensure nil
  :hook ((prog-mode . flymake-mode))
  :custom (flymake-show-diagnostics-at-end-of-line 'short)
  :config
  (general-define-key :states 'normal :keymaps 'flymake-mode-map
                      "]e" 'flymake-goto-next-error
                      "[e" 'flymake-goto-prev-error))

(my/leader
  "en" '(flymake-goto-next-error :wk "next")
  "ep" '(flymake-goto-prev-error :wk "previous"))

(provide 'my-lang-flymake)
