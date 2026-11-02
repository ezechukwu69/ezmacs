;;; ez-review-ui.el --- Shared look and widgets for ez-review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Faces, icons, status chips, label chips, relative times, a light Markdown
;; renderer and comment cards.  Everything the list, detail and diff buffers
;; share lives here so they look like one tool.  Icons use `nerd-icons' when it
;; is installed and fall back to plain Unicode, so nothing here is required.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)

(defcustom ez-review-icons 'auto
  "Whether to draw icons with `nerd-icons'.
`auto' uses them when the package is available; nil always uses Unicode."
  :type '(choice (const :tag "When available" auto) (const :tag "Never" nil))
  :group 'ez-review)

;;;; Faces

(defgroup ez-review-faces nil "Faces for ez-review." :group 'ez-review)

(defmacro ez-review-ui--chip-face (name bg-dark bg-light doc)
  `(defface ,name
     '((((background dark)) :background ,bg-dark :foreground "#ffffff" :weight bold)
       (t :background ,bg-light :foreground "#ffffff" :weight bold))
     ,doc :group 'ez-review-faces))

(ez-review-ui--chip-face ez-review-chip-open "#238636" "#1a7f37" "Open status chip.")
(ez-review-ui--chip-face ez-review-chip-merged "#8957e5" "#8250df" "Merged status chip.")
(ez-review-ui--chip-face ez-review-chip-closed "#da3633" "#cf222e" "Closed status chip.")
(ez-review-ui--chip-face ez-review-chip-draft "#6e7681" "#6e7781" "Draft status chip.")
(ez-review-ui--chip-face ez-review-chip-pending "#bf8700" "#9a6700" "Pending / needs-attention chip.")

