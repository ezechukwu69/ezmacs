;;; ez-review-magit.el --- Magit integration for ez-review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Adds `ez-review-dispatch' to `magit-dispatch' (key `@') and, optionally, a
;; "Review requests" section to the status buffer listing the PRs/MRs waiting
;; for you.  The section is off by default (it makes a network call each time
;; the status buffer is opened, at most once per `ez-review-magit-cache-seconds'):
;;
;;   (setq ez-review-magit-status-section t)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-forge)
(require 'ez-review-ui)

(declare-function magit-toplevel "magit-git")
(declare-function magit-refresh-buffer "magit-mode")
(declare-function magit-insert-heading "magit-section")
(declare-function magit-section-value-if "magit-section")
(declare-function ez-review-view "ez-review-view")
(declare-function ez-review-dispatch "ez-review")

(defcustom ez-review-magit-status-section nil
  "Non-nil: show PRs/MRs awaiting your review in the Magit status buffer."
  :type 'boolean
  :group 'ez-review)

(defcustom ez-review-magit-cache-seconds 120
  "How long the status section reuses a fetched list."
  :type 'integer
  :group 'ez-review)

(defvar ez-review-magit--cache (make-hash-table :test #'equal)
  "Repository root -> (TIME . PRS).")

(defun ez-review-magit--fetch (root buffer)
  "Refresh the cache for ROOT; redraw BUFFER if the list changed."
  (condition-case err
      (let ((forge (ez-review-forge-current root)))
        (ez-review-forge-list
         forge 'pr '(:filter review :state open)
         (lambda (prs)
           (unless (stringp prs)
             (let* ((old (cdr (gethash root ez-review-magit--cache)))
                    (changed (not (equal (mapcar #'ez-review-pr-number old)
                                         (mapcar #'ez-review-pr-number prs)))))
               (puthash root (cons (float-time) prs) ez-review-magit--cache)
               (when (and changed (buffer-live-p buffer))
                 (with-current-buffer buffer (magit-refresh-buffer))))))))
    (error (message "ez-review: %s" (error-message-string err)))))

(defvar-keymap magit-review-status-item-section-map
  :doc "Keymap for review rows in the Magit status buffer."
  "RET" #'ez-review-magit-visit-item)

(defun ez-review-magit-visit-item ()
  "Open the PR/MR on this row."
  (interactive)
  (let ((pr (magit-section-value-if 'review-status-item)))
    (when pr
      (ez-review-view (ez-review-forge-current default-directory) 'pr (ez-review-pr-number pr)))))

(defun ez-review-magit-insert-requests ()
  "Insert the \"Review requests\" section into the Magit status buffer."
  (when (and ez-review-magit-status-section (magit-toplevel))
    (let* ((root (magit-toplevel))
           (entry (gethash root ez-review-magit--cache)))
      (when (or (null entry)
                (> (- (float-time) (car entry)) ez-review-magit-cache-seconds))
        ;; Stamp now so a slow fetch is not started twice while it runs.
        (puthash root (cons (float-time) (cdr entry)) ez-review-magit--cache)
        (ez-review-magit--fetch root (current-buffer)))
      (when-let* ((prs (cdr entry)))
        (magit-insert-section (review-status (length prs))
          (magit-insert-heading
            (propertize (format "Review requests (%d)" (length prs)) 'face 'magit-section-heading))
          (dolist (pr prs)
            (magit-insert-section (review-status-item pr)
              (insert (ez-review-ui-state-icon pr) " "
                      (propertize (format "#%-4d" (ez-review-pr-number pr)) 'face 'ez-review-number) " "
                      (ez-review-pr-title pr)
                      (propertize (format "  @%s" (ez-review-pr-author pr)) 'face 'ez-review-meta)
                      "\n")))
          (insert "\n"))))))

;;;###autoload
(defun ez-review-magit-setup ()
  "Hook ez-review into Magit's dispatch menu and status buffer."
  (with-eval-after-load 'magit
    (require 'transient)
    (unless (ignore-errors (transient-get-suffix 'magit-dispatch "@"))
      (ignore-errors
        (transient-append-suffix 'magit-dispatch "!"
          '("@" "Review PRs/MRs" ez-review-dispatch))))
    (add-hook 'magit-status-sections-hook #'ez-review-magit-insert-requests t)))

(ez-review-magit-setup)

(provide 'ez-review-magit)
;;; ez-review-magit.el ends here
