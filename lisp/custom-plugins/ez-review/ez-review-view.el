;;; ez-review-view.el --- Detail page for a PR, MR or issue -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A single page with the header card (status, branches, labels, checks,
;; reviewers), the description, and the conversation: comments and review
;; verdicts as cards.  Inline review comments are summarised here and shown in
;; place in the diff (`d').  Keys:
;;
;;   d diff   c comment   S submit review   a approve   M merge   C check out
;;   x close/reopen   o browser   g refresh   ? menu

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'magit-section)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-ui)
(require 'ez-review-drafts)
(require 'ez-review-actions)

(declare-function ez-review-diff-open "ez-review-diff")

(defvar-local ez-review-view--forge nil)
(defvar-local ez-review-view--what nil)
(defvar-local ez-review-view--number nil)
(defvar-local ez-review-view--item nil)
(defvar-local ez-review-view--timeline nil)
(defvar-local ez-review-view--commits nil)

(defvar-keymap ez-review-view-mode-map
  :doc "Keymap for `ez-review-view-mode'."
  :parent magit-section-mode-map
  "d" #'ez-review-view-diff
  "RET" #'ez-review-view-visit
  "c" #'ez-review-view-comment
  "S" #'ez-review-view-submit
  "a" #'ez-review-view-approve
  "M" #'ez-review-view-merge
  "C" #'ez-review-view-checkout
  "x" #'ez-review-view-toggle-state
  "o" #'ez-review-view-browse
  "g" #'ez-review-view-refresh
  "?" #'ez-review-view-menu)

(define-derived-mode ez-review-view-mode magit-section-mode "Review-Item"
  "Major mode showing one PR, MR or issue."
  (ez-review-ui-keep-faces)
  (setq-local revert-buffer-function (lambda (&rest _) (ez-review-view-refresh))))

(defun ez-review-view--pr-p () (eq ez-review-view--what 'pr))

;;;; Rendering

(defun ez-review-view--insert-checks (pr)
  (let ((checks (ez-review-pr-checks pr)))
    (when checks
      (let ((summary (ez-review-ui-checks-summary checks)))
        (magit-insert-section (review-checks nil (eq summary 'success))
          (magit-insert-heading
            (ez-review-ui-check-icon summary) " "
            (propertize "Checks" 'face 'ez-review-heading)
            (propertize (format "  %d/%d passing"
                                (cl-count 'success checks :key #'cdr) (length checks))
                        'face 'ez-review-meta))
          (dolist (c checks)
            (insert "  " (ez-review-ui-check-icon (cdr c)) " " (car c) "\n"))
          (insert "\n"))))))

(defun ez-review-view--insert-header (item)
  (let ((pr (ez-review-pr-p item)))
    (insert (ez-review-ui-state-chip item) "  "
            (propertize (format "#%d %s" (if pr (ez-review-pr-number item) (ez-review-issue-number item))
                                (if pr (ez-review-pr-title item) (ez-review-issue-title item)))
                        'face 'ez-review-heading)
            "\n")
    (if pr
        (insert (propertize (format "@%s wants to merge " (ez-review-pr-author item)) 'face 'ez-review-meta)
                (propertize (ez-review-pr-head item) 'face 'font-lock-constant-face)
                (propertize " into " 'face 'ez-review-meta)
                (propertize (ez-review-pr-base item) 'face 'font-lock-constant-face)
                (propertize (format " · %s" (or (ez-review-ui-reltime (ez-review-pr-created item)) ""))
                            'face 'ez-review-meta)
                "\n")
      (insert (propertize (format "opened by @%s · %s" (ez-review-issue-author item)
                                  (or (ez-review-ui-reltime (ez-review-issue-created item)) ""))
                          'face 'ez-review-meta)
              "\n"))
    (let ((labels (if pr (ez-review-pr-labels item) (ez-review-issue-labels item))))
      (when labels (insert "\n" (ez-review-ui-labels labels) "\n")))
    (insert "\n")
    (if pr
        (progn
          (when (or (ez-review-pr-additions item) (ez-review-pr-files item))
            (insert (propertize "Changes     " 'face 'ez-review-meta)
                    (if (ez-review-pr-files item) (format "%d files  " (ez-review-pr-files item)) "")
                    (if (ez-review-pr-additions item)
                        (concat (propertize (format "+%d" (ez-review-pr-additions item)) 'face 'ez-review-ok) " "
                                (propertize (format "−%d" (ez-review-pr-deletions item)) 'face 'ez-review-fail))
                      "")
                    "\n"))
          (when (ez-review-pr-reviewers item)
            (insert (propertize "Reviewers   " 'face 'ez-review-meta)
                    (mapconcat (lambda (r) (propertize (concat "@" r) 'face 'ez-review-author))
                               (ez-review-pr-reviewers item) ", ")
                    "\n"))
          (let ((d (ez-review-ui-decision (ez-review-pr-decision item))))
            (unless (string-empty-p d) (insert (propertize "Review      " 'face 'ez-review-meta) d "\n")))
          (when (ez-review-pr-mergeable item)
            (insert (propertize "Mergeable   " 'face 'ez-review-meta) (ez-review-pr-mergeable item) "\n"))
          (let ((n (ez-review-drafts-count ez-review-view--forge ez-review-view--number)))
            (when (> n 0)
              (insert (propertize "Pending     " 'face 'ez-review-meta)
                      (ez-review-ui-chip (format "%d unsent comments" n) 'ez-review-chip-pending)
                      (propertize "  d then S to submit" 'face 'ez-review-meta) "\n")))
          (insert "\n"))
      (when (ez-review-issue-assignees item)
        (insert (propertize "Assignees   " 'face 'ez-review-meta)
                (mapconcat (lambda (a) (propertize (concat "@" a) 'face 'ez-review-author))
                           (ez-review-issue-assignees item) ", ")
                "\n\n")))))

(defun ez-review-view--insert-commits ()
  (when ez-review-view--commits
    (let ((n (length ez-review-view--commits)))
      (magit-insert-section (review-commits nil (> n 12))
        (magit-insert-heading
          (propertize "Commits" 'face 'ez-review-heading)
          (propertize (format "  %d   RET opens a commit's diff" n) 'face 'ez-review-meta))
        (dolist (c ez-review-view--commits)
          (magit-insert-section (review-commit c)
            (insert "  "
                    (propertize (substring (ez-review-commit-sha c) 0 (min 7 (length (ez-review-commit-sha c))))
                                'face 'ez-review-number)
                    "  " (propertize (or (ez-review-commit-subject c) "") 'face 'ez-review-title)
                    (propertize (format "  %s · %s" (or (ez-review-commit-author c) "")
                                        (or (ez-review-ui-reltime (ez-review-commit-date c)) ""))
                                'face 'ez-review-meta)
                    "\n")))
        (insert "\n")))))

(defun ez-review-view--insert-timeline ()
  (let* ((all ez-review-view--timeline)
         (inline (cl-remove-if-not (lambda (c) (eq (ez-review-comment-kind c) 'inline)) all))
         (shown (cl-remove-if (lambda (c) (eq (ez-review-comment-kind c) 'inline)) all)))
    (magit-insert-section (review-conversation)
      (magit-insert-heading
        (propertize "Conversation" 'face 'ez-review-heading)
        (propertize (format "  %d" (length shown)) 'face 'ez-review-meta))
      (if (and (null shown) (null inline))
          (insert (propertize "  No comments yet.\n" 'face 'ez-review-meta))
        (dolist (c shown)
          (let ((start (point)))
            (insert (ez-review-ui-card (ez-review-ui-comment-header c) (ez-review-comment-body c)
                                       :indent 0
                                       :chip (ez-review-ui-comment-chip c)
                                       :bar (if (eq (ez-review-comment-kind c) 'review)
                                                'ez-review-card-bar-review 'ez-review-card-bar))
                    "\n")
            (put-text-property start (point) 'ez-review-comment c)))
        (when inline
          (insert (propertize (format "%s %d inline review %s — press d to read them in the diff\n"
                                      (ez-review-ui-icon 'comment) (length inline)
                                      (if (= 1 (length inline)) "comment" "comments"))
                              'face 'ez-review-meta)))))))

(defun ez-review-view--render ()
  (let ((inhibit-read-only t)
        (item ez-review-view--item)
        (pos (point)))
    (erase-buffer)
    (magit-insert-section (review-page)
      (ez-review-view--insert-header item)
      (when (ez-review-pr-p item) (ez-review-view--insert-checks item))
      (let ((body (if (ez-review-pr-p item) (ez-review-pr-body item) (ez-review-issue-body item))))
        (magit-insert-section (review-description)
          (magit-insert-heading (propertize "Description" 'face 'ez-review-heading))
          (insert (if (string-empty-p (string-trim (or body "")))
                      (propertize "  No description provided.\n" 'face 'ez-review-meta)
                    (ez-review-ui-card "" body :indent 0))
                  "\n")))
      (when (ez-review-pr-p item) (ez-review-view--insert-commits))
      (ez-review-view--insert-timeline))
    (goto-char (min pos (point-max)))))

;;;; Fetching

(defun ez-review-view--fetch (buffer)
  (with-current-buffer buffer
    (let ((forge ez-review-view--forge) (what ez-review-view--what) (n ez-review-view--number))
      (message "Fetching #%d…" n)
      (ez-review-process-gather
       (list (lambda (cb) (ez-review-forge-view forge what n cb))
             (lambda (cb) (ez-review-forge-timeline forge what n cb))
             (lambda (cb) (if (eq what 'pr) (ez-review-forge-commits forge n cb) (funcall cb nil))))
       (lambda (results)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if (stringp results)
                 (message "ez-review: %s" results)
               (setq ez-review-view--item (nth 0 results)
                     ez-review-view--timeline (nth 1 results)
                     ez-review-view--commits (nth 2 results))
               (ez-review-view--render)
               (message "")))))))))

;;;###autoload
(defun ez-review-view (forge what number)
  "Show item NUMBER of kind WHAT (`pr' or `issue') of FORGE."
  (interactive (let ((forge (ez-review-forge-current)))
                 (list forge
                       (intern (completing-read "Kind: " '("pr" "issue") nil t nil nil "pr"))
                       (read-number "Number: "))))
  (let ((buf (get-buffer-create (format "*ez-review %s: %s #%d*" (if (eq what 'pr) "pr" "issue")
                                        (ez-review-forge-path forge) number))))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-review-view-mode) (ez-review-view-mode))
      (setq ez-review-view--forge forge ez-review-view--what what ez-review-view--number number))
    (pop-to-buffer-same-window buf)
    (ez-review-view--fetch buf)))

;;;; Commands

(defun ez-review-view-refresh ()
  "Refetch this page."
  (interactive)
  (ez-review-view--fetch (current-buffer)))

(defun ez-review-view--people ()
  "Users involved in this item, for @-completion."
  (let ((item ez-review-view--item))
    (cl-delete-duplicates
     (delq nil (append (list (if (ez-review-pr-p item) (ez-review-pr-author item) (and item (ez-review-issue-author item))))
                       (if (ez-review-pr-p item) (ez-review-pr-reviewers item) (and item (ez-review-issue-assignees item)))
                       (mapcar #'ez-review-comment-author ez-review-view--timeline)))
     :test #'equal :from-end t)))

(defun ez-review-view--done ()
  (let ((buffer (current-buffer)))
    (lambda () (when (buffer-live-p buffer) (ez-review-view--fetch buffer)))))

(defun ez-review-view-diff ()
  "Review the diff; on a commit row, review just that commit."
  (interactive)
  (unless (ez-review-view--pr-p) (user-error "Issues have no diff"))
  (ez-review-diff-open ez-review-view--forge ez-review-view--number
                       (magit-section-value-if 'review-commit)))

(defun ez-review-view-visit ()
  "Open the commit at point as a diff."
  (interactive)
  (if-let* ((commit (magit-section-value-if 'review-commit)))
      (ez-review-diff-open ez-review-view--forge ez-review-view--number commit)
    (call-interactively #'magit-section-toggle)))

(defun ez-review-view-comment ()
  "Add a comment."
  (interactive)
  (ez-review-actions-comment ez-review-view--forge ez-review-view--what ez-review-view--number
                             (ez-review-view--done) #'ez-review-view--people))

(defun ez-review-view-submit ()
  "Submit a review with a verdict."
  (interactive)
  (unless (ez-review-view--pr-p) (user-error "Only pull requests have reviews"))
  (ez-review-actions-submit ez-review-view--forge ez-review-view--number (ez-review-view--done)
                            #'ez-review-view--people))

(defun ez-review-view-approve ()
  "Approve (asks for an optional note and confirmation)."
  (interactive)
  (unless (ez-review-view--pr-p) (user-error "Only pull requests can be approved"))
  (ez-review-actions-submit ez-review-view--forge ez-review-view--number (ez-review-view--done)))

(defun ez-review-view-merge ()
  "Merge this PR."
  (interactive)
  (unless (ez-review-view--pr-p) (user-error "Only pull requests can be merged"))
  (ez-review-actions-merge ez-review-view--forge ez-review-view--number (ez-review-view--done)))

(defun ez-review-view-checkout ()
  "Check out this PR."
  (interactive)
  (unless (ez-review-view--pr-p) (user-error "Only pull requests can be checked out"))
  (ez-review-actions-checkout ez-review-view--forge ez-review-view--number))

(defun ez-review-view-toggle-state ()
  "Close this item, or reopen it."
  (interactive)
  (let ((state (if (ez-review-view--pr-p) (ez-review-pr-state ez-review-view--item)
                 (ez-review-issue-state ez-review-view--item))))
    (when (equal state "merged") (user-error "Already merged"))
    (ez-review-actions-set-state ez-review-view--forge ez-review-view--what ez-review-view--number
                                 (if (equal state "open") 'closed 'open) (ez-review-view--done))))

(defun ez-review-view-browse ()
  "Open in the browser."
  (interactive)
  (ez-review-forge-browse ez-review-view--forge ez-review-view--what ez-review-view--number))

(transient-define-prefix ez-review-view-menu ()
  "Actions on this item."
  [["Review"
    ("d" "Review diff" ez-review-view-diff)
    ("S" "Submit review…" ez-review-view-submit)
    ("a" "Approve…" ez-review-view-approve)
    ("M" "Merge…" ez-review-view-merge)
    ("C" "Check out" ez-review-view-checkout)]
   ["Item"
    ("c" "Comment" ez-review-view-comment)
    ("x" "Close / reopen" ez-review-view-toggle-state)
    ("o" "Browser" ez-review-view-browse)
    ("g" "Refresh" ez-review-view-refresh)]])

(provide 'ez-review-view)
;;; ez-review-view.el ends here