(defface ez-review-title '((t :weight bold)) "Item titles." :group 'ez-review-faces)
(defface ez-review-heading '((t :inherit (bold font-lock-keyword-face) :height 1.15)) "Page headings." :group 'ez-review-faces)
(defface ez-review-meta '((t :inherit shadow)) "Secondary text." :group 'ez-review-faces)
(defface ez-review-number '((t :inherit shadow)) "Item numbers." :group 'ez-review-faces)
(defface ez-review-author '((t :inherit font-lock-function-name-face)) "User names." :group 'ez-review-faces)
(defface ez-review-ok '((t :inherit success)) "Passing." :group 'ez-review-faces)
(defface ez-review-fail '((t :inherit error)) "Failing." :group 'ez-review-faces)
(defface ez-review-wait '((t :inherit warning)) "In progress." :group 'ez-review-faces)
(defface ez-review-tab-active
  '((t :inherit (bold) :inverse-video t :box (:line-width (6 . 2) :style flat-button)))
  "Selected tab." :group 'ez-review-faces)
(defface ez-review-tab '((t :inherit shadow :box (:line-width (6 . 2) :style flat-button))) "Other tabs." :group 'ez-review-faces)
(defface ez-review-code-block '((t :inherit (fixed-pitch) :background "#00000014" :extend t)) "Fenced code." :group 'ez-review-faces)
(defface ez-review-inline-code '((t :inherit (font-lock-constant-face fixed-pitch))) "`inline code`." :group 'ez-review-faces)
(defface ez-review-suggestion
  '((((background dark)) :background "#0f2d1c" :foreground "#9be9a8" :extend t)
    (t :background "#dafbe1" :foreground "#116329" :extend t))
  "Lines of a suggested change." :group 'ez-review-faces)
(defface ez-review-suggestion-header
  '((t :inherit (bold ez-review-ok))) "Heading of a suggested change." :group 'ez-review-faces)
(defface ez-review-mention
  '((t :inherit (font-lock-function-name-face) :weight bold))
  "An @mention." :group 'ez-review-faces)
(defface ez-review-card-bar '((t :inherit shadow)) "Left bar of a comment card." :group 'ez-review-faces)
(defface ez-review-card-bar-pending '((t :inherit warning)) "Left bar of a pending comment." :group 'ez-review-faces)
(defface ez-review-card-bar-review '((t :inherit font-lock-keyword-face)) "Left bar of a review." :group 'ez-review-faces)

;;;; Buffers

(defun ez-review-ui--font-lock-off ()
  (when font-lock-mode (font-lock-mode -1)))

(defun ez-review-ui-keep-faces ()
  "Stop font-lock from stripping the `face' properties this package inserts.
Call from a major mode body.  Modes derived from `magit-section-mode' get
font-lock with no keywords, which erases every propertized string we draw."
  (setq-local font-lock-defaults nil)
  ;; the global mode turns font-lock on after the mode function; run last
  (add-hook 'after-change-major-mode-hook #'ez-review-ui--font-lock-off 90 t)
  (when font-lock-mode (font-lock-mode -1)))

;;;; Icons

(defconst ez-review-ui--icons
  '((pr-open "●" "nf-oct-git_pull_request")
    (pr-draft "○" "nf-oct-git_pull_request_draft")
    (pr-merged "◆" "nf-oct-git_merge")
    (pr-closed "✕" "nf-oct-git_pull_request_closed")
    (issue-open "◉" "nf-oct-issue_opened")
    (issue-closed "✓" "nf-oct-issue_closed")
    (success "✓" "nf-oct-check_circle")
    (failure "✗" "nf-oct-x_circle")
    (pending "◔" "nf-oct-clock")
    (skipped "–" "nf-oct-skip")
    (comment "▪" "nf-oct-comment")
    (file "▤" "nf-oct-file_diff")
    (branch "⎇" "nf-oct-git_branch")
    (approved "✓" "nf-oct-check")
    (changes "±" "nf-oct-diff"))
  "Icon name -> (UNICODE NERD-ICONS-OCTICON-NAME).")

(defun ez-review-ui-icon (name &optional face)
  "Icon string for NAME, optionally propertized with FACE."
  (let* ((entry (cdr (assq name ez-review-ui--icons)))
         (glyph (or (and ez-review-icons
                         (require 'nerd-icons nil t)
                         (fboundp 'nerd-icons-octicon)
                         (ignore-errors (nerd-icons-octicon (cadr entry))))
                    (car entry) "?")))
    (if face (propertize (substring-no-properties glyph) 'face face) glyph)))

;;;; Chips and small text pieces

(defun ez-review-ui-chip (text face)
  "TEXT as a padded colored chip in FACE."
  (propertize (format " %s " text) 'face face))

(defun ez-review-ui-state-chip (item)
  "Status chip for a PR or issue ITEM."
  (let* ((pr (ez-review-pr-p item))
         (state (if pr (ez-review-pr-state item) (ez-review-issue-state item))))
    (cond ((and pr (ez-review-pr-draft item) (equal state "open"))
           (ez-review-ui-chip (concat (ez-review-ui-icon 'pr-draft) " Draft") 'ez-review-chip-draft))
          ((equal state "merged")
           (ez-review-ui-chip (concat (ez-review-ui-icon 'pr-merged) " Merged") 'ez-review-chip-merged))
          ((equal state "closed")
           (ez-review-ui-chip (concat (ez-review-ui-icon (if pr 'pr-closed 'issue-closed)) " Closed")
                              'ez-review-chip-closed))
          (t (ez-review-ui-chip (concat (ez-review-ui-icon (if pr 'pr-open 'issue-open)) " Open")
                                'ez-review-chip-open)))))

(defun ez-review-ui-state-icon (item)
  "Just the colored icon of ITEM's state, for compact rows."
  (let* ((pr (ez-review-pr-p item))
         (state (if pr (ez-review-pr-state item) (ez-review-issue-state item))))
    (cond ((and pr (ez-review-pr-draft item) (equal state "open"))
           (ez-review-ui-icon 'pr-draft 'ez-review-meta))
          ((equal state "merged") (ez-review-ui-icon 'pr-merged '(:foreground "#a371f7")))
          ((equal state "closed")
           (ez-review-ui-icon (if pr 'pr-closed 'issue-closed) 'ez-review-fail))
          (t (ez-review-ui-icon (if pr 'pr-open 'issue-open) 'ez-review-ok)))))

(defun ez-review-ui--hash-color (name)
  "A stable pleasant color for label NAME, as RRGGBB."
  (let ((h (abs (sxhash-equal name))))
    (format "%02x%02x%02x" (+ 70 (% h 140)) (+ 70 (% (/ h 140) 140)) (+ 70 (% (/ h 19600) 140)))))

(defun ez-review-ui-label (label)
  "A colored chip for LABEL, a (NAME . HEX-OR-NIL) cons."
  (let* ((name (car label))
         (hex (string-remove-prefix "#" (or (cdr label) (ez-review-ui--hash-color name))))
         (rgb (condition-case nil
                  (list (string-to-number (substring hex 0 2) 16)
                        (string-to-number (substring hex 2 4) 16)
                        (string-to-number (substring hex 4 6) 16))
                (error '(110 118 129))))
         (lum (/ (+ (* 0.299 (nth 0 rgb)) (* 0.587 (nth 1 rgb)) (* 0.114 (nth 2 rgb))) 255)))
    (propertize (format " %s " name) 'face
                `(:background ,(apply #'format "#%02x%02x%02x" rgb)
                  :foreground ,(if (> lum 0.55) "#1f2328" "#ffffff")))))

(defun ez-review-ui-labels (labels)
  "LABELS as a row of chips separated by spaces."
  (mapconcat #'ez-review-ui-label labels " "))

(defun ez-review-ui-reltime (iso)
  "ISO timestamp as \"3h ago\"."
  (when (and (stringp iso) (not (string-empty-p iso)))
    (condition-case nil
        (let ((secs (- (float-time) (float-time (date-to-time iso)))))
          (cond ((< secs 60) "just now")
                ((< secs 3600) (format "%dm ago" (/ secs 60)))
                ((< secs 86400) (format "%dh ago" (/ secs 3600)))
                ((< secs 2592000) (format "%dd ago" (/ secs 86400)))
                ((< secs 31536000) (format "%dmo ago" (/ secs 2592000)))
                (t (format "%dy ago" (/ secs 31536000)))))
      (error iso))))

(defun ez-review-ui-check-icon (state)
  "Colored icon for a check STATE."
  (pcase state
    ('success (ez-review-ui-icon 'success 'ez-review-ok))
    ('failure (ez-review-ui-icon 'failure 'ez-review-fail))
    ('skipped (ez-review-ui-icon 'skipped 'ez-review-meta))
    (_ (ez-review-ui-icon 'pending 'ez-review-wait))))

(defun ez-review-ui-checks-summary (checks)
  "One-word rollup of CHECKS, an alist of (NAME . STATE), or nil if none."
  (when checks
    (let ((states (mapcar #'cdr checks)))
      (cond ((memq 'failure states) 'failure)
            ((memq 'pending states) 'pending)
            (t 'success)))))

(defun ez-review-ui-decision (decision)
  "Chip text for a review DECISION string, or an empty string."
  (pcase decision
    ("approved" (concat (ez-review-ui-icon 'approved 'ez-review-ok) (propertize " approved" 'face 'ez-review-ok)))
    ("changes_requested" (concat (ez-review-ui-icon 'changes 'ez-review-fail) (propertize " changes" 'face 'ez-review-fail)))
    ("review_required" (propertize "needs review" 'face 'ez-review-wait))
    (_ "")))

(defun ez-review-ui-right (text)
  "A display string that right-aligns TEXT within the window."
  (concat (propertize " " 'display `(space :align-to (- right ,(1+ (string-width text)))))
          text))

(defun ez-review-ui-tabs (tabs active)
  "A header-line string for TABS, an alist of (KEY LABEL COUNT), ACTIVE is a KEY."
  (mapconcat
   (lambda (tab)
     (pcase-let ((`(,key ,label ,count) tab))
       (propertize (format " %s%s " label (if count (format "  %s" count) ""))
                   'face (if (eq key active) 'ez-review-tab-active 'ez-review-tab))))
   tabs " "))

;;;; Markdown, lightly

(defun ez-review-ui--inline (line)
  "Fontify inline Markdown in LINE."
  (let ((s line))
    (setq s (replace-regexp-in-string
             "`\\([^`\n]+\\)`" (lambda (m) (propertize (match-string 1 m) 'face 'ez-review-inline-code)) s t t))
    (setq s (replace-regexp-in-string
             "\\*\\*\\([^*\n]+\\)\\*\\*" (lambda (m) (propertize (match-string 1 m) 'face 'bold)) s t t))
    (setq s (replace-regexp-in-string
             "\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))"
             (lambda (m) (propertize (match-string 1 m) 'face 'link)) s t t))
    ;; @user, but not the middle of an e-mail address
    (setq s (replace-regexp-in-string
             "\\(\\`\\|[^[:alnum:]_@]\\)\\(@[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9_]\\|@[A-Za-z0-9]\\)"
             (lambda (m) (concat (match-string 1 m) (propertize (match-string 2 m) 'face 'ez-review-mention)))
             s t t))
    (replace-regexp-in-string "^\\([ \t]*\\)[-*] \\[\\([ xX]\\)\\]"
                              (lambda (m) (concat (match-string 1 m)
                                                  (if (string= (match-string 2 m) " ") "☐" "☑")))
                              s t t)))

(defun ez-review-ui-markdown (text)
  "TEXT with light Markdown styling: headings, quotes, code, bold, links.
A fenced block tagged `suggestion' is drawn as a suggested change."
  (let ((fence nil) out)                ; FENCE is nil, `code' or `suggestion'
    (dolist (raw (split-string (replace-regexp-in-string "\r" "" (or text "")) "\n"))
      (let ((line
             (cond
              ((string-match "\\`[ \t]*```\\(.*\\)" raw)
               (if fence
                   (progn (setq fence nil) :skip)
                 (setq fence (if (string-prefix-p "suggestion" (string-trim (match-string 1 raw)))
                                 'suggestion 'code))
                 (if (eq fence 'suggestion)
                     (cons (propertize (concat (ez-review-ui-icon 'changes) " Suggested change")
                                       'face 'ez-review-suggestion-header)
                           nil)
                   :skip)))
              ;; the face covers the newline too, so :extend paints the whole row
              ((eq fence 'suggestion) (cons (propertize (concat "+ " raw) 'face 'ez-review-suggestion)
                                            'ez-review-suggestion))
              (fence (cons (propertize (concat "  " raw) 'face 'ez-review-code-block)
                           'ez-review-code-block))
              ((string-match "\\`#+ +\\(.*\\)" raw)
               (cons (propertize (match-string 1 raw) 'face 'ez-review-heading) nil))
              ((string-match "\\`> ?\\(.*\\)" raw)
               (cons (concat (propertize "▎ " 'face 'ez-review-card-bar)
                             (propertize (ez-review-ui--inline (match-string 1 raw)) 'face 'italic))
                     nil))
              (t (cons (ez-review-ui--inline raw) nil)))))
        (unless (eq line :skip) (push line out))))
    (let ((lines (nreverse out)))
      (mapconcat #'identity
                 (cl-loop for (line . face) in lines
                          for i from 1
                          collect (if (and face (< i (length lines)))
                                      (concat line (propertize "\n" 'face face))
                                    (concat line (if (< i (length lines)) "\n" ""))))
                 ""))))

;;;; Cards

(defun ez-review-ui-card (header body &rest args)
  "A comment card: a HEADER line over BODY (Markdown), with a colored left bar.
ARGS: :bar FACE, :indent N columns, :chip extra text after HEADER.
Returns the card as a string ending in a newline."
  (let* ((bar-face (or (plist-get args :bar) 'ez-review-card-bar))
         (pad (make-string (or (plist-get args :indent) 2) ?\s))
         (bar (concat pad (propertize "┃ " 'face bar-face)))
         (text (string-trim-right (ez-review-ui-markdown (or body ""))))
         (lines (unless (string-empty-p text) (split-string text "\n"))))
    (concat (unless (and (string-empty-p header) (not (plist-get args :chip)))
              (concat bar header (if-let* ((c (plist-get args :chip))) (concat " " c) "") "\n"))
            (mapconcat (lambda (l) (concat bar l "\n")) lines ""))))

(defun ez-review-ui-comment-header (comment)
  "Header text for COMMENT: author and time."
  (concat (propertize (or (ez-review-comment-author comment) "ghost") 'face 'ez-review-author)
          (propertize (concat " · " (or (ez-review-ui-reltime (ez-review-comment-created comment)) ""))
                      'face 'ez-review-meta)))

(defun ez-review-ui-comment-chip (comment)
  "Extra chip for COMMENT: review verdicts and resolved threads."
  (pcase (ez-review-comment-state comment)
    ("approved" (ez-review-ui-chip "approved" 'ez-review-chip-open))
    ("changes_requested" (ez-review-ui-chip "changes requested" 'ez-review-chip-closed))
    (_ (when (ez-review-comment-resolved comment) (ez-review-ui-chip "resolved" 'ez-review-chip-draft)))))

(provide 'ez-review-ui)
;;; ez-review-ui.el ends here
