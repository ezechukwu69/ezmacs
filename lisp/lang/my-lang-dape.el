;;; my-lang-dape.el --- Debug Adapter Protocol client  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;; Adapters (debugpy, js-debug, codelldb, dlv, ...) are installed separately;
;; see `dape-configs' / M-x dape for the supported ones.

(use-package dape
  :commands (dape dape-breakpoint-toggle dape-next dape-step-in dape-step-out
             dape-continue dape-restart dape-quit dape-repl dape-info
             dape-eval dape-watch-dwim dape-breakpoint-remove-all dape-until
             dape-breakpoint-expression dape-breakpoint-log dape-disconnect-quit)
  :custom
  (dape-buffer-window-arrangement 'right)
  (dape-inlay-hints t)
  (dape-info-hide-mode-line nil)
  :config
  (add-hook 'dape-start-hook (lambda () (save-some-buffers t t)))
  (add-hook 'dape-display-source-hook #'pulse-momentary-highlight-one-line)
  ;; Keep session buffers when the debug session ends.
  (setq dape-repl-echo-shell-output t))

(my/leader
  "d"  '(:ignore t :wk "debug")
  "dd" '(dape :wk "start/configure")
  "db" '(dape-breakpoint-toggle :wk "toggle breakpoint")
  "dB" '(dape-breakpoint-remove-all :wk "clear breakpoints")
  "de" '(dape-breakpoint-expression :wk "conditional breakpoint")
  "dl" '(dape-breakpoint-log :wk "log point")
  "dc" '(dape-continue :wk "continue")
  "dn" '(dape-next :wk "step over")
  "di" '(dape-step-in :wk "step in")
  "do" '(dape-step-out :wk "step out")
  "du" '(dape-until :wk "run to cursor")
  "dr" '(dape-restart :wk "restart")
  "dp" '(dape-repl :wk "repl")
  "dI" '(dape-info :wk "info")
  "dw" '(dape-watch-dwim :wk "watch")
  "dx" '(dape-eval :wk "eval")
  "dq" '(dape-quit :wk "quit"))

(provide 'my-lang-dape)
