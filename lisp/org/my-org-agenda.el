;;; my-org-agenda.el --- Agenda  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(defvar my/org-dir)                          ; defined in my-org-core.el

(use-package org-agenda
  :ensure nil
  :after org
  :custom
  (org-agenda-files (list my/org-dir))   ; every *.org directly in ~/org
  (org-agenda-window-setup 'current-window)
  (org-agenda-start-with-log-mode t)
  (org-agenda-skip-scheduled-if-done t)
  (org-agenda-skip-deadline-if-done t)
  (org-agenda-span 'week)
  (org-agenda-tags-column 0)
  (org-agenda-block-separator ?─)
  (org-deadline-warning-days 5)
  (org-agenda-custom-commands
   '(("d" "Dashboard"
      ((agenda "" ((org-deadline-warning-days 7)))
       (todo "NEXT" ((org-agenda-overriding-header "Next actions")))
       (todo "WAIT" ((org-agenda-overriding-header "Waiting")))
       (todo "TODO" ((org-agenda-overriding-header "Backlog")
                     (org-agenda-skip-function
                      '(org-agenda-skip-entry-if 'scheduled 'deadline))))))
     ("w" "Waiting" todo "WAIT"))))

(my/leader
  "oa" '(org-agenda :wk "agenda")
  "od" '((lambda () (interactive) (org-agenda nil "d")) :wk "dashboard"))

(provide 'my-org-agenda)
