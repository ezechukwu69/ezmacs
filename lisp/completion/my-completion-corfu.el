;;; my-completion-corfu.el --- In-buffer completion popup  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function general-define-key "general")

(use-package corfu
  :demand t
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.15)
  (corfu-auto-prefix 2)
  (corfu-cycle t)
  (corfu-preselect 'first)               ; first candidate selected, RET/TAB-complete accepts it
  (corfu-quit-no-match 'separator)
  (corfu-popupinfo-delay '(0.5 . 0.2))
  :config
  (global-corfu-mode 1)
  (corfu-history-mode 1)
  (corfu-popupinfo-mode 1)
  (general-define-key :keymaps 'corfu-map
                      "TAB"     'corfu-next
                      [tab]     'corfu-next
                      "S-TAB"   'corfu-previous
                      [backtab] 'corfu-previous
                      "C-j"     'corfu-next
                      "C-k"     'corfu-previous
                      "RET"     'corfu-insert
                      "C-SPC"   'corfu-insert-separator))

;; Corfu works in the terminal natively since Emacs 31 (no corfu-terminal needed).

(provide 'my-completion-corfu)
