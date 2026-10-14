;;; my-org-evil.el --- Evil bindings for org  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function evil-org-set-key-theme "evil-org")
(declare-function evil-org-agenda-set-keys "evil-org-agenda")

(use-package evil-org
  :after (evil org)
  :hook ((org-mode . evil-org-mode)
         (org-agenda-mode . evil-org-mode))
  :config
  (require 'evil-org-agenda)
  (evil-org-agenda-set-keys)
  (evil-org-set-key-theme '(navigation insert textobjects additional calendar todo)))

(provide 'my-org-evil)
