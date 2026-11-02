;;; ez-review-diff.el --- Review a PR/MR diff with inline comments -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `ez-review-diff-open' shows the whole diff of a PR/MR as collapsible file
;; and hunk sections, with the existing review threads drawn under the lines
;; they are about.  Put point on a line (or select a range) and press `c' to
;; write a comment; it becomes a *pending* draft, saved to disk, and nothing
;; is sent until you submit the review with `S' (comment, approve or request
;; changes), which posts all drafts together.
;;
;;   c comment (C-c C-c keeps it pending, C-c C-p posts it now, no review)
;;   P post the pending comment at point now   s suggest a change   r reply   e edit draft   k delete draft   S submit review
;;   ] [ next / previous comment   } { next / previous file
;;   RET on an index row jumps there, on a line visits the file
;;   C check out   g refresh
;;   L pick a commit   ) ( next / previous commit   a back to all changes

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'magit-section)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-ui)
(require 'ez-review-compose)
(require 'ez-review-drafts)
(require 'ez-review-actions)

(declare-function magit-diff-range "magit-diff")
(declare-function evil-visual-state-p "evil-states")
(declare-function evil-visual-beginning "evil-common")
(declare-function evil-visual-end "evil-common")
(declare-function evil-exit-visual-state "evil-states")

(defcustom ez-review-diff-collapse-lines 400
  "Files with more diff lines than this start collapsed."
  :type 'integer
  :group 'ez-review)

(defcustom ez-review-diff-max-lines 3000
  "Diff lines shown per file; the rest is cut (open the file for the remainder)."
  :type 'integer
  :group 'ez-review)

(defface ez-review-diff-add
  '((((background dark)) :background "#0f2d1c" :foreground "#9be9a8" :extend t)
    (t :background "#dafbe1" :foreground "#116329" :extend t))
  "Added lines." :group 'ez-review-faces)
(defface ez-review-diff-del
  '((((background dark)) :background "#3a1418" :foreground "#ffa198" :extend t)
    (t :background "#ffebe9" :foreground "#82071e" :extend t))
  "Removed lines." :group 'ez-review-faces)
(defface ez-review-diff-hunk
  '((t :inherit (font-lock-comment-face) :slant italic :extend t))
  "Hunk headers." :group 'ez-review-faces)
(defface ez-review-diff-file
  '((t :inherit (bold) :extend t))
  "File headings." :group 'ez-review-faces)
(defface ez-review-diff-banner
  '((((background dark)) :background "#2d333b" :extend t)
    (t :background "#dde3ea" :extend t))
  "Background of a file's heading in the Changes section." :group 'ez-review-faces)
(defface ez-review-card-bg
  '((((background dark)) :background "#1c2128" :extend t)
    (t :background "#f1f4f8" :extend t))
  "Background of a comment card." :group 'ez-review-faces)
(defface ez-review-card-bg-pending
  '((((background dark)) :background "#2b2412" :extend t)
    (t :background "#fff5cc" :extend t))
  "Background of a pending (unsent) comment card." :group 'ez-review-faces)

;;;; Parsing

(cl-defstruct ez-review-file old new status hunks (add 0) (del 0) binary)
(cl-defstruct ez-review-hunk header lines)
(cl-defstruct ez-review-dline type old new text)

(defun ez-review-file-path (file)
  "The path to show for FILE: the new one, or the old if deleted."
  (or (ez-review-file-new file) (ez-review-file-old file)))

(defun ez-review-diff--strip (path)
  "PATH without a/ b/ prefix, or nil for /dev/null."
  (let ((p (string-trim path)))
    (cond ((equal p "/dev/null") nil)
          ((string-match "\\`[ab]/\\(.*\\)" p) (match-string 1 p))
          (t p))))

