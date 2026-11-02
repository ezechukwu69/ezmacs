;;; my-vc-review.el --- PR/MR and issue review (ez-review)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; ez-review lives in lisp/custom-plugins/ez-review/, inside `user-lisp-directory':
;; it is already on `load-path' and its autoloads are scraped, so nothing needs
;; requiring here.  This file only holds what is specific to this config: keys,
;; Evil, hosts, Magit.  Keep it that way so the package stays movable.

(declare-function my/leader "my-keys-leader")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")

;;;; Hosts

;; Self-hosted GitLab, so ez-review skips the "which CLI is logged in?" probe.
(with-eval-after-load 'ez-review-forge
  (add-to-list 'ez-review-host-alist '("labhub.softalliance.com" . gitlab)))

;;;; Magit

;; Adds `@' to magit-dispatch.
(with-eval-after-load 'magit (require 'ez-review-magit))

;; PRs/MRs awaiting your review, listed in the magit-status buffer.  Costs one
;; `gh'/`glab' call per status refresh (cached for two minutes), so it is opt-in:
;; (setq ez-review-magit-status-section t)

;;;; Keys

;; SPC g r is taken by diff-hl (revert hunk), so the review prefix is SPC g R.
(my/leader
  "gR" '(:ignore t :wk "review")
  "gRr" '(ez-review-dispatch :wk "review menu")
  "gRl" '(ez-review-list :wk "list PRs/MRs")
  "gRm" '(ez-review-list-mine :wk "my PRs/MRs")
  "gRq" '(ez-review-list-requested :wk "awaiting my review")
  "gRx" '(ez-review-list-closed :wk "closed/merged PRs")
  "gRi" '(ez-review-list-issues :wk "issues")
  "gRn" '(ez-review-create-pr :wk "new PR/MR from branch")
  "gRN" '(ez-review-create-issue :wk "new issue")
  "gRd" '(ez-review-diff :wk "review diff by number")
  "gRa" '(ez-review-auth-status :wk "auth status"))

;;;; Evil

;; Review buffers are keyed with plain letters (c comment, d diff, r reply...).
;; In Evil's normal state those are operators, so the buffers start in motion
;; state (j/k/gg/G/search still work) and the package's keys are re-bound there,
;; which puts them above Evil's own motion keys such as m, e, ? and [ ].
(defun my/review--evilify (map)
  "Bind the keys of MAP, and of its parents, in Evil motion state."
  (let (maps)
    (let ((m map))
      (while (keymapp m) (push m maps) (setq m (keymap-parent m))))
    (dolist (m maps)                    ; parents first, so MAP's own keys win
      (let ((copy (copy-keymap m)))
        (set-keymap-parent copy nil)
        (map-keymap (lambda (event def)
                      (when (and (commandp def) (or (characterp event) (symbolp event)))
                        (evil-define-key* 'motion map (vector event) def)))
                    copy)))))

(with-eval-after-load 'evil
  (dolist (mode '(ez-review-list-mode ez-review-view-mode ez-review-diff-mode))
    (evil-set-initial-state mode 'motion))
  ;; Compose buffers are for typing.
  (evil-set-initial-state 'ez-review-compose-mode 'insert))

(defun my/review--visual-keys (map)
  "In the diff buffer, a visual selection can be commented on or suggested for."
  (evil-define-key* 'visual map
    "c" #'ez-review-diff-comment
    "s" #'ez-review-diff-suggest))

(with-eval-after-load 'ez-review-diff
  (with-eval-after-load 'evil
    (my/review--visual-keys ez-review-diff-mode-map)))

(dolist (spec '((ez-review-list . ez-review-list-mode-map)
                (ez-review-view . ez-review-view-mode-map)
                (ez-review-diff . ez-review-diff-mode-map)))
  (let ((map (cdr spec)))
    (with-eval-after-load (car spec)
      (with-eval-after-load 'evil
        (my/review--evilify (symbol-value map))))))

(provide 'my-vc-review)
