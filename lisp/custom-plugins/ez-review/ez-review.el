;;; ez-review.el --- Review GitHub PRs and GitLab MRs from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ezechukwu Ojukwu

;; Author: Ezechukwu Ojukwu <ezechukwu69@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.5.0") (magit-section "4.0.0"))
;; Keywords: tools, vc
;; URL: https://github.com/ezechukwu69/ez-review
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Review GitHub pull requests, GitLab merge requests and issues of the
;; current repository, using the `gh' and `glab' command line tools.  Their
;; stored credentials are used; nothing here reads or keeps a token.
;; Self-hosted GitLab and GitHub Enterprise hosts work too.
;;
;;   - list, view, check out, create, merge, close and reopen PRs/MRs
;;   - list, view, create, comment on, close and reopen issues
;;   - a diff review buffer with existing threads in place; write inline
;;     comments, keep them as pending drafts, then submit one review
;;     (comment, approve or request changes)
;;   - log in and out of both platforms
;;   - Magit: a key in `magit-dispatch' and an optional status section
;;
;; Entry point: `ez-review-dispatch'.  Bind it, or `ez-review-map', yourself:
;;
;;   (keymap-global-set "C-c r" ez-review-map)

;;; Code:

(require 'transient)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-auth)
(require 'ez-review-list)
(require 'ez-review-view)
(require 'ez-review-diff)
(require 'ez-review-create)
(require 'ez-review-magit)

;;;###autoload
(defun ez-review-list-mine ()
  "List the PRs or MRs authored by you."
  (interactive)
  (ez-review-list 'pr 'mine))

;;;###autoload
(defun ez-review-list-requested ()
  "List the PRs or MRs awaiting your review."
  (interactive)
  (ez-review-list 'pr 'review))

;;;###autoload
(defun ez-review-list-closed ()
  "List closed PRs or MRs, merged ones included."
  (interactive)
  (ez-review-list 'pr 'all 'closed))

;;;###autoload
(defun ez-review-checkout (number)
  "Check out PR (MR) NUMBER of the current repository."
  (interactive (list (read-number "PR/MR number: ")))
  (ez-review-actions-checkout (ez-review-forge-current) number))

;;;###autoload
(defun ez-review-view-pr (number)
  "Open PR (MR) NUMBER of the current repository."
  (interactive (list (read-number "PR/MR number: ")))
  (ez-review-view (ez-review-forge-current) 'pr number))

;;;###autoload
(defun ez-review-view-issue (number)
  "Open issue NUMBER of the current repository."
  (interactive (list (read-number "Issue number: ")))
  (ez-review-view (ez-review-forge-current) 'issue number))

;;;###autoload
(defun ez-review-diff (number)
  "Review the diff of PR (MR) NUMBER of the current repository."
  (interactive (list (read-number "PR/MR number: ")))
  (ez-review-diff-open (ez-review-forge-current) number))

;;;###autoload (autoload 'ez-review-dispatch "ez-review" nil t)
(transient-define-prefix ez-review-dispatch ()
  "Review pull requests, merge requests and issues."
  [["Pull / merge requests"
    ("l" "List" ez-review-list)
    ("m" "Mine" ez-review-list-mine)
    ("r" "Awaiting my review" ez-review-list-requested)
    ("x" "Closed / merged" ez-review-list-closed)
    ("v" "Open by number" ez-review-view-pr)
    ("d" "Review diff by number" ez-review-diff)
    ("c" "Check out by number" ez-review-checkout)
    ("n" "New from this branch" ez-review-create-pr)]
   ["Issues"
    ("i" "List" ez-review-list-issues)
    ("I" "Open by number" ez-review-view-issue)
    ("N" "New issue" ez-review-create-issue)]
   ["Accounts"
    ("a" "Auth status" ez-review-auth-status)
    ("L" "Log in" ez-review-auth-login)
    ("X" "Log out" ez-review-auth-logout)]])

;;;###autoload
(defvar ez-review-map
  (let ((map (make-sparse-keymap)))
    (define-key map "d" #'ez-review-dispatch)
    (define-key map "l" #'ez-review-list)
    (define-key map "m" #'ez-review-list-mine)
    (define-key map "r" #'ez-review-list-requested)
    (define-key map "x" #'ez-review-list-closed)
    (define-key map "i" #'ez-review-list-issues)
    (define-key map "n" #'ez-review-create-pr)
    (define-key map "a" #'ez-review-auth-status)
    map)
  "Prefix keymap for ez-review.  Bind it to a key of your choice.")

(provide 'ez-review)
;;; ez-review.el ends here