(defun ez-review-diff-parse (text)
  "Parse unified diff TEXT into a list of `ez-review-file'."
  (let ((lines (split-string text "\n"))
        files file hunk old-no new-no)
    (when (and lines (string-empty-p (car (last lines)))) (setq lines (butlast lines)))
    (cl-labels
        ((close-hunk ()
           (when (and hunk file)
             (setf (ez-review-hunk-lines hunk) (nreverse (ez-review-hunk-lines hunk)))
             (push hunk (ez-review-file-hunks file)))
           (setq hunk nil))
         (close-file ()
           (close-hunk)
           (when file
             (setf (ez-review-file-hunks file) (nreverse (ez-review-file-hunks file)))
             (push file files))
           (setq file nil))
         (open-file (&optional old new)
           (close-file)
           (setq file (make-ez-review-file :old old :new new :status 'modified))))
      (dolist (line lines)
        (cond
         ((string-match "\\`diff --git a/\\(.*\\) b/\\(.*\\)\\'" line)
          (open-file (match-string 1 line) (match-string 2 line)))
         ((and hunk (string-match-p "\\`[ +\\\\-]\\|\\`\\'" line)
               (not (string-prefix-p "diff " line)))
          (pcase (and (> (length line) 0) (aref line 0))
            (?+ (push (make-ez-review-dline :type 'add :new new-no :text (substring line 1))
                      (ez-review-hunk-lines hunk))
                (cl-incf new-no) (cl-incf (ez-review-file-add file)))
            (?- (push (make-ez-review-dline :type 'del :old old-no :text (substring line 1))
                      (ez-review-hunk-lines hunk))
                (cl-incf old-no) (cl-incf (ez-review-file-del file)))
            (?\\ nil)
            (_ (push (make-ez-review-dline :type 'ctx :old old-no :new new-no
                                           :text (if (> (length line) 0) (substring line 1) ""))
                     (ez-review-hunk-lines hunk))
               (cl-incf old-no) (cl-incf new-no))))
         ((string-match "\\`@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@" line)
          (unless file (open-file))
          (close-hunk)
          (setq old-no (string-to-number (match-string 1 line))
                new-no (string-to-number (match-string 2 line))
                hunk (make-ez-review-hunk :header line)))
         ((null file)
          (when (string-prefix-p "--- " line)
            (open-file (ez-review-diff--strip (substring line 4)))))
         ((string-prefix-p "new file mode" line) (setf (ez-review-file-status file) 'added))
         ((string-prefix-p "deleted file mode" line) (setf (ez-review-file-status file) 'deleted))
         ((string-prefix-p "rename from " line)
          (setf (ez-review-file-old file) (substring line 12) (ez-review-file-status file) 'renamed))
         ((string-prefix-p "rename to " line) (setf (ez-review-file-new file) (substring line 10)))
         ((or (string-prefix-p "Binary files" line) (string-prefix-p "GIT binary patch" line))
          (setf (ez-review-file-binary file) t))
         ((string-prefix-p "--- " line)
          (if (ez-review-file-hunks file)
              (open-file (ez-review-diff--strip (substring line 4)))
            (setf (ez-review-file-old file) (ez-review-diff--strip (substring line 4)))))
         ((string-prefix-p "+++ " line)
          (setf (ez-review-file-new file) (ez-review-diff--strip (substring line 4))))))
      (close-file))
    (let ((result (nreverse files)))
      ;; /dev/null on either side already nils the path; keep display paths valid.
      (dolist (f result)
        (when (and (null (ez-review-file-new f)) (eq (ez-review-file-status f) 'modified))
          (setf (ez-review-file-status f) 'deleted)))
      result)))

;;;; Buffer state

(defvar-local ez-review-diff--forge nil)
(defvar-local ez-review-diff--number nil)
(defvar-local ez-review-diff--pr nil)
(defvar-local ez-review-diff--files nil)
(defvar-local ez-review-diff--comments nil)
(defvar-local ez-review-diff--commits nil "Commits of the PR, oldest first.")
(defvar-local ez-review-diff--commit nil "The commit being shown, or nil for the whole PR.")
(defvar-local ez-review-diff--only-commented nil
  "Non-nil: Changes lists only files with threads or pending comments.")
(defvar-local ez-review-diff--anchors nil "Hash of jump targets (file, comment, draft) -> buffer position.")

(defvar-keymap ez-review-diff-mode-map
  :doc "Keymap for `ez-review-diff-mode'."
  :parent magit-section-mode-map
  "c" #'ez-review-diff-comment
  "s" #'ez-review-diff-suggest
  "r" #'ez-review-diff-reply
  "e" #'ez-review-diff-edit-draft
  "k" #'ez-review-diff-delete-draft
  "P" #'ez-review-diff-post-draft
  "S" #'ez-review-diff-submit
  "}" #'ez-review-diff-next-file
  "{" #'ez-review-diff-previous-file
  "]" #'ez-review-diff-next-comment
  "[" #'ez-review-diff-previous-comment
  "RET" #'ez-review-diff-visit
  "C" #'ez-review-diff-checkout
  "m" #'ez-review-diff-magit
  "L" #'ez-review-diff-pick-commit
  ")" #'ez-review-diff-next-commit
  "(" #'ez-review-diff-previous-commit
  "a" #'ez-review-diff-all-changes
  "f" #'ez-review-diff-toggle-commented-only
  "g" #'ez-review-diff-refresh
  "o" #'ez-review-diff-browse
  "?" #'ez-review-diff-menu)

(define-derived-mode ez-review-diff-mode magit-section-mode "Review-Diff"
  "Major mode for reviewing a PR/MR diff."
  (ez-review-ui-keep-faces)
  (setq-local revert-buffer-function (lambda (&rest _) (ez-review-diff-refresh))))

;;;; Rendering

(defun ez-review-diff--key (path side line) (list path side line))

(defun ez-review-diff--index (comments)
  "Hash of (PATH SIDE LINE) -> inline COMMENTS, oldest first."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (c comments)
      (when (and (eq (ez-review-comment-kind c) 'inline)
                 (ez-review-comment-path c) (ez-review-comment-line c))
        (push c (gethash (ez-review-diff--key (ez-review-comment-path c) (ez-review-comment-side c)
                                              (ez-review-comment-line c))
                         h))))
    (maphash (lambda (k v) (puthash k (nreverse v) h)) h)
    h))

(defun ez-review-diff--draft-index (drafts)
  (let ((h (make-hash-table :test #'equal)))
    (dolist (d drafts)
      (push d (gethash (ez-review-diff--key (ez-review-draft-path d) (ez-review-draft-side d)
                                            (ez-review-draft-line d))
                       h)))
    (maphash (lambda (k v) (puthash k (nreverse v) h)) h)
    h))

(defun ez-review-diff--anchor (key)
  "Remember that KEY's content starts at point."
  (when ez-review-diff--anchors (puthash key (point) ez-review-diff--anchors)))

(defun ez-review-diff--tint (start end indent face)
  "Add FACE to each line between START and END from column INDENT onward."
  (save-excursion
    (goto-char start)
    (while (< (point) end)
      (let ((bol (line-beginning-position)))
        (add-face-text-property (min (+ bol indent) (line-end-position))
                                (min (1+ (line-end-position)) (point-max))
                                face t))
      (forward-line 1))))

(defun ez-review-diff--insert-comment (c)
  "Insert the card for comment C."
  (ez-review-diff--anchor (list 'comment (ez-review-comment-id c)))
  (let ((start (point))
        (indent (if (ez-review-comment-reply-to c) 14 10)))
    (insert (ez-review-ui-card (ez-review-ui-comment-header c) (ez-review-comment-body c)
                               :indent indent
                               :chip (ez-review-ui-comment-chip c)))
    (ez-review-diff--tint start (point) indent 'ez-review-card-bg)
    (put-text-property start (point) 'ez-review-comment c)))

(defun ez-review-diff--draft-key (d)
  (list 'draft (ez-review-draft-path d) (ez-review-draft-line d) (ez-review-draft-body d)))

(defun ez-review-diff--insert-draft (d)
  "Insert the card for pending draft D."
  (ez-review-diff--anchor (ez-review-diff--draft-key d))
  (let ((start (point)))
    (insert (ez-review-ui-card
             (concat (propertize "you" 'face 'ez-review-author) " "
                     (ez-review-ui-chip "pending" 'ez-review-chip-pending)
                     (if (ez-review-draft-start-line d)
                         (propertize (format "  lines %d–%d" (ez-review-draft-start-line d)
                                             (ez-review-draft-line d))
                                     'face 'ez-review-meta)
                       ""))
             (ez-review-draft-body d)
             :indent 10 :bar 'ez-review-card-bar-pending))
    (ez-review-diff--tint start (point) 10 'ez-review-card-bg-pending)
    (put-text-property start (point) 'ez-review-draft d)))

(defun ez-review-diff--insert-line (file dl width index drafts shown)
  "Insert diff line DL of FILE, then any comments and drafts attached to it."
  (let* ((type (ez-review-dline-type dl))
         (path (ez-review-file-path file))
         (face (pcase type ('add 'ez-review-diff-add) ('del 'ez-review-diff-del)))
         (start (point)))
    (insert (propertize (format (format "%%%ds %%%ds " width width)
                                (or (ez-review-dline-old dl) "") (or (ez-review-dline-new dl) ""))
                        'face 'ez-review-meta)
            (let ((s (concat (pcase type ('add "+ ") ('del "- ") (_ "  "))
                             (ez-review-dline-text dl) "\n")))
              (if face (propertize s 'face face) s)))
    (put-text-property start (point) 'ez-review-line (cons file dl))
    (let* ((side (if (eq type 'del) 'left 'right))
           (num (if (eq type 'del) (ez-review-dline-old dl) (ez-review-dline-new dl)))
           (key (ez-review-diff--key path side num)))
      (dolist (c (gethash key index))
        (puthash (ez-review-comment-id c) t shown)
        (ez-review-diff--insert-comment c))
      (dolist (d (gethash key drafts))
        (ez-review-diff--insert-draft d)))))

(defun ez-review-diff--status-icon (file)
  (pcase (ez-review-file-status file)
    ('added (propertize "A" 'face 'ez-review-ok))
    ('deleted (propertize "D" 'face 'ez-review-fail))
    ('renamed (propertize "R" 'face 'ez-review-wait))
    (_ (propertize "M" 'face 'ez-review-wait))))

(defun ez-review-diff--file-title (file)
  (if (and (ez-review-file-old file) (ez-review-file-new file)
           (not (equal (ez-review-file-old file) (ez-review-file-new file))))
      (format "%s → %s" (ez-review-file-old file) (ez-review-file-new file))
    (ez-review-file-path file)))

(defun ez-review-diff--file-badges (file thread-counts draft-counts)
  "Comment and pending-comment badges for FILE."
  (let ((threads (gethash (ez-review-file-path file) thread-counts 0))
        (pending (gethash (ez-review-file-path file) draft-counts 0)))
    (concat (if (> threads 0)
                (propertize (format "  %s %d" (ez-review-ui-icon 'comment) threads) 'face 'ez-review-author)
              "")
            (if (> pending 0)
                (concat "  " (ez-review-ui-chip (format "%d pending" pending) 'ez-review-chip-pending))
              ""))))

(defun ez-review-diff--insert-file (file index drafts shown thread-counts draft-counts)
  (let* ((total (cl-loop for h in (ez-review-file-hunks file) sum (length (ez-review-hunk-lines h))))
         (width (max 4 (length (number-to-string
                                (cl-loop for h in (ez-review-file-hunks file)
                                         maximize (or (cl-loop for l in (ez-review-hunk-lines h)
                                                               maximize (max (or (ez-review-dline-old l) 0)
                                                                             (or (ez-review-dline-new l) 0)))
                                                      0)))))))
    (insert "\n")                       ; air between files
    (ez-review-diff--anchor (list 'file (ez-review-file-path file)))
    (magit-insert-section (review-file file (> total ez-review-diff-collapse-lines))
      (magit-insert-heading
        (let ((title (concat (ez-review-diff--status-icon file) " "
                             (propertize (ez-review-diff--file-title file) 'face 'ez-review-diff-file)
                             "  "
                             (propertize (format "+%d" (ez-review-file-add file)) 'face 'ez-review-ok) " "
                             (propertize (format "−%d" (ez-review-file-del file)) 'face 'ez-review-fail)
                             (ez-review-diff--file-badges file thread-counts draft-counts))))
          (add-face-text-property 0 (length title) 'ez-review-diff-banner t title)
          (concat title (propertize "\n" 'face 'ez-review-diff-banner))))
      (if (ez-review-file-binary file)
          (insert (propertize "  Binary file\n" 'face 'ez-review-meta))
        (let ((budget ez-review-diff-max-lines))
          (dolist (hunk (ez-review-file-hunks file))
            (when (> budget 0)
              (magit-insert-section (review-hunk hunk)
                (magit-insert-heading (concat (propertize (ez-review-hunk-header hunk) 'face 'ez-review-diff-hunk)
                                              (propertize "\n" 'face 'ez-review-diff-hunk)))
                (dolist (dl (ez-review-hunk-lines hunk))
                  (when (> budget 0)
                    (cl-decf budget)
                    (ez-review-diff--insert-line file dl width index drafts shown)))))))
        (when (<= ez-review-diff-max-lines 0)
          (insert (propertize "  (cut)\n" 'face 'ez-review-meta)))))))

(defun ez-review-diff--insert-outdated (comments shown)
  "Show inline COMMENTS not drawn in the diff (outdated threads)."
  (let ((loose (cl-remove-if (lambda (c) (or (not (eq (ez-review-comment-kind c) 'inline))
                                             (gethash (ez-review-comment-id c) shown)))
                             comments)))
    (when loose
      (magit-insert-section (review-outdated)
        (magit-insert-heading (propertize "Outdated or unplaced comments" 'face 'ez-review-heading))
        (dolist (c loose)
          (insert (propertize (format "  %s%s\n" (or (ez-review-comment-path c) "?")
                                      (cond ((ez-review-comment-line c) (format ":%d" (ez-review-comment-line c)))
                                            ((ez-review-comment-original-line c)
                                             (format "  (outdated: was line %d in an earlier commit)"
                                                     (ez-review-comment-original-line c)))
                                            (t "")))
                              'face 'ez-review-meta))
          (ez-review-diff--insert-comment c))))))

(defun ez-review-diff--excerpt (body)
  "A one-line gist of comment BODY."
  (let* ((lines (seq-remove (lambda (l) (or (string-empty-p (string-trim l))
                                            (string-prefix-p "```" (string-trim l))))
                            (split-string (or body "") "\n")))
         (first (string-trim (or (car lines) "")))
         (suggestion (string-match-p "```suggestion" (or body ""))))
    (concat (if suggestion (concat (ez-review-ui-icon 'changes) " ") "")
            (truncate-string-to-width first 60 nil nil "…"))))

(defun ez-review-diff--thread-rows (comments drafts index)
  "Rows describing every review thread and pending comment, in file order."
  (let ((by-thread (make-hash-table :test #'equal)) (order nil) rows)
    (dolist (c comments)
      (when (and (eq (ez-review-comment-kind c) 'inline) (ez-review-comment-path c))
        (unless (gethash (ez-review-comment-thread c) by-thread) (push (ez-review-comment-thread c) order))
        (push c (gethash (ez-review-comment-thread c) by-thread))))
    (dolist (id (nreverse order))
      (let* ((cs (reverse (gethash id by-thread)))
             (root (or (cl-find-if-not #'ez-review-comment-reply-to cs) (car cs))))
        (push (list :key (list 'comment (ez-review-comment-id root))
                    :path (ez-review-comment-path root) :line (ez-review-comment-line root)
                    :who (ez-review-comment-author root) :count (length cs)
                    :excerpt (ez-review-diff--excerpt (ez-review-comment-body root))
                    :outdated (not (memq root (gethash (ez-review-diff--key (ez-review-comment-path root)
                                                                             (ez-review-comment-side root)
                                                                             (ez-review-comment-line root))
                                                       index)))
                    :resolved (ez-review-comment-resolved root))
              rows)))
    (dolist (d drafts)
      (push (list :key (ez-review-diff--draft-key d) :path (ez-review-draft-path d)
                  :line (ez-review-draft-line d) :who "you" :count 1 :pending t
                  :excerpt (ez-review-diff--excerpt (ez-review-draft-body d)))
            rows))
    (let ((paths (mapcar #'ez-review-file-path ez-review-diff--files)))
      (sort (nreverse rows)
            (lambda (a b)
              (let ((pa (or (cl-position (plist-get a :path) paths :test #'equal) 999))
                    (pb (or (cl-position (plist-get b :path) paths :test #'equal) 999)))
                (if (= pa pb)
                    (< (or (plist-get a :line) 0) (or (plist-get b :line) 0))
                  (< pa pb))))))))

(defun ez-review-diff--insert-overview (pr commit adds dels n-threads n-pending)
  (magit-insert-section (review-overview)
    (insert (ez-review-ui-state-chip pr) " "
            (propertize (format "#%d %s" (ez-review-pr-number pr) (ez-review-pr-title pr)) 'face 'ez-review-heading)
            "\n")
    (insert (propertize (format "%s %s → %s   by @%s" (ez-review-ui-icon 'branch)
                                (ez-review-pr-head pr) (ez-review-pr-base pr) (ez-review-pr-author pr))
                        'face 'ez-review-meta)
            "\n")
    (when commit
      (insert (ez-review-ui-chip (format "commit %d/%d  %s"
                                         (1+ (or (cl-position (ez-review-commit-sha commit) ez-review-diff--commits
                                                              :key #'ez-review-commit-sha :test #'equal) 0))
                                         (length ez-review-diff--commits)
                                         (substring (ez-review-commit-sha commit) 0 7))
                                 'ez-review-chip-draft)
              " " (propertize (or (ez-review-commit-subject commit) "") 'face 'ez-review-title)
              (propertize (format "  %s · %s" (or (ez-review-commit-author commit) "")
                                  (or (ez-review-ui-reltime (ez-review-commit-date commit)) ""))
                          'face 'ez-review-meta)
              "\n"
              (propertize "read-only view of one commit: ) ( walk commits, a for all changes to comment\n"
                          'face 'ez-review-wait)))
    (insert (format "%d %s   " (length ez-review-diff--files)
                    (if (= 1 (length ez-review-diff--files)) "file" "files"))
            (propertize (format "+%d" adds) 'face 'ez-review-ok) " "
            (propertize (format "−%d" dels) 'face 'ez-review-fail))
    (unless commit
      (insert (propertize (format "   %s %d %s" (ez-review-ui-icon 'comment) n-threads
                                  (if (= 1 n-threads) "thread" "threads"))
                          'face 'ez-review-author))
      (when (> n-pending 0)
        (insert "   " (ez-review-ui-chip (format "%d pending" n-pending) 'ez-review-chip-pending)
                (propertize "  S submits them" 'face 'ez-review-meta))))
    (insert "\n"
            (propertize "c comment · s suggest · r reply · S submit · ] [ comments · } { files · L commits · TAB fold · ? menu"
                        'face 'ez-review-meta)
            "\n\n")))

(defun ez-review-diff--insert-file-index (thread-counts draft-counts)
  (let ((n (length ez-review-diff--files)))
    (when (> n 0)
      (magit-insert-section (review-files-index nil (> n 40))
        (magit-insert-heading (propertize "Files changed" 'face 'ez-review-heading)
                              (propertize (format "  %d" n) 'face 'ez-review-meta))
        (let ((width (min 70 (cl-loop for f in ez-review-diff--files
                                      maximize (string-width (ez-review-diff--file-title f))))))
          (dolist (f ez-review-diff--files)
            (magit-insert-section (review-file-link (ez-review-file-path f))
              (insert "  " (ez-review-diff--status-icon f) " "
                      (truncate-string-to-width (ez-review-diff--file-title f) width nil ?\s "…")
                      "  " (propertize (format "+%d" (ez-review-file-add f)) 'face 'ez-review-ok) " "
                      (propertize (format "−%d" (ez-review-file-del f)) 'face 'ez-review-fail)
                      (ez-review-diff--file-badges f thread-counts draft-counts)
                      "\n"))))
        (insert "\n")))))

(defun ez-review-diff--insert-thread-index (rows)
  (when rows
    (magit-insert-section (review-threads-index nil (> (length rows) 40))
      (magit-insert-heading (propertize "Review threads" 'face 'ez-review-heading)
                            (propertize (format "  %d" (length rows)) 'face 'ez-review-meta))
      (dolist (r rows)
        (magit-insert-section (review-thread-link (plist-get r :key))
          (insert "  "
                  (if (plist-get r :pending)
                      (ez-review-ui-chip "pending" 'ez-review-chip-pending)
                    (ez-review-ui-icon 'comment 'ez-review-author))
                  " "
                  (propertize (format "%s%s" (plist-get r :path)
                                      (if (plist-get r :line) (format ":%d" (plist-get r :line)) ""))
                              'face 'ez-review-diff-file)
                  (propertize (format "  %s%s · " (plist-get r :who)
                                      (if (> (plist-get r :count) 1)
                                          (format " +%d" (1- (plist-get r :count))) ""))
                              'face 'ez-review-meta)
                  (plist-get r :excerpt)
                  (if (plist-get r :outdated)
                      (concat "  " (ez-review-ui-chip "outdated" 'ez-review-chip-draft)) "")
                  (if (plist-get r :resolved)
                      (concat "  " (ez-review-ui-chip "resolved" 'ez-review-chip-draft)) "")
                  "\n")))
      (insert "\n"))))

(defun ez-review-diff--render ()
  "Redraw the whole buffer from the data in memory."
  (let* ((inhibit-read-only t)
         (pr ez-review-diff--pr)
         (commit ez-review-diff--commit)
         (comments (unless commit ez-review-diff--comments))
         (index (ez-review-diff--index comments))
         (drafts-list (unless commit (ez-review-drafts-load ez-review-diff--forge ez-review-diff--number)))
         (drafts (ez-review-diff--draft-index drafts-list))
         (shown (make-hash-table :test #'equal))
         (thread-counts (make-hash-table :test #'equal))
         (draft-counts (make-hash-table :test #'equal))
         (adds (cl-loop for f in ez-review-diff--files sum (ez-review-file-add f)))
         (dels (cl-loop for f in ez-review-diff--files sum (ez-review-file-del f)))
         (rows (ez-review-diff--thread-rows comments drafts-list index)))
    (dolist (r rows)
      (let ((table (if (plist-get r :pending) draft-counts thread-counts)))
        (puthash (plist-get r :path) (1+ (gethash (plist-get r :path) table 0)) table)))
    (setq ez-review-diff--anchors (make-hash-table :test #'equal))
    (erase-buffer)
    (magit-insert-section (review-diff)
      (ez-review-diff--insert-overview pr commit adds dels
                                       (cl-count-if-not (lambda (r) (plist-get r :pending)) rows)
                                       (length drafts-list))
      (ez-review-diff--insert-file-index thread-counts draft-counts)
      (ez-review-diff--insert-thread-index rows)
      (magit-insert-section (review-changes)
        (magit-insert-heading (propertize "Changes" 'face 'ez-review-heading)
                              (if ez-review-diff--only-commented
                                  (propertize "  commented files only, f shows all" 'face 'ez-review-wait)
                                ""))
        (dolist (f (if ez-review-diff--only-commented
                       (seq-filter (lambda (f) (or (> (gethash (ez-review-file-path f) thread-counts 0) 0)
                                                   (> (gethash (ez-review-file-path f) draft-counts 0) 0)))
                                   ez-review-diff--files)
                     ez-review-diff--files))
          (ez-review-diff--insert-file f index drafts shown thread-counts draft-counts))
        (when (null ez-review-diff--files)
          (insert (propertize "No changes.\n" 'face 'ez-review-meta))))
      (unless commit
        (insert "\n")
        (ez-review-diff--insert-outdated comments shown)))))

(defun ez-review-diff--redraw ()
  "Redraw keeping point on the same diff line."
  (let ((line (get-text-property (line-beginning-position) 'ez-review-line))
        (fallback (point)))
    (ez-review-diff--render)
    (goto-char fallback)
    (when line
      (let ((pos (point-min)) found)
        (while (and (not found) (setq pos (next-single-property-change pos 'ez-review-line)))
          (when (eq (get-text-property pos 'ez-review-line) line) (setq found pos)))
        (when found (goto-char found))))))

;;;; Fetching

(defun ez-review-diff--fetch (buffer)
  "Fetch diff, comments, commits and PR details for BUFFER and render."
  (with-current-buffer buffer
    (let ((forge ez-review-diff--forge) (n ez-review-diff--number) (commit ez-review-diff--commit))
      (message "Fetching %s #%d%s…" (ez-review-forge-noun forge) n
               (if commit (format " commit %s" (substring (ez-review-commit-sha commit) 0 7)) ""))
      (ez-review-process-gather
       (list (lambda (cb) (if commit
                              (ez-review-forge-commit-diff forge (ez-review-commit-sha commit) cb)
                            (ez-review-forge-diff forge n cb)))
             (lambda (cb) (if commit (funcall cb nil) (ez-review-forge-timeline forge 'pr n cb)))
             (lambda (cb) (ez-review-forge-view forge 'pr n cb))
             (lambda (cb) (ez-review-forge-commits forge n cb)))
       (lambda (results)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if (stringp results)
                 (message "ez-review: %s" results)
               (setq ez-review-diff--files (ez-review-diff-parse (plist-get (nth 0 results) :diff))
                     ez-review-diff--comments (nth 1 results)
                     ez-review-diff--pr (nth 2 results)
                     ez-review-diff--commits (nth 3 results))
               ;; the commit being shown may be a stale copy; keep the fresh one
               (when commit
                 (setq ez-review-diff--commit
                       (or (cl-find (ez-review-commit-sha commit) ez-review-diff--commits
                                    :key #'ez-review-commit-sha :test #'equal)
                           commit)))
               (ez-review-diff--redraw)
               (message "%s #%d: %d files" (ez-review-forge-noun forge) n
                        (length ez-review-diff--files))))))))))

;;;###autoload
(defun ez-review-diff-open (forge number &optional commit)
  "Review the diff of PR NUMBER of FORGE, or of one COMMIT of it."
  (interactive (list (ez-review-forge-current) (read-number "PR/MR number: ")))
  (let ((buf (get-buffer-create (format "*ez-review diff: %s #%d*" (ez-review-forge-path forge) number))))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-review-diff-mode) (ez-review-diff-mode))
      (setq ez-review-diff--forge forge ez-review-diff--number number
            ez-review-diff--commit commit))
    (pop-to-buffer-same-window buf)
    (ez-review-diff--fetch buf)))

(defun ez-review-diff--show-commit (commit)
  "Show COMMIT (or the whole PR when nil) in this buffer."
  (setq ez-review-diff--commit commit
        ez-review-diff--files nil)
  (ez-review-diff--fetch (current-buffer)))

(defun ez-review-diff--commit-label (c)
  (format "%s  %s" (substring (ez-review-commit-sha c) 0 7) (or (ez-review-commit-subject c) "")))

(defun ez-review-diff-pick-commit ()
  "Choose one commit of this PR to review on its own."
  (interactive)
  (unless ez-review-diff--commits (user-error "No commits loaded yet"))
  (let* ((table (mapcar (lambda (c) (cons (ez-review-diff--commit-label c) c)) ez-review-diff--commits))
         (choice (completing-read
                  "Commit: "
                  (lambda (str pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action table str pred)))
                  nil t)))
    (ez-review-diff--show-commit (cdr (assoc choice table)))))

(defun ez-review-diff--step-commit (delta)
  (unless ez-review-diff--commits (user-error "No commits loaded yet"))
  (let* ((n (length ez-review-diff--commits))
         (here (if ez-review-diff--commit
                   (cl-position (ez-review-commit-sha ez-review-diff--commit) ez-review-diff--commits
                                :key #'ez-review-commit-sha :test #'equal)
                 (if (> delta 0) -1 n)))
         (next (+ here delta)))
    (if (or (< next 0) (>= next n))
        (user-error (if (> delta 0) "That is the last commit" "That is the first commit"))
      (ez-review-diff--show-commit (nth next ez-review-diff--commits)))))

(defun ez-review-diff-next-commit ()
  "Review the next commit of the PR."
  (interactive) (ez-review-diff--step-commit 1))

(defun ez-review-diff-previous-commit ()
  "Review the previous commit of the PR."
  (interactive) (ez-review-diff--step-commit -1))

(defun ez-review-diff-toggle-commented-only ()
  "Toggle between all files and only those with threads or pending comments."
  (interactive)
  (setq ez-review-diff--only-commented (not ez-review-diff--only-commented))
  (ez-review-diff--redraw)
  (message (if ez-review-diff--only-commented "Commented files only" "All files")))

(defun ez-review-diff-all-changes ()
  "Go back from a single commit to the whole PR's changes."
  (interactive)
  (if ez-review-diff--commit
      (ez-review-diff--show-commit nil)
    (message "Already showing all changes")))

(defun ez-review-diff-refresh ()
  "Refetch everything."
  (interactive)
  (ez-review-diff--fetch (current-buffer)))

;;;; Commands

(defun ez-review-diff--line-at (&optional pos)
  "The (FILE . DLINE) at POS (default point), or nil."
  (get-text-property (or pos (line-beginning-position)) 'ez-review-line))

(defun ez-review-diff--number-on-side (dl side)
  (if (eq side 'left) (ez-review-dline-old dl) (ez-review-dline-new dl)))

(defun ez-review-diff--region ()
  "The selected (BEG . END): an Emacs region or an Evil visual selection."
  (cond ((use-region-p) (cons (region-beginning) (region-end)))
        ((and (bound-and-true-p evil-local-mode) (fboundp 'evil-visual-state-p) (evil-visual-state-p))
         (cons (evil-visual-beginning) (evil-visual-end)))))

(defun ez-review-diff--leave-selection ()
  (cond ((and (bound-and-true-p evil-local-mode) (fboundp 'evil-visual-state-p) (evil-visual-state-p))
         (evil-exit-visual-state))
        ((use-region-p) (deactivate-mark))))

(defun ez-review-diff--people ()
  "Users involved in this PR, for @-completion: author, reviewers, commenters."
  (cl-delete-duplicates
   (delq nil (append (list (and ez-review-diff--pr (ez-review-pr-author ez-review-diff--pr)))
                     (and ez-review-diff--pr (ez-review-pr-reviewers ez-review-diff--pr))
                     (mapcar #'ez-review-comment-author ez-review-diff--comments)))
   :test #'equal :from-end t))

(defun ez-review-diff--mentions ()
  (ez-review-forge-mention-function ez-review-diff--forge #'ez-review-diff--people))

(defun ez-review-diff--post-now-action (probe buffer)
  "A compose ALT cons that posts PROBE, with the typed text, immediately."
  (cons "post now"
        (lambda (text)
          (with-current-buffer buffer
            (let ((d (copy-sequence probe)))
              (setf (ez-review-draft-body d) text)
              (ez-review-actions-post-inline
               ez-review-diff--forge ez-review-diff--number d
               (lambda () (when (buffer-live-p buffer)
                            (with-current-buffer buffer (ez-review-diff-refresh))))))))))

(defun ez-review-diff--require-pr-view ()
  (when ez-review-diff--commit
    (user-error "Commit view is read-only; press `a' for all changes, then comment there")))

(defun ez-review-diff--new-draft (body)
  "A draft built from the line (or region) at point with BODY."
  (let* ((region (ez-review-diff--region))
         (rb (car region))
         (re (cdr region))
         (end (or (ez-review-diff--line-at
                   (if rb
                       (save-excursion (goto-char (max rb (1- re))) (line-beginning-position))
                     (line-beginning-position)))
                  (user-error "Put point on a diff line")))
         (start (and rb (ez-review-diff--line-at
                         (save-excursion (goto-char rb) (line-beginning-position)))))
         (file (car end))
         (dl (cdr end))
         (side (if (eq (ez-review-dline-type dl) 'del) 'left 'right))
         (line (ez-review-diff--number-on-side dl side))
         (first (and start (eq (car start) file)
                     (ez-review-diff--number-on-side (cdr start) side))))
    (make-ez-review-draft
     :path (ez-review-file-path file) :old-path (ez-review-file-old file)
     :side side :line line
     :old-line (ez-review-dline-old dl) :new-line (ez-review-dline-new dl)
     :start-line (and first line (< first line) first)
     :body body)))

(defun ez-review-diff-comment ()
  "Write a pending comment on the line at point (or the selected lines)."
  (interactive)
  (ez-review-diff--require-pr-view)
  (unless (ez-review-diff--line-at) (user-error "Put point on a diff line"))
  (let ((buffer (current-buffer))
        (probe (prog1 (ez-review-diff--new-draft "x") (ez-review-diff--leave-selection))))
    (ez-review-compose
     (format "comment on %s:%d" (ez-review-draft-path probe) (ez-review-draft-line probe))
     ""
     (lambda (text)
       (with-current-buffer buffer
         (let ((d (copy-sequence probe)))
           (setf (ez-review-draft-body d) text)
           (ez-review-drafts-add ez-review-diff--forge ez-review-diff--number d)
           (ez-review-diff--redraw)
           (message "Pending comment added (S submits the review)"))))
     :header "Pending comment —"
     :mentions (ez-review-diff--mentions)
     :alt (ez-review-diff--post-now-action probe buffer))))

(defun ez-review-diff--source-lines (file first last)
  "Text of FILE's new-side lines FIRST to LAST, or nil if any is not in the diff."
  (let (out)
    (dolist (hunk (ez-review-file-hunks file))
      (dolist (dl (ez-review-hunk-lines hunk))
        (let ((n (ez-review-dline-new dl)))
          (when (and n (<= first n last)) (push (ez-review-dline-text dl) out)))))
    (setq out (nreverse out))
    (and (= (length out) (1+ (- last first))) out)))

(defun ez-review-diff--suggestion-text (forge lines)
  "Compose-buffer starting text offering LINES as a suggested replacement."
  (format "\n\n```%s\n%s\n```"
          (if (eq (ez-review-forge-kind forge) 'gitlab)
              ;; GitLab names the range relative to the commented (last) line
              (format "suggestion:-%d+0" (1- (length lines)))
            "suggestion")
          (string-join lines "\n")))

(defun ez-review-diff-suggest ()
  "Suggest a change to the line at point (or the selected lines).
Like GitHub's \"Add a suggestion\": the comment starts with a suggestion block
holding the current code; edit it into what you would like, add a sentence
above if you want, and finish.  The author can then apply it from the web."
  (interactive)
  (ez-review-diff--require-pr-view)
  (unless (ez-review-diff--line-at) (user-error "Put point on a diff line"))
  (let* ((buffer (current-buffer))
         (probe (prog1 (ez-review-diff--new-draft "x") (ez-review-diff--leave-selection)))
         (forge ez-review-diff--forge)
         (file (cl-find (ez-review-draft-path probe) ez-review-diff--files
                        :key #'ez-review-file-path :test #'equal))
         (first (or (ez-review-draft-start-line probe) (ez-review-draft-line probe)))
         (last (ez-review-draft-line probe)))
    (when (eq (ez-review-draft-side probe) 'left)
      (user-error "Suggestions replace added or unchanged lines, not removed ones"))
    (let ((lines (or (ez-review-diff--source-lines file first last)
                     (user-error "Select lines that are all shown in this diff"))))
      (with-current-buffer
          (ez-review-compose
           (format "suggest change at %s:%d" (ez-review-draft-path probe) last)
           (ez-review-diff--suggestion-text forge lines)
           (lambda (text)
             (with-current-buffer buffer
               (let ((d (copy-sequence probe)))
                 (setf (ez-review-draft-body d) text)
                 (ez-review-drafts-add forge ez-review-diff--number d)
                 (ez-review-diff--redraw)
                 (message "Pending suggestion added (S submits the review)"))))
           :header "Suggest a change —"
           :mentions (ez-review-diff--mentions)
           :alt (ez-review-diff--post-now-action probe buffer))
        ;; start inside the block, on its first code line
        (goto-char (point-min))
        (when (re-search-forward "^```suggestion" nil t)
          (forward-line 1)
          (end-of-line))))))

(defun ez-review-diff--draft-at-point ()
  (get-text-property (point) 'ez-review-draft))

(defun ez-review-diff-edit-draft ()
  "Edit the pending comment at point."
  (interactive)
  (let ((d (or (ez-review-diff--draft-at-point) (user-error "Not on a pending comment")))
        (buffer (current-buffer)))
    (ez-review-compose
     "edit pending comment" (ez-review-draft-body d)
     (lambda (text)
       (with-current-buffer buffer
         (let ((new (copy-sequence d)))
           (setf (ez-review-draft-body new) text)
           (ez-review-drafts-replace ez-review-diff--forge ez-review-diff--number d new)
           (ez-review-diff--redraw))))
     :mentions (ez-review-diff--mentions))))

(defun ez-review-diff-post-draft ()
  "Post the pending comment at point right now, on its own, without a review."
  (interactive)
  (let ((d (or (ez-review-diff--draft-at-point) (user-error "Not on a pending comment")))
        (buffer (current-buffer)))
    (ez-review-actions-post-inline
     ez-review-diff--forge ez-review-diff--number d
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (ez-review-drafts-remove ez-review-diff--forge ez-review-diff--number d)
           (ez-review-diff-refresh)))))))

(defun ez-review-diff-delete-draft ()
  "Delete the pending comment at point."
  (interactive)
  (let ((d (or (ez-review-diff--draft-at-point) (user-error "Not on a pending comment"))))
    (when (y-or-n-p "Delete this pending comment? ")
      (ez-review-drafts-remove ez-review-diff--forge ez-review-diff--number d)
      (ez-review-diff--redraw))))

(defun ez-review-diff-reply ()
  "Reply to the comment at point."
  (interactive)
  (let ((c (or (get-text-property (point) 'ez-review-comment) (user-error "Not on a comment")))
        (buffer (current-buffer)))
    (ez-review-actions-reply
     ez-review-diff--forge ez-review-diff--number c
     (lambda () (when (buffer-live-p buffer) (with-current-buffer buffer (ez-review-diff-refresh))))
     (ez-review-diff--people))))

(defun ez-review-diff-submit ()
  "Submit the review: all pending comments plus your verdict."
  (interactive)
  (let ((buffer (current-buffer)))
    (ez-review-actions-submit
     ez-review-diff--forge ez-review-diff--number
     (lambda () (when (buffer-live-p buffer) (with-current-buffer buffer (ez-review-diff-refresh))))
     (ez-review-diff--people))))

(defun ez-review-diff--card-start-p (pos)
  "Non-nil if a comment or draft card begins at POS."
  (let ((c (get-text-property pos 'ez-review-comment))
        (d (get-text-property pos 'ez-review-draft)))
    (and (or c d)
         (or (= pos (point-min))
             (not (eq c (get-text-property (1- pos) 'ez-review-comment)))
             (not (eq d (get-text-property (1- pos) 'ez-review-draft)))))))

(defun ez-review-diff--goto-card (direction)
  "Move to the start of the next (DIRECTION 1) or previous (-1) card."
  (let ((start (point)) found)
    (while (and (not found) (zerop (forward-line direction)))
      (when (ez-review-diff--card-start-p (point)) (setq found (point))))
    (if found
        (goto-char found)
      (goto-char start)
      (message "No more comments"))))

(defun ez-review-diff-next-comment ()
  "Move to the next comment."
  (interactive)
  (ez-review-diff--goto-card 1))

(defun ez-review-diff-previous-comment ()
  "Move to the previous comment."
  (interactive)
  (ez-review-diff--goto-card -1))

(defun ez-review-diff--reveal-and-go (key)
  "Go to the jump target KEY, unfolding whatever hides it."
  (let ((pos (and ez-review-diff--anchors (gethash key ez-review-diff--anchors))))
    (unless pos (user-error "That is not in this diff any more"))
    (goto-char pos)
    (let ((section (magit-current-section)))
      (while section
        (when (oref section hidden) (magit-section-show section))
        (setq section (oref section parent))))
    (goto-char pos)
    (recenter 2)))

(defun ez-review-diff--next-file (direction)
  (let* ((positions (sort (cl-loop for k being the hash-keys of ez-review-diff--anchors using (hash-values v)
                                   when (eq (car-safe k) 'file) collect v)
                          #'<))
         (target (if (> direction 0)
                     (cl-find-if (lambda (p) (> p (line-end-position))) positions)
                   (cl-find-if (lambda (p) (< p (line-beginning-position))) (reverse positions)))))
    (if target
        (progn (goto-char target) (recenter 2))
      (message "No more files"))))

(defun ez-review-diff-next-file ()
  "Move to the next file's heading in the Changes section."
  (interactive) (ez-review-diff--next-file 1))

(defun ez-review-diff-previous-file ()
  "Move to the previous file's heading in the Changes section."
  (interactive) (ez-review-diff--next-file -1))

(defun ez-review-diff-visit ()
  "On an index row, jump to its place in the diff; on a diff line, visit the file."
  (interactive)
  (cond
   ((magit-section-value-if 'review-file-link)
    (ez-review-diff--reveal-and-go (list 'file (magit-section-value-if 'review-file-link))))
   ((magit-section-value-if 'review-thread-link)
    (ez-review-diff--reveal-and-go (magit-section-value-if 'review-thread-link)))
   (t (ez-review-diff--visit-file))))

(defun ez-review-diff--visit-file ()
  "Visit the file at the line at point in the work tree."
  (let* ((loc (or (ez-review-diff--line-at) (user-error "Not on a diff line")))
         (file (expand-file-name (ez-review-file-path (car loc)) (ez-review-forge-dir ez-review-diff--forge)))
         (line (or (ez-review-dline-new (cdr loc)) (ez-review-dline-old (cdr loc)))))
    (unless (file-exists-p file)
      (user-error "%s is not in the work tree (check out the PR with C)" (ez-review-file-path (car loc))))
    (find-file-other-window file)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun ez-review-diff-checkout ()
  "Check out this PR."
  (interactive)
  (ez-review-actions-checkout ez-review-diff--forge ez-review-diff--number))

(defun ez-review-diff-magit ()
  "Show this PR's changes as a Magit diff, when its branch is checked out."
  (interactive)
  (unless (fboundp 'magit-diff-range) (user-error "Magit is not installed"))
  (let ((default-directory (ez-review-forge-dir ez-review-diff--forge))
        (base (ez-review-pr-base ez-review-diff--pr)))
    (magit-diff-range (format "origin/%s...HEAD" base))))

(defun ez-review-diff-browse ()
  "Open this PR in the browser."
  (interactive)
  (ez-review-forge-browse ez-review-diff--forge 'pr ez-review-diff--number))

(transient-define-prefix ez-review-diff-menu ()
  "Actions in the diff review buffer."
  [["Comment"
    ("c" "Comment on line / region" ez-review-diff-comment)
    ("s" "Suggest a change" ez-review-diff-suggest)
    ("r" "Reply to thread" ez-review-diff-reply)
    ("e" "Edit pending" ez-review-diff-edit-draft)
    ("k" "Delete pending" ez-review-diff-delete-draft)
    ("P" "Post pending one now (no review)" ez-review-diff-post-draft)
    ("S" "Submit review…" ez-review-diff-submit)]
   ["Move"
    ("f" "Commented files only (toggle)" ez-review-diff-toggle-commented-only)
    ("}" "Next file" ez-review-diff-next-file :transient t)
    ("{" "Previous file" ez-review-diff-previous-file :transient t)
    ("]" "Next comment" ez-review-diff-next-comment :transient t)
    ("[" "Previous comment" ez-review-diff-previous-comment :transient t)
    ("RET" "Jump to row / visit file" ez-review-diff-visit)]
   ["Commits"
    ("L" "Pick a commit" ez-review-diff-pick-commit)
    (")" "Next commit" ez-review-diff-next-commit :transient t)
    ("(" "Previous commit" ez-review-diff-previous-commit :transient t)
    ("a" "All changes" ez-review-diff-all-changes)]
   ["Other"
    ("C" "Check out" ez-review-diff-checkout)
    ("m" "Magit range diff" ez-review-diff-magit)
    ("o" "Open in browser" ez-review-diff-browse)
    ("g" "Refresh" ez-review-diff-refresh)]])

(provide 'ez-review-diff)
;;; ez-review-diff.el ends here
