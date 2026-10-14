;;; my-tools-which-key.el --- Key hints  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package which-key
  :ensure nil
  :demand t
  :custom
  (which-key-idle-delay 0.4)
  (which-key-sort-order #'which-key-key-order-alpha)
  (which-key-max-description-length 32)
  :config (which-key-mode 1))

(provide 'my-tools-which-key)
