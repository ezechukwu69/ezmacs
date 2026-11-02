;;; ez-review-list.el --- List PRs, MRs and issues -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One buffer with two tabs, Pull requests (Merge requests on GitLab) and
;; Issues, each a `magit-section' list with colored status icons, label chips
;; and right-aligned metadata.  Keys:
;;
;;   1 / 2  switch tab        s  cycle state (open, closed, merged, all)
;;   O C M A  show open / closed (merged included) / merged / all
;;   a m r  all / mine / awaiting my review     g  refresh
;;   > load more (lists are fetched ``ez-review-list-limit'' at a time)
;;   RET view   d diff   c check out   x close/reopen   o browser   + new

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'magit-section)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-github)
(require 'ez-review-gitlab)
(require 'ez-review-ui)
(require 'ez-review-actions)

(declare-function ez-review-view "ez-review-view")
(declare-function ez-review-diff-open "ez-review-diff")
(declare-function ez-review-create-pr "ez-review-create")
(declare-function ez-review-create-issue "ez-review-create")

(defvar-local ez-review-list--forge nil "Forge shown in this buffer.")
(defvar-local ez-review-list--what 'pr "Active tab: `pr' or `issue'.")
(defvar-local ez-review-list--filter 'all "One of `all', `mine', `review'.")
(defvar-local ez-review-list--state 'open "One of `open', `closed', `merged', `all'.")
(defvar-local ez-review-list--items nil "Items of the active tab.")
(defvar-local ez-review-list--counts nil "Plist of counts per tab, once loaded.")
(defvar-local ez-review-list--loading nil)
(defvar-local ez-review-list--limit nil "How many items the last fetch asked for.")

(defvar-keymap ez-review-list-mode-map
  :doc "Keymap for `ez-review-list-mode'."
  :parent magit-section-mode-map
  "RET" #'ez-review-list-view
  "d" #'ez-review-list-diff
  "c" #'ez-review-list-checkout
  "x" #'ez-review-list-toggle-state
  "o" #'ez-review-list-browse
  "+" #'ez-review-list-new
  "g" #'ez-review-list-refresh
  ">" #'ez-review-list-more
  "s" #'ez-review-list-cycle-state
  "O" #'ez-review-list-state-open
  "C" #'ez-review-list-state-closed
  "M" #'ez-review-list-state-merged
  "A" #'ez-review-list-state-all
  "1" #'ez-review-list-show-prs
  "2" #'ez-review-list-show-issues
  "a" #'ez-review-list-show-all
  "m" #'ez-review-list-show-mine
  "r" #'ez-review-list-show-review
  "?" #'ez-review-list-menu)

(define-derived-mode ez-review-list-mode magit-section-mode "Review"
  "Major mode listing PRs, MRs and issues."
  (ez-review-ui-keep-faces)
  (setq-local truncate-lines t)
  (setq-local header-line-format '(:eval (ez-review-list--header))))

;;;; Header and rows

(defun ez-review-list--header ()
  (let ((forge ez-review-list--forge))
    (concat
     " "
     (ez-review-ui-tabs
      `((pr ,(if forge (if (eq (ez-review-forge-kind forge) 'gitlab) "Merge requests" "Pull requests") "Pull requests")
            ,(plist-get ez-review-list--counts :pr))
        (issue "Issues" ,(plist-get ez-review-list--counts :issue)))
      ez-review-list--what)
     "   "
     (mapconcat
      (lambda (st)
        (propertize (format " %s " (car st))
                    'face (if (eq (cdr st) ez-review-list--state) 'ez-review-tab-active 'ez-review-meta)))
      (append '(("open" . open) ("closed" . closed))
              (when (eq ez-review-list--what 'pr) '(("merged" . merged)))
              '(("all" . all)))
      "")
     (propertize (format "  · %s%s" ez-review-list--filter (if ez-review-list--loading "  loading…" ""))
                 'face 'ez-review-meta)
     (if (and ez-review-list--limit (not ez-review-list--loading)
              (>= (length ez-review-list--items) ez-review-list--limit))
         (propertize (format "  · first %d, > for more" ez-review-list--limit) 'face 'ez-review-wait)
       "")
     (propertize "   ? keys" 'face 'ez-review-meta))))

(defun ez-review-list--pr-row (pr)
  (let* ((left (concat (ez-review-ui-state-icon pr) " "
                       (propertize (format "#%-4d" (ez-review-pr-number pr)) 'face 'ez-review-number) " "
                       (propertize (ez-review-pr-title pr) 'face 'ez-review-title)
                       (if (ez-review-pr-labels pr) (concat "  " (ez-review-ui-labels (ez-review-pr-labels pr))) "")))
         (right (concat (propertize (format "%s → %s" (ez-review-pr-head pr) (ez-review-pr-base pr)) 'face 'ez-review-meta)
                        (propertize (format "  @%s  %s" (ez-review-pr-author pr)
                                            (or (ez-review-ui-reltime (ez-review-pr-updated pr)) ""))
                                    'face 'ez-review-meta)
                        (let ((d (ez-review-ui-decision (ez-review-pr-decision pr))))
                          (if (string-empty-p d) "" (concat "  " d))))))
    (ez-review-list--fit left right)))

(defun ez-review-list--issue-row (issue)
  (let* ((left (concat (ez-review-ui-state-icon issue) " "
                       (propertize (format "#%-4d" (ez-review-issue-number issue)) 'face 'ez-review-number) " "
                       (propertize (ez-review-issue-title issue) 'face 'ez-review-title)
                       (if (ez-review-issue-labels issue) (concat "  " (ez-review-ui-labels (ez-review-issue-labels issue))) "")))
         (right (concat (propertize (format "@%s  %s" (ez-review-issue-author issue)
                                            (or (ez-review-ui-reltime (ez-review-issue-updated issue)) ""))
                                    'face 'ez-review-meta)
                        (if (ez-review-issue-assignees issue)
                            (propertize (format "  → %s" (string-join (ez-review-issue-assignees issue) ", "))
                                        'face 'ez-review-meta)
                          ""))))
    (ez-review-list--fit left right)))

(defun ez-review-list--fit (left right)
  "LEFT cut to leave room for RIGHT, then RIGHT aligned to the window edge."
  (let ((room (max 20 (- (window-width) (string-width right) 3))))
    (concat (truncate-string-to-width left room nil nil "…") (ez-review-ui-right right))))

(defun ez-review-list--render ()
  (let ((inhibit-read-only t)
        (forge ez-review-list--forge)
        (pos (point)))
    (erase-buffer)
    (magit-insert-section (review-root)
      (insert (propertize (format "%s/%s" (ez-review-forge-host forge) (ez-review-forge-path forge))
                          'face 'ez-review-heading)
              "\n\n")
      (if (null ez-review-list--items)
          (insert (propertize (if ez-review-list--loading "  Loading…\n" "  Nothing here.\n") 'face 'ez-review-meta))
        (dolist (item ez-review-list--items)
          (magit-insert-section (review-item item)
            (insert (if (ez-review-pr-p item) (ez-review-list--pr-row item) (ez-review-list--issue-row item))
                    "\n")))))
    (goto-char (min pos (point-max)))
    (when (= pos (point-min)) (forward-line 2))))

;;;; Fetching

(defun ez-review-list--fetch (buffer)
  (with-current-buffer buffer
    (let ((what ez-review-list--what))
      (setq ez-review-list--loading t)
      (force-mode-line-update)
      (unless ez-review-list--limit (setq ez-review-list--limit ez-review-list-limit))
      (ez-review-forge-list
       ez-review-list--forge what
       (list :filter ez-review-list--filter :state ez-review-list--state :limit ez-review-list--limit)
       (lambda (result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq ez-review-list--loading nil)
             (if (stringp result)
                 (progn (message "ez-review: %s" result)
                        (ez-review-list--render))
               (when (eq what ez-review-list--what)
                 (setq ez-review-list--items result))
               (setq ez-review-list--counts (plist-put ez-review-list--counts what (length result)))
               (ez-review-list--render))
             (force-mode-line-update))))))))

(defun ez-review-list--item ()
  "The item at point, or a user error."
  (or (magit-section-value-if 'review-item) (user-error "Nothing at point")))

(defun ez-review-list--number (item)
  (if (ez-review-pr-p item) (ez-review-pr-number item) (ez-review-issue-number item)))

;;;; Commands

;;;###autoload
(defun ez-review-list (&optional what filter state)
  "List the PRs (or MRs) of the current repository.
WHAT is `pr' (default) or `issue'; FILTER is `all', `mine' or `review'; STATE
is `open' (default), `closed' (merged included), `merged' or `all'."
  (interactive)
  (let* ((forge (ez-review-forge-current))
         (buf (get-buffer-create (format "*ez-review: %s*" (ez-review-forge-path forge)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-review-list-mode) (ez-review-list-mode))
      (setq ez-review-list--forge forge
            ez-review-list--what (or what 'pr)
            ez-review-list--filter (or filter 'all)
            ez-review-list--state (or state 'open)
            ez-review-list--items nil)
      (ez-review-list--render)
      (ez-review-list--fetch buf))
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun ez-review-list-issues (&optional filter)
  "List the issues of the current repository."
  (interactive)
  (ez-review-list 'issue filter))

(defun ez-review-list--switch (&optional what filter state)
  (when what (setq ez-review-list--what what))
  (when filter (setq ez-review-list--filter filter))
  (when state (setq ez-review-list--state state))
  (when (and (eq ez-review-list--what 'issue) (eq ez-review-list--state 'merged))
    (setq ez-review-list--state 'open))
  (setq ez-review-list--items nil
        ez-review-list--limit ez-review-list-limit)
  (ez-review-list--render)
  (ez-review-list--fetch (current-buffer)))

(defun ez-review-list-show-prs () "Show pull requests." (interactive) (ez-review-list--switch 'pr))
(defun ez-review-list-show-issues () "Show issues." (interactive) (ez-review-list--switch 'issue))
(defun ez-review-list-show-all () "Show everyone's." (interactive) (ez-review-list--switch nil 'all))
(defun ez-review-list-show-mine () "Show only yours." (interactive) (ez-review-list--switch nil 'mine))
(defun ez-review-list-show-review () "Show those awaiting your review (or assigned to you)."
  (interactive) (ez-review-list--switch nil 'review))

(defun ez-review-list-cycle-state ()
  "Cycle open → closed → merged → all."
  (interactive)
  (let ((order (if (eq ez-review-list--what 'pr) '(open closed merged all) '(open closed all))))
    (ez-review-list--switch nil nil
                            (or (cadr (memq ez-review-list--state order)) (car order)))))

(defun ez-review-list--set-state (state)
  (ez-review-list--switch nil nil state))

(defun ez-review-list-state-open () "Show open items." (interactive) (ez-review-list--set-state 'open))
(defun ez-review-list-state-closed ()
  "Show closed items (merged PRs included)."
  (interactive) (ez-review-list--set-state 'closed))
(defun ez-review-list-state-merged () "Show merged PRs." (interactive)
  (if (eq ez-review-list--what 'pr) (ez-review-list--set-state 'merged) (user-error "Issues are not merged")))
(defun ez-review-list-state-all () "Show items in every state." (interactive) (ez-review-list--set-state 'all))

(defun ez-review-list-more ()
  "Fetch another page of items."
  (interactive)
  (setq ez-review-list--limit (+ (or ez-review-list--limit ez-review-list-limit) ez-review-list-limit))
  (ez-review-list--fetch (current-buffer)))

(defun ez-review-list-refresh ()
  "Refetch the list."
  (interactive)
  (ez-review-list--fetch (current-buffer)))

(defun ez-review-list-view ()
  "Open the item at point."
  (interactive)
  (ez-review-view ez-review-list--forge ez-review-list--what
                  (ez-review-list--number (ez-review-list--item))))

(defun ez-review-list-diff ()
  "Review the diff of the PR at point."
  (interactive)
  (let ((item (ez-review-list--item)))
    (unless (ez-review-pr-p item) (user-error "Issues have no diff"))
    (ez-review-diff-open ez-review-list--forge (ez-review-pr-number item))))

(defun ez-review-list-checkout ()
  "Check out the PR at point."
  (interactive)
  (let ((item (ez-review-list--item)))
    (unless (ez-review-pr-p item) (user-error "Only pull requests can be checked out"))
    (ez-review-actions-checkout ez-review-list--forge (ez-review-pr-number item))))

(defun ez-review-list-toggle-state ()
  "Close the open item at point, or reopen a closed one."
  (interactive)
  (let* ((item (ez-review-list--item))
         (state (if (ez-review-pr-p item) (ez-review-pr-state item) (ez-review-issue-state item)))
         (buffer (current-buffer)))
    (when (equal state "merged") (user-error "Already merged"))
    (ez-review-actions-set-state
     ez-review-list--forge ez-review-list--what (ez-review-list--number item)
     (if (equal state "open") 'closed 'open)
     (lambda () (when (buffer-live-p buffer) (ez-review-list--fetch buffer))))))

(defun ez-review-list-browse ()
  "Open the item at point in the browser."
  (interactive)
  (ez-review-forge-browse ez-review-list--forge ez-review-list--what
                          (ez-review-list--number (ez-review-list--item))))

(defun ez-review-list-new ()
  "Create a PR/MR or an issue, depending on the active tab."
  (interactive)
  (if (eq ez-review-list--what 'pr)
      (ez-review-create-pr ez-review-list--forge)
    (ez-review-create-issue ez-review-list--forge)))

(transient-define-prefix ez-review-list-menu ()
  "Actions in the list buffer."
  [["Show"
    ("1" "Pull / merge requests" ez-review-list-show-prs)
    ("2" "Issues" ez-review-list-show-issues)
    ("a" "Everyone's" ez-review-list-show-all)
    ("m" "Mine" ez-review-list-show-mine)
    ("r" "Awaiting my review" ez-review-list-show-review)
    ("s" "Cycle state" ez-review-list-cycle-state :transient t)]
   ["State"
    ("O" "Open" ez-review-list-state-open)
    ("C" "Closed (incl. merged)" ez-review-list-state-closed)
    ("M" "Merged" ez-review-list-state-merged)
    ("A" "All" ez-review-list-state-all)]
   ["Item"
    ("RET" "Open" ez-review-list-view)
    ("d" "Review diff" ez-review-list-diff)
    ("c" "Check out" ez-review-list-checkout)
    ("x" "Close / reopen" ez-review-list-toggle-state)
    ("o" "Browser" ez-review-list-browse)]
   ["Create"
    ("+" "New for this tab" ez-review-list-new)
    (">" "Load more" ez-review-list-more)
    ("g" "Refresh" ez-review-list-refresh)]])

(provide 'ez-review-list)
;;; ez-review-list.el ends here
