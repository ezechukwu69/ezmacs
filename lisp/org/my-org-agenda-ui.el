;;; my-org-agenda-ui.el --- Week calendar (org-timegrid) and grouped task view  -*- coding: utf-8; lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; The regular agenda (SPC o a / SPC o d) is left exactly as org ships it.
;;   SPC o C   week calendar (org-timegrid)    SPC o g   grouped open tasks

(declare-function my/leader "my-keys-leader")
(defvar my/org-dir)

;;; Grouped lists ------------------------------------------------------------

;; Only the "g" command below uses grouping; the regular agenda is untouched
;; (`org-super-agenda-groups' stays nil globally).
(use-package org-super-agenda
  :after org-agenda
  :demand t
  :custom (org-super-agenda-header-separator "")
  :config (org-super-agenda-mode 1))

(with-eval-after-load 'org-agenda
  (add-to-list
   'org-agenda-custom-commands
   '("g" "Grouped tasks" alltodo ""
     ((org-agenda-overriding-header "All open tasks")
      (org-super-agenda-groups
       '((:name "Overdue"  :deadline past :scheduled past)
         (:name "Today"    :time-grid t :scheduled today :deadline today)
         (:name "Due soon" :deadline future)
         (:name "Next"     :todo "NEXT")
         (:name "Waiting"  :todo "WAIT")
         (:auto-category t)))))
   t))

;;; Week calendar (org-timegrid) ---------------------------------------------
;; An SVG week view backed by your org files: drag to create/move/resize,
;; keyboard editing, and a day strip inside the agenda.  Needs SVG support.

(declare-function org-timegrid-week "org-timegrid-org")

(use-package org-timegrid
  :commands org-timegrid-week
  :init
  (setq org-timegrid-org-files 'agenda          ; read events from `org-agenda-files'
        org-timegrid-range-alignment 'center
        org-timegrid-default-zoom 0.7
        org-timegrid-org-capture-file (expand-file-name "calendar.org" my/org-dir)
        org-timegrid-org-capture-template
        '(:target file :template "* %{title}\n%{time-range}\n%?")
        org-timegrid-org-auto-save t
        org-timegrid-org-show-repeaters t
        org-timegrid-org-tag-color-alist
        '(("work" . indigo) ("personal" . green) ("errand" . cyan) ("reading" . yellow)))
  :config
  (require 'org-timegrid-org))

;; Optional read-only day strip (hours around now) at the top of the agenda; RET on
;; it opens the editable week view.  Off by default so the agenda stays stock:
;; set `my/org-agenda-day-strip' to t (or M-x my/org-agenda-day-strip-toggle).
(defcustom my/org-agenda-day-strip nil
  "Whether the org-timegrid day strip is inserted into the agenda."
  :type 'boolean :group 'org-agenda)

(use-package org-timegrid-agenda
  :ensure nil
  :after org-agenda
  :demand t
  :init
  (setq org-timegrid-agenda-insert-after nil
        org-timegrid-agenda-separator t
        org-timegrid-agenda-minutes-before 180
        org-timegrid-agenda-minutes-after 180)
  :config
  (when my/org-agenda-day-strip (org-timegrid-agenda-mode 1)))

(defun my/org-agenda-day-strip-toggle ()
  "Toggle the org-timegrid day strip in the agenda (re-run the agenda to see it)."
  (interactive)
  (setq my/org-agenda-day-strip (not my/org-agenda-day-strip))
  (org-timegrid-agenda-mode (if my/org-agenda-day-strip 1 -1))
  (message "Agenda day strip %s" (if my/org-agenda-day-strip "on" "off")))

;; The strip is labelled "TODAY" but, by default, shows the first day of the
;; agenda range (Monday in a week agenda).  Make it always show today, and only
;; appear when the agenda actually covers today.
(defun my/org-agenda-covers-today-p ()
  "Non-nil when the current agenda buffer's date range includes today."
  (let* ((today (calendar-absolute-from-gregorian (calendar-current-date)))
         (start (if (boundp 'org-starting-day) org-starting-day today))
         (ndays (pcase org-agenda-current-span
                  ('day 1) ('week 7) ('fortnight 14) ('month 31)
                  ((pred integerp) org-agenda-current-span)
                  (_ 1))))
    (and (<= start today) (< today (+ start ndays)))))

(with-eval-after-load 'org-timegrid-agenda
  (advice-add 'org-timegrid-agenda--display-day :around
              (lambda (orig)
                (if (my/org-agenda-covers-today-p)
                    (calendar-absolute-from-gregorian (calendar-current-date))
                  (funcall orig))))
  (advice-add 'org-timegrid-agenda-insert :around
              (lambda (orig &rest args)
                (when (my/org-agenda-covers-today-p) (apply orig args)))))

;; The week view has its own single-letter keys (n/p select, t time, e rename,
;; d delete, j jump, f/b week/day ...), which Evil's normal state would hide.
;; Emacs state leaves them alone; the SPC leader still works there.
(with-eval-after-load 'evil
  (evil-set-initial-state 'org-timegrid-mode 'emacs))

(defun my/org-calendar ()
  "Open the org week calendar (SVG).  Keys: `C-h m' inside the calendar."
  (interactive)
  (unless (image-type-available-p 'svg)
    (user-error "This Emacs has no SVG support"))
  (require 'org-timegrid-org)
  (org-timegrid-week)
  (message "n/p block  t time  e rename  d remove  b/f day/week  j jump  . today  RET open/create  q quit"))

(my/leader "oC" '(my/org-calendar :wk "week calendar")
           "og" '((lambda () (interactive) (org-agenda nil "g")) :wk "grouped tasks"))

(provide 'my-org-agenda-ui)
