;;; ez-review-actions.el --- Commands that change a PR, MR or issue -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The write side, shared by the detail and diff buffers: add a comment, reply
;; to a thread, submit a review (comment, approve, request changes), merge,
;; close or reopen, check out.  Each takes a DONE function that the caller uses
;; to refresh its buffer.  Anything that changes the remote asks first, and
;; names the repository and number in the question so you never confirm
;; blindly.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-compose)
(require 'ez-review-drafts)

(declare-function magit-refresh "magit-mode")
(declare-function magit-anything-modified-p "magit-git")

(defcustom ez-review-confirm-writes t
  "Non-nil: ask before sending a review, merging, closing or reopening."
  :type 'boolean
  :group 'ez-review)

(defun ez-review-actions--target (forge what number)
  "Human description of item NUMBER, for prompts."
  (format "%s #%d in %s/%s" (if (eq what 'pr) (ez-review-forge-noun forge) "issue")
          number (ez-review-forge-host forge) (ez-review-forge-path forge)))

(defun ez-review-actions--confirm (prompt)
  (or (not ez-review-confirm-writes) (y-or-n-p prompt)))

(defun ez-review-actions--result (done what)
  "A callback that reports failure, or says WHAT happened and calls DONE."
  (lambda (result)
    (if (stringp result)
        (message "ez-review: %s" result)
      (message "%s" what)
      (when done (funcall done)))))

;;;###autoload
(defun ez-review-actions-comment (forge what number done &optional people)
  "Compose and send a general comment on item NUMBER.
PEOPLE (a list, or a function returning one) are offered first after `@'."
  (ez-review-compose
   (format "comment on #%d" number) ""
   (lambda (text)
     (message "Sending comment…")
     (ez-review-forge-comment forge what number text
                              (ez-review-actions--result done "Comment posted")))
   :header "Comment —"
   :mentions (ez-review-forge-mention-function forge people)))

(defun ez-review-actions-reply (forge number comment done &optional people)
  "Compose and send a reply to inline COMMENT of PR NUMBER.
PEOPLE are offered first after `@'."
  (ez-review-compose
   (format "reply to %s" (or (ez-review-comment-author comment) "comment")) ""
   (lambda (text)
     (message "Sending reply…")
     (ez-review-forge-reply forge number comment text
                            (ez-review-actions--result done "Reply posted")))
   :header "Reply —"
   :mentions (ez-review-forge-mention-function forge people)))

(defun ez-review-actions--events (forge)
  "Review verdicts offered for FORGE as an alist of (LABEL . EVENT)."
  (append '(("Comment" . comment) ("Approve" . approve))
          (unless (eq (ez-review-forge-kind forge) 'gitlab)
            '(("Request changes" . request-changes)))))

;;;###autoload
(defun ez-review-actions-submit (forge number done &optional people)
  "Send the pending comments of PR NUMBER as one review with a verdict.
PEOPLE are offered first after `@' in the summary."
  (let* ((drafts (ez-review-drafts-load forge number))
         (events (ez-review-actions--events forge))
         (choice (completing-read
                  (format "Submit review (%d pending %s): " (length drafts)
                          (if (= 1 (length drafts)) "comment" "comments"))
                  (mapcar #'car events) nil t))
         (event (cdr (assoc choice events))))
    (ez-review-compose
     (format "review summary #%d" number)
     ""
     (lambda (text)
       (let ((body (and (not (string-empty-p text)) text)))
         (when (and (null drafts) (null body) (eq event 'comment))
           (user-error "Nothing to submit: no pending comments and no summary"))
         (when (ez-review-actions--confirm
                (format "%s on %s with %d inline %s? "
                        choice (ez-review-actions--target forge 'pr number) (length drafts)
                        (if (= 1 (length drafts)) "comment" "comments")))
           (let ((hook (lambda (d) (ez-review-drafts-remove forge number d))))
             (add-hook 'ez-review-forge-draft-posted-hook hook)
             (message "Submitting review…")
             (ez-review-forge-submit-review
              forge number event body drafts
              (lambda (result)
                (remove-hook 'ez-review-forge-draft-posted-hook hook)
                (if (stringp result)
                    (message "ez-review: %s" result)
                  (ez-review-drafts-save forge number nil)
                  (message "Review submitted: %s" choice)
                  (when done (funcall done)))))))))
     :header (format "Summary for \"%s\" (optional) —" choice)
     :allow-empty t
     :mentions (ez-review-forge-mention-function forge people))))

(defun ez-review-actions-post-inline (forge number draft done)
  "Post inline DRAFT on PR NUMBER right now, as a single comment and not a review."
  (when (ez-review-actions--confirm
         (format "Post this comment on %s:%d now, without a review, on %s? "
                 (ez-review-draft-path draft) (ez-review-draft-line draft)
                 (ez-review-actions--target forge 'pr number)))
    (message "Posting comment…")
    (ez-review-forge-post-inline forge number draft
                                 (ez-review-actions--result done "Comment posted"))))

;;;###autoload
(defun ez-review-actions-merge (forge number done)
  "Merge PR NUMBER after choosing how."
  (let* ((method (intern (completing-read "Merge method: " '("merge" "squash" "rebase") nil t nil nil "merge")))
         (delete (y-or-n-p "Delete the source branch afterwards? ")))
    (when (ez-review-actions--confirm
           (format "Merge (%s) %s? " method (ez-review-actions--target forge 'pr number)))
      (message "Merging…")
      (ez-review-forge-merge forge number method delete
                             (ez-review-actions--result done "Merged")))))

;;;###autoload
(defun ez-review-actions-set-state (forge what number state done)
  "Close or reopen item NUMBER (STATE is `closed' or `open')."
  (when (ez-review-actions--confirm
         (format "%s %s? " (if (eq state 'closed) "Close" "Reopen")
                 (ez-review-actions--target forge what number)))
    (ez-review-forge-set-state forge what number state
                               (ez-review-actions--result done (if (eq state 'closed) "Closed" "Reopened")))))

;;;###autoload
(defun ez-review-actions-checkout (forge number)
  "Check out PR NUMBER, then refresh Magit."
  (when (and (fboundp 'magit-anything-modified-p)
             (let ((default-directory (ez-review-forge-dir forge)))
               (ignore-errors (magit-anything-modified-p)))
             (not (y-or-n-p "Working tree has uncommitted changes; check out anyway? ")))
    (user-error "Checkout cancelled"))
  (message "Checking out %s #%d…" (ez-review-forge-noun forge) number)
  (ez-review-forge-checkout
   forge number
   (lambda (result)
     (if (stringp result)
         (message "ez-review: %s" result)
       (message "Checked out %s #%d" (ez-review-forge-noun forge) number)
       (when (fboundp 'magit-refresh)
         (let ((default-directory (ez-review-forge-dir forge)))
           (ignore-errors (magit-refresh))))))))

(provide 'ez-review-actions)
;;; ez-review-actions.el ends here
