;;; ez-agents-review.el --- Code review of what an agent changed -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; `ez-agents-review' opens a buffer listing every file an agent changed since
;; its base commit (committed, uncommitted and untracked), each with its hunks.
;; Mark files reviewed, attach notes to lines, and send the notes back to the
;; agent as one prompt.  Deeper looks open in the viewer of your choice:
;;
;;   magit  `v'/`d'  full magit diff of the file against the base
;;   ediff  `e'      side-by-side base vs. working tree (read-only by default);
;;                   `E' walks through every unreviewed file in turn
;;   delta  `D'      `git diff | delta' in a Ghostel terminal
;;   eshell `$'      the diff command typed into an eshell in the worktree
;;
;; Nothing here changes the agent's working tree or your index.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'ez-agents)
(require 'ez-agents-git)
(require 'ez-agents-ui)

(declare-function magit-diff-range "magit-diff")
(declare-function magit-status "magit-status")
(declare-function ediff-buffers "ediff")
(declare-function ediff-setup-windows-plain "ediff-wind")
(declare-function eshell "eshell")
(declare-function eshell-send-input "esh-mode")
(declare-function ghostel-exec "ghostel")
(defvar ediff-window-setup-function)
(defvar ediff-split-window-function)
(defvar ediff-startup-hook)
(defvar ediff-after-quit-hook-internal)

(defcustom ez-agents-review-viewer 'magit
  "What `v' (and RET on a file with a prefix) opens for the file at point."
  :type '(choice (const magit) (const ediff) (const delta) (const eshell))
  :group 'ez-agents)

(defcustom ez-agents-review-feedback-format 'paste
  "How review notes are delivered to the agent.
`paste' sends them as one multi-line bracketed paste; `single-line' joins
them with \" / \" for agents that mishandle pasted newlines."
  :type '(choice (const paste) (const single-line))
  :group 'ez-agents)

(defcustom ez-agents-review-max-diff-lines 400
  "Longer per-file diffs are cut in the review buffer (use a viewer for the rest)."
  :type 'integer
  :group 'ez-agents)

(defface ez-agents-review-added
  '((((background dark)) :background "#12361f" :foreground "#8fe3a1" :extend t)
    (t :background "#dcf5e1" :foreground "#14532d" :extend t))
  "Added lines." :group 'ez-agents)
(defface ez-agents-review-removed
  '((((background dark)) :background "#3d1a1f" :foreground "#f2a1a8" :extend t)
    (t :background "#fbe0e2" :foreground "#7f1d1d" :extend t))
  "Removed lines." :group 'ez-agents)
(defface ez-agents-review-hunk
  '((((background dark)) :background "#1f2a44" :foreground "#8fb4ff" :extend t)
    (t :background "#dce6fb" :foreground "#1e3a8a" :extend t))
  "Hunk headers." :group 'ez-agents)
(defface ez-agents-review-note '((t :inherit warning :slant italic)) "Review notes." :group 'ez-agents)

(defvar-local ez-agents-review--session-id nil)
(defvar-local ez-agents-review--files nil "Plists for the files rendered, in order.")
(defvar-local ez-agents-review--hunks nil "Hash \"path#i\" -> (:path :start :lines).")

;;;; Data

(defun ez-agents-review--hash (text) (secure-hash 'sha1 text))

(defun ez-agents-review--session ()
  (or (and ez-agents-review--session-id (ez-agents-session ez-agents-review--session-id))
      (user-error "This review's agent session is gone")))

(defun ez-agents-review--check (s)
  (unless (and (ez-agent-cwd s) (ez-agent-base s))
    (user-error "%s has no base commit to review against (not a git checkout?)"
                (ez-agent-name s))))

(defun ez-agents-review--collect (s)
  "Changed files of S as plists with :path :status :old :diff :hash :reviewed."
  (let ((dir (ez-agent-cwd s)) (base (ez-agent-base s)))
    (mapcar
     (lambda (c)
       (let* ((untracked (equal (plist-get c :status) "?"))
              (diff (ez-agents-git-file-diff dir base (plist-get c :path) untracked
                                             (plist-get c :old)))
              (hash (ez-agents-review--hash diff)))
         (append c (list :diff diff :hash hash
                         :reviewed (equal (gethash (plist-get c :path) (ez-agent-reviewed s))
                                          hash)))))
     (ez-agents-git-changes dir base))))

(defun ez-agents-review--parse-diff (text)
  "Split unified diff TEXT into hunks: plists (:header :start :lines)."
  (let (hunks cur)
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match "\\`@@ -[0-9,]+ \\+\\([0-9]+\\)" line)
        (when cur (push cur hunks))
        (setq cur (list :header line :start (string-to-number (match-string 1 line)) :lines nil)))
       (cur (plist-put cur :lines (cons line (plist-get cur :lines))))))
    (when cur (push cur hunks))
    (mapcar (lambda (h) (plist-put h :lines (nreverse (plist-get h :lines))))
            (nreverse hunks))))

