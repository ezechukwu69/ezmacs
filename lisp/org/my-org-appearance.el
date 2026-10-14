;;; my-org-appearance.el --- Prettier org  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package org-modern
  :hook ((org-mode . org-modern-mode)
         (org-agenda-finalize . org-modern-agenda))
  :custom
  (org-modern-star 'replace)
  (org-modern-table nil)                 ; keep tables aligned in all fonts
  (org-modern-block-fringe nil))

(use-package org-appear                  ; reveal emphasis markers/links under point
  :hook (org-mode . org-appear-mode)
  :custom
  (org-hide-emphasis-markers t)
  (org-appear-autolinks t)
  (org-appear-autoentities t)
  (org-appear-autosubmarkers t)
  (org-appear-trigger 'always))

(setq org-pretty-entities t
      org-ellipsis " ▾"
      org-auto-align-tags nil
      org-special-ctrl-a/e t
      org-insert-heading-respect-content t)

(provide 'my-org-appearance)
