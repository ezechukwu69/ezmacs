;;; my-ui-icons.el --- Icons  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;; Run M-x nerd-icons-install-fonts once.

(use-package nerd-icons
  :demand t)

(use-package nerd-icons-completion
  :after (marginalia nerd-icons)
  :hook (marginalia-mode . nerd-icons-completion-marginalia-setup)
  :config (nerd-icons-completion-mode 1))

(use-package nerd-icons-dired
  :hook (dired-mode . nerd-icons-dired-mode))

(use-package nerd-icons-corfu
  :after corfu
  :config (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

(provide 'my-ui-icons)