(defun ez-agents-review--hunk-line (hunk idx)
  "New-file line number of the IDXth body line (0-based) of HUNK."
  (let ((n (plist-get hunk :start)))
    (cl-loop for l in (cl-subseq (plist-get hunk :lines) 0 (min idx (length (plist-get hunk :lines))))
             unless (string-prefix-p "-" l) do (cl-incf n))
    n))

(defun ez-agents-review-mark (s path hash &optional on)
  "Record PATH (with diff HASH) as reviewed (ON non-nil) or not."
  (if on (puthash path hash (ez-agent-reviewed s)) (remhash path (ez-agent-reviewed s)))
  (ez-agents--changed))

(defun ez-agents-review-needs-review-p (s)
  "Non-nil if S changed files and its review has not been approved."
  (and (ez-agent-diffstat s) (> (car (ez-agent-diffstat s)) 0)
       (not (eq (ez-agent-review-state s) 'approved))))

(defun ez-agents-review-refresh-stats (s &optional force)
  "Recompute S's diffstat at most every 8 seconds.  Return non-nil if it changed."
  (when (and (ez-agent-cwd s) (ez-agent-base s)
             (or force (null (ez-agent-stats-time s))
                 (> (- (float-time) (ez-agent-stats-time s)) 8)))
    (setf (ez-agent-stats-time s) (float-time))
    (let ((new (ez-agents-git-diffstat (ez-agent-cwd s) (ez-agent-base s))))
      (unless (equal new (ez-agent-diffstat s))
        (setf (ez-agent-diffstat s) new)
        (when (eq (ez-agent-review-state s) 'approved)   ; new changes void an approval
          (setf (ez-agent-review-state s) nil))
        t))))

;;;; Feedback text

(defun ez-agents-review-feedback-text (notes &optional single-line)
  "Prompt text for NOTES, a list of (PATH LINE TEXT)."
  (let ((items (cl-loop for (path line text) in notes
                        for i from 1
                        collect (format "%d. %s%s — %s" i path (if line (format ":%d" line) "") text))))
    (if single-line
        (concat "Code review feedback on your changes, please address each: "
                (string-join items " / "))
      (concat "Code review feedback on your changes. Please address each item, "
              "then tell me when you are done:\n\n"
              (string-join items "\n")))))

;;;; Rendering

(defun ez-agents-review--color-line (l)
  (propertize l 'face (cond ((string-prefix-p "+" l) 'ez-agents-review-added)
                            ((string-prefix-p "-" l) 'ez-agents-review-removed)
                            (t nil))))

(defun ez-agents-review--insert-file (s f numstat)
  (let* ((path (plist-get f :path))
         (st (plist-get f :status))
         (ns (gethash path numstat))
         (hunks (ez-agents-review--parse-diff (plist-get f :diff)))
         (notes (cl-remove-if-not (lambda (n) (equal (car n) path)) (ez-agent-notes s))))
    (magit-insert-section (ez-rfile path)
      (magit-insert-heading
        (concat (if (plist-get f :reviewed)
                    (propertize "☑" 'face 'ez-agents-working)
                  (propertize "☐" 'face 'ez-agents-waiting))
                " " (propertize (format "%-2s" (if (equal st "?") "new" st)) 'face 'ez-agents-dim)
                " " (propertize path 'face (if (plist-get f :reviewed) 'ez-agents-dim 'ez-agents-project))
                (when (plist-get f :old)
                  (propertize (format "  (from %s)" (plist-get f :old)) 'face 'ez-agents-dim))
                (when ns (concat "  " (propertize (format "+%d" (car ns)) 'face 'ez-agents-review-added)
                                 " " (propertize (format "−%d" (cdr ns)) 'face 'ez-agents-review-removed)))
                (when notes (propertize (format "  ✎ %d" (length notes)) 'face 'ez-agents-review-note))))
      (let ((shown 0) (idx 0))
        (dolist (h hunks)
          (let ((key (format "%s#%d" path idx)))
            (puthash key (list :path path :hunk h) ez-agents-review--hunks)
            (magit-insert-section (ez-rhunk key)
              (magit-insert-heading (propertize (plist-get h :header) 'face 'ez-agents-review-hunk))
              (dolist (l (plist-get h :lines))
                (when (< shown ez-agents-review-max-diff-lines)
                  (insert (ez-agents-review--color-line l) "\n"))
                (cl-incf shown))
              (let ((lo (plist-get h :start))
                    (hi (+ (plist-get h :start) (length (plist-get h :lines)))))
                (dolist (n (cl-remove-if-not (lambda (n) (and (cadr n) (<= lo (cadr n)) (< (cadr n) hi)))
                                             notes))
                  (magit-insert-section (ez-rnote (format "%s:%d" path (cadr n)))
                    (insert (propertize (format "  ✎ line %d: %s\n" (cadr n) (nth 2 n))
                                        'face 'ez-agents-review-note)))))))
          (cl-incf idx))
        (when (> shown ez-agents-review-max-diff-lines)
          (insert (propertize (format "  … %d more lines (open a viewer: v)\n"
                                      (- shown ez-agents-review-max-diff-lines))
                              'face 'ez-agents-dim)))
        ;; file-level notes, and the note for a file without text hunks
        (dolist (n (cl-remove-if #'cadr notes))
          (magit-insert-section (ez-rnote (format "%s:" path))
            (insert (propertize (format "  ✎ %s\n" (nth 2 n)) 'face 'ez-agents-review-note))))))))

(defun ez-agents-review--header (s files)
  (let* ((n (length files))
         (done (cl-count-if (lambda (f) (plist-get f :reviewed)) files))
         (commits (ez-agents-git-lines (ez-agent-cwd s) "log" "--oneline"
                                       (format "%s..HEAD" (ez-agent-base s)))))
    (insert "\n  " (propertize (ez-agent-name s) 'face 'ez-agents-title)
            (propertize (format "   ⎇ %s" (or (ez-agent-branch s) "detached")) 'face 'ez-agents-project)
            (propertize (format "   base %s" (substring (ez-agent-base s) 0 (min 8 (length (ez-agent-base s)))))
                        'face 'ez-agents-dim)
            "\n  "
            (propertize (format "%d file%s changed · %d/%d reviewed · %d commit%s · %d note%s"
                                n (if (= n 1) "" "s") done n
                                (length commits) (if (= 1 (length commits)) "" "s")
                                (length (ez-agent-notes s)) (if (= 1 (length (ez-agent-notes s))) "" "s"))
                        'face 'ez-agents-dim)
            (pcase (ez-agent-review-state s)
              ('approved (propertize "   ✓ approved" 'face 'ez-agents-working))
              ('changes (propertize "   ✎ changes requested" 'face 'ez-agents-waiting))
              (_ ""))
            "\n")
    (dolist (c (cl-subseq commits 0 (min 5 (length commits))))
      (insert (propertize (concat "    " c "\n") 'face 'ez-agents-dim)))
    (insert "\n")))

(defun ez-agents-review--render ()
  (let* ((s (ez-agents-review--session))
         (inhibit-read-only t)
         (state (ez-agents-ui--point-state))
         (fresh (zerop (buffer-size)))
         (files (ez-agents-review--collect s))
         (numstat (ez-agents-git-numstat (ez-agent-cwd s) (ez-agent-base s))))
    (ez-agents-review-refresh-stats s t)
    (setq ez-agents-review--files files
          ez-agents-review--hunks (make-hash-table :test #'equal))
    (erase-buffer)
    (magit-insert-section (ez-rroot)
      (ez-agents-review--header s files)
      (if files
          (dolist (f files) (ez-agents-review--insert-file s f numstat))
        (insert (propertize "  The agent has not changed anything yet.\n" 'face 'ez-agents-dim)))
      (insert (propertize "\n  RET open file · TAB fold · m mark reviewed · ; note · F send notes · A approve · X request changes\n  v viewer · e ediff · E ediff all unreviewed · D delta · $ eshell · S magit status · g refresh\n"
                          'face 'ez-agents-dim)))
    (magit-map-sections
     (lambda (sec)
       (when (and (oref sec hidden) (oref sec content) (not (eq sec magit-root-section)))
         (magit-section-hide sec))))
    (ez-agents-ui--restore-point state fresh 'ez-rfile)))

(defun ez-agents-review--visibility (section)
  (when (eq (oref section type) 'ez-rfile)
    (let ((f (cl-find (oref section value) ez-agents-review--files
                      :key (lambda (x) (plist-get x :path)) :test #'equal)))
      (if (and f (plist-get f :reviewed)) 'hide 'show))))

;;;; Mode and navigation helpers

(defvar-keymap ez-agents-review-mode-map
  :doc "Keymap for `ez-agents-review-mode'."
  "RET" #'ez-agents-review-open-file
  "v" #'ez-agents-review-view
  "d" #'ez-agents-review-view-magit
  "e" #'ez-agents-review-ediff
  "E" #'ez-agents-review-ediff-queue
  "D" #'ez-agents-review-delta
  "$" #'ez-agents-review-eshell
  "S" #'ez-agents-review-magit-status
  "m" #'ez-agents-review-mark-reviewed
  "u" #'ez-agents-review-unmark-reviewed
  ";" #'ez-agents-review-add-note
  "k" #'ez-agents-review-delete-note
  "F" #'ez-agents-review-send-feedback
  "A" #'ez-agents-review-approve
  "X" #'ez-agents-review-request-changes
  "n" #'ez-agents-review-next-file
  "p" #'ez-agents-review-previous-file
  "g" #'ez-agents-review-refresh
  "q" #'quit-window)

(define-derived-mode ez-agents-review-mode magit-section-mode "Agents-Review"
  "Review the changes an agent made."
  ;; Font-lock would strip the `face' properties these buffers set themselves;
  ;; switch it off after the mode and global font-lock have run.
  :after-hook (font-lock-mode -1)
  (setq-local truncate-lines nil
              line-spacing 0.15
              magit-section-highlight-hook nil)
  (add-hook 'magit-section-set-visibility-hook #'ez-agents-review--visibility nil t)
  (hl-line-mode 1))

(defun ez-agents-review-refresh ()
  "Recompute the diff and redraw."
  (interactive)
  (ez-agents-review--render))

(defun ez-agents-review--file-at-point ()
  "The file plist at point (inside a file, hunk or note)."
  (let ((sec (magit-current-section)) path)
    (while (and sec (not path))
      (pcase (oref sec type)
        ('ez-rfile (setq path (oref sec value)))
        ('ez-rhunk (setq path (plist-get (gethash (oref sec value) ez-agents-review--hunks) :path)))
        ('ez-rnote (setq path (car (split-string (oref sec value) ":")))))
      (setq sec (oref sec parent)))
    (and path (cl-find path ez-agents-review--files
                       :key (lambda (f) (plist-get f :path)) :test #'equal))))

(defun ez-agents-review--require-file ()
  (or (ez-agents-review--file-at-point) (user-error "Put point on a file first")))

(defun ez-agents-review--line-at-point ()
  "New-file line number at point when inside a hunk, else nil."
  (let ((sec (magit-current-section)))
    (while (and sec (not (eq (oref sec type) 'ez-rhunk))) (setq sec (oref sec parent)))
    (when-let* ((h (and sec (plist-get (gethash (oref sec value) ez-agents-review--hunks) :hunk))))
      (ez-agents-review--hunk-line
       h (max 0 (- (line-number-at-pos) (line-number-at-pos (oref sec start)) 1))))))

(defun ez-agents-review--move-file (dir)
  (let* ((here (line-beginning-position)) (ps nil))
    (magit-map-sections (lambda (sec) (when (eq (oref sec type) 'ez-rfile)
                                        (push (marker-position (oref sec start)) ps))))
    (setq ps (sort ps #'<))
    (if-let* ((target (if (> dir 0) (cl-find-if (lambda (p) (> p here)) ps)
                        (cl-find-if (lambda (p) (< p here)) (reverse ps)))))
        (goto-char target)
      (message "No more files"))))

(defun ez-agents-review-next-file () "Next file." (interactive) (ez-agents-review--move-file 1))
(defun ez-agents-review-previous-file () "Previous file." (interactive) (ez-agents-review--move-file -1))

;;;; Marking

(defun ez-agents-review--mark (on)
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file)))
    (ez-agents-review-mark s (plist-get f :path) (plist-get f :hash) on)
    (ez-agents-review--render)
    (when on (ez-agents-review--move-file 1))))

(defun ez-agents-review-mark-reviewed () "Mark the file at point reviewed." (interactive)
       (ez-agents-review--mark t))
(defun ez-agents-review-unmark-reviewed () "Mark the file at point not reviewed." (interactive)
       (ez-agents-review--mark nil))

;;;; Notes and feedback

(defun ez-agents-review-add-note (text)
  "Attach a note to the line (or file) at point."
  (interactive (list (read-string "Review note: ")))
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file)))
    (when (string-empty-p (string-trim text)) (user-error "Empty note"))
    (setf (ez-agent-notes s)
          (append (ez-agent-notes s)
                  (list (list (plist-get f :path) (ez-agents-review--line-at-point) text))))
    (ez-agents--changed)
    (ez-agents-review--render)))

(defun ez-agents-review-delete-note ()
  "Delete the note at point."
  (interactive)
  (let ((sec (magit-current-section)))
    (unless (and sec (eq (oref sec type) 'ez-rnote)) (user-error "Not on a note"))
    (pcase-let* ((s (ez-agents-review--session))
                 (`(,path ,line) (split-string (oref sec value) ":"))
                 (line (and line (not (string-empty-p line)) (string-to-number line))))
      (let ((n (cl-find-if (lambda (n) (and (equal (car n) path) (equal (cadr n) line)))
                           (ez-agent-notes s))))
        (setf (ez-agent-notes s) (remq n (ez-agent-notes s)))
        (ez-agents--changed)
        (ez-agents-review--render)))))

(defun ez-agents-review-send-feedback ()
  "Send all notes to the agent as one prompt and clear them."
  (interactive)
  (let* ((s (ez-agents-review--session)) (notes (ez-agent-notes s)))
    (unless notes (user-error "No notes to send"))
    (unless (ez-agents-live-p s) (user-error "%s is not running" (ez-agent-name s)))
    (when (y-or-n-p (format "Send %d note%s to %s? " (length notes)
                            (if (= 1 (length notes)) "" "s") (ez-agent-name s)))
      (if (eq ez-agents-review-feedback-format 'paste)
          (ez-agents-send-paste s (ez-agents-review-feedback-text notes))
        (ez-agents-send s (ez-agents-review-feedback-text notes t)))
      (setf (ez-agent-notes s) nil
            (ez-agent-review-state s) 'changes)
      (ez-agents--changed)
      (ez-agents-review--render)
      (message "Sent review feedback to %s" (ez-agent-name s)))))

(defun ez-agents-review-approve ()
  "Approve the agent's changes."
  (interactive)
  (let ((s (ez-agents-review--session)))
    (setf (ez-agent-review-state s) 'approved)
    (ez-agents--changed)
    (ez-agents-review--render)))

(defun ez-agents-review-request-changes ()
  "Mark the review as needing changes, offering to send pending notes."
  (interactive)
  (let ((s (ez-agents-review--session)))
    (setf (ez-agent-review-state s) 'changes)
    (ez-agents--changed)
    (ez-agents-review--render)
    (when (and (ez-agent-notes s) (y-or-n-p "Send the pending notes to the agent now? "))
      (ez-agents-review-send-feedback))))

;;;; Viewers

(defun ez-agents-review-open-file ()
  "Visit the file (and line) at point in the agent's checkout."
  (interactive)
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file))
         (line (ez-agents-review--line-at-point))
         (file (expand-file-name (plist-get f :path) (ez-agent-cwd s))))
    (if (file-exists-p file)
        (progn (find-file-other-window file)
               (when line (goto-char (point-min)) (forward-line (1- line))))
      (user-error "%s no longer exists (deleted by the agent)" (plist-get f :path)))))

(defun ez-agents-review-view ()
  "Open the file at point in `ez-agents-review-viewer'."
  (interactive)
  (pcase ez-agents-review-viewer
    ('ediff (ez-agents-review-ediff))
    ('delta (ez-agents-review-delta))
    ('eshell (ez-agents-review-eshell))
    (_ (ez-agents-review-view-magit))))

(defun ez-agents-review-view-magit ()
  "Show the file's full diff against the base in magit."
  (interactive)
  (require 'magit-diff)
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file))
         (default-directory (ez-agent-cwd s)))
    (magit-diff-range (ez-agent-base s) nil
                      (delq nil (list (plist-get f :old) (plist-get f :path))))))

(defun ez-agents-review-magit-status ()
  "Open magit-status in the agent's checkout (stage, commit, etc.)."
  (interactive)
  (require 'magit-status)
  (magit-status (ez-agent-cwd (ez-agents-review--session))))

(defun ez-agents-review--diff-command (s f)
  (let ((base (shell-quote-argument (ez-agent-base s)))
        (path (shell-quote-argument (plist-get f :path))))
    (if (equal (plist-get f :status) "?")
        (format "git --no-pager diff --no-index -- /dev/null %s" path)
      (format "git --no-pager diff -M %s -- %s" base path))))

(defun ez-agents-review-delta ()
  "Run `git diff | delta' for the file at point in a Ghostel terminal."
  (interactive)
  (unless (executable-find "delta") (user-error "delta is not installed"))
  (require 'ghostel)
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file))
         (default-directory (ez-agent-cwd s))
         (buf (generate-new-buffer (format "*review: %s*" (plist-get f :path)))))
    (ghostel-exec buf "sh"
                  (list "-c" (format "%s | delta --paging=never; printf '\\n-- press Enter to close --'; read _"
                                     (ez-agents-review--diff-command s f))))
    (pop-to-buffer buf)))

(defun ez-agents-review-eshell ()
  "Open an eshell in the agent's checkout with the file's diff command run."
  (interactive)
  (require 'eshell)
  (let* ((s (ez-agents-review--session)) (f (ez-agents-review--require-file))
         (default-directory (ez-agent-cwd s)))
    (eshell t)
    (goto-char (point-max))
    (insert (ez-agents-review--diff-command s f))
    (eshell-send-input)))

;;;; ediff

(defvar ez-agents-review--ro-restore nil "Buffers made read-only for an ediff session.")

(defun ez-agents-review--base-buffer (s path)
  "A read-only buffer holding PATH as of S's base commit (empty if absent)."
  (let* ((r (ez-agents-git (ez-agent-cwd s) "show" (format "%s:%s" (ez-agent-base s) path)))
         (buf (generate-new-buffer (format "base:%s" (file-name-nondirectory path)))))
    (with-current-buffer buf
      (when (eq (car r) 0) (insert (cdr r)))
      (let ((buffer-file-name (expand-file-name path (ez-agent-cwd s))))
        (set-auto-mode t))
      (setq buffer-read-only t)
      (set-buffer-modified-p nil))
    buf))

(defun ez-agents-review--empty-buffer (name)
  (with-current-buffer (generate-new-buffer name)
    (setq buffer-read-only t)
    (current-buffer)))

(defun ez-agents-review--ediff-start ()
  "Run in the ediff control buffer: use plain windows."
  (setq-local ediff-window-setup-function #'ediff-setup-windows-plain))

(defun ez-agents-review--ediff-file (s f &optional queue)
  "Ediff F of session S (base on the left, working tree on the right).
QUEUE is a list of further paths to review afterwards."
  (require 'ediff)
  (let* ((path (plist-get f :path)) (st (plist-get f :status))
         (full (expand-file-name path (ez-agent-cwd s)))
         (left (cond ((member st '("?" "A")) (ez-agents-review--empty-buffer (format "base:%s (new)" path)))
                     (t (ez-agents-review--base-buffer s (or (plist-get f :old) path)))))
         (right (if (equal st "D")
                    (ez-agents-review--empty-buffer (format "%s (deleted)" path))
                  (find-file-noselect full)))
         (made-ro (and (buffer-local-value 'buffer-file-name right)
                       (not (buffer-local-value 'buffer-read-only right))
                       (not (buffer-modified-p right)))))
    (when made-ro (with-current-buffer right (setq buffer-read-only t)))
    (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
          (ediff-split-window-function #'split-window-horizontally)
          (ediff-startup-hook (cons #'ez-agents-review--ediff-start ediff-startup-hook))
          (after
           (lambda ()
             (when (and made-ro (buffer-live-p right))
               (with-current-buffer right (setq buffer-read-only nil)))
             (dolist (b (list left right))
               (when (and (buffer-live-p b) (string-prefix-p "base:" (buffer-name b))
                          (not (buffer-file-name b)))
                 (kill-buffer b)))
             (when (y-or-n-p (format "Mark %s as reviewed? " path))
               (ez-agents-review-mark s path (plist-get f :hash) t))
             (when-let* ((buf (get-buffer (ez-agents-review--buffer-name s))))
               (with-current-buffer buf (ez-agents-review--render)))
             (when queue
               (run-at-time 0 nil #'ez-agents-review--ediff-next s queue)))))
      (ediff-buffers left right
                     (list (lambda ()
                             (add-hook 'ediff-after-quit-hook-internal after nil t)))))))

(defun ez-agents-review--ediff-next (s queue)
  (let* ((files (ez-agents-review--collect s))
         (todo (cl-remove-if-not
                (lambda (f) (and (member (plist-get f :path) queue) (not (plist-get f :reviewed))))
                files)))
    (if (null todo)
        (message "Review complete: nothing left to ediff")
      (ez-agents-review--ediff-file s (car todo)
                                    (mapcar (lambda (f) (plist-get f :path)) (cdr todo))))))

(defun ez-agents-review-ediff ()
  "Ediff the file at point: base left, working tree (read-only) right.
Use `C-x C-q' in the right-hand buffer to make it editable."
  (interactive)
  (ez-agents-review--ediff-file (ez-agents-review--session) (ez-agents-review--require-file)))

(defun ez-agents-review-ediff-queue ()
  "Ediff every unreviewed file in turn, offering to mark each reviewed."
  (interactive)
  (let* ((s (ez-agents-review--session))
         (todo (cl-remove-if (lambda (f) (plist-get f :reviewed)) ez-agents-review--files)))
    (unless todo (user-error "Every file is already reviewed"))
    (ez-agents-review--ediff-file s (car todo)
                                  (mapcar (lambda (f) (plist-get f :path)) (cdr todo)))))

;;;; Entry point

(defun ez-agents-review--buffer-name (s)
  (format "*Agent Review: %s*" (ez-agent-name s)))

;;;###autoload
(defun ez-agents-review (session)
  "Review the changes SESSION's agent has made since its base commit."
  (interactive (list (ez-agents-read-session "Review which agent: ")))
  (let ((s (ez-agents--top session)))
    (ez-agents-review--check s)
    (let ((buf (get-buffer-create (ez-agents-review--buffer-name s))))
      (with-current-buffer buf
        (unless (derived-mode-p 'ez-agents-review-mode) (ez-agents-review-mode))
        (setq ez-agents-review--session-id (ez-agent-id s))
        (ez-agents-review--render))
      (pop-to-buffer buf))))

(provide 'ez-agents-review)
;;; ez-agents-review.el ends here
