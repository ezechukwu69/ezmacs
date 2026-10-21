;;; ez-agents-git.el --- Git helpers for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Small synchronous wrappers around git.  Every function takes the directory
;; to run in; none touches the index or working tree except where named.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom ez-agents-review-ignore '("\\`\\.claude/settings\\.local\\.json\\'")
  "Regexps of paths left out of reviews."
  :type '(repeat regexp)
  :group 'ez-agents)

(defun ez-agents-git (dir &rest args)
  "Run git ARGS in DIR.  Return (EXIT . OUTPUT)."
  (let ((default-directory (file-name-as-directory (expand-file-name dir)))
        (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment)))
    (with-temp-buffer
      (let ((code (apply #'process-file "git" nil t nil "--no-pager" args)))
        (cons code (buffer-string))))))

(defun ez-agents-git-string (dir &rest args)
  "Trimmed stdout of git ARGS in DIR, or nil on failure or empty output."
  (let ((r (apply #'ez-agents-git dir args)))
    (and (eq (car r) 0)
         (let ((s (string-trim (cdr r)))) (and (not (string-empty-p s)) s)))))

(defun ez-agents-git-lines (dir &rest args)
  "Non-empty stdout lines of git ARGS in DIR (nil on failure)."
  (let ((r (apply #'ez-agents-git dir args)))
    (and (eq (car r) 0) (split-string (cdr r) "\n" t))))

(defun ez-agents-git-root (dir)
  "Top level of the working tree containing DIR, or nil."
  (when (file-directory-p dir)
    (when-let* ((r (ez-agents-git-string dir "rev-parse" "--show-toplevel")))
      (file-name-as-directory r))))

(defun ez-agents-git-main-root (dir)
  "Top level of the *main* working tree for DIR (the repo, even from a worktree)."
  (when-let* ((common (ez-agents-git-string dir "rev-parse" "--path-format=absolute"
                                            "--git-common-dir")))
    (let ((common (directory-file-name common)))
      (if (equal (file-name-nondirectory common) ".git")
          (file-name-as-directory (file-name-directory common))
        (ez-agents-git-root dir)))))

(defun ez-agents-git-head (dir) (ez-agents-git-string dir "rev-parse" "HEAD"))

(defun ez-agents-git-branch (dir)
  "Current branch name in DIR, or nil when detached."
  (ez-agents-git-string dir "symbolic-ref" "--short" "-q" "HEAD"))

(defun ez-agents-git-dirty-p (dir)
  (and (ez-agents-git-lines dir "status" "--porcelain") t))

(defun ez-agents-git-default-branch (dir)
  "The repository's main branch name (origin/HEAD, else main, else master)."
  (or (when-let* ((r (ez-agents-git-string dir "symbolic-ref" "--short" "-q"
                                           "refs/remotes/origin/HEAD")))
        (string-remove-prefix "origin/" r))
      (cl-find-if (lambda (b) (eq 0 (car (ez-agents-git dir "rev-parse" "--verify" "-q" b))))
                  '("main" "master"))))

(defun ez-agents-git-branches (dir)
  (ez-agents-git-lines dir "for-each-ref" "--format=%(refname:short)" "refs/heads"))

(defun ez-agents-git--ignored-p (path)
  (cl-some (lambda (re) (string-match-p re path)) ez-agents-review-ignore))

(defun ez-agents-git-changes (dir base)
  "Files changed in DIR since BASE as a list of plists.
Each has :path :status (a letter: A M D R T ?) and :old (for renames).
Includes uncommitted and untracked files; leaves the index untouched."
  (let (out)
    (dolist (line (ez-agents-git-lines dir "diff" "--name-status" "-M" base))
      (let* ((f (split-string line "\t"))
             (st (substring (car f) 0 1)))
        (push (if (equal st "R")
                  (list :path (nth 2 f) :status "R" :old (nth 1 f))
                (list :path (nth 1 f) :status st))
              out)))
    (dolist (p (ez-agents-git-lines dir "ls-files" "--others" "--exclude-standard"))
      (push (list :path p :status "?") out))
    (cl-remove-if (lambda (c) (ez-agents-git--ignored-p (plist-get c :path)))
                  (sort (nreverse out)
                        (lambda (a b) (string< (plist-get a :path) (plist-get b :path)))))))

(defun ez-agents-git-numstat (dir base)
  "Hash table path -> (ADDED . DELETED) for the diff against BASE.
Untracked files are counted as entirely added."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (line (ez-agents-git-lines dir "diff" "--numstat" "-M" base))
      (let ((f (split-string line "\t")))
        (when (= (length f) 3)
          (puthash (nth 2 f) (cons (string-to-number (nth 0 f))
                                   (string-to-number (nth 1 f)))
                   h))))
    (dolist (p (ez-agents-git-lines dir "ls-files" "--others" "--exclude-standard"))
      (let ((file (expand-file-name p dir)))
        (puthash p (cons (if (and (file-regular-p file)
                                  (< (file-attribute-size (file-attributes file)) 2000000))
                             (with-temp-buffer (insert-file-contents file)
                                               (count-lines (point-min) (point-max)))
                           0)
                         0)
                 h)))
    h))

(defun ez-agents-git-diffstat (dir base)
  "Summary (FILES ADDED DELETED) of the changes in DIR since BASE."
  (let ((files 0) (add 0) (del 0)
        (ignored (mapcar (lambda (c) (plist-get c :path)) nil)))
    (ignore ignored)
    (maphash (lambda (p v)
               (unless (ez-agents-git--ignored-p p)
                 (cl-incf files) (cl-incf add (car v)) (cl-incf del (cdr v))))
             (ez-agents-git-numstat dir base))
    (list files add del)))

(defun ez-agents-git-file-diff (dir base path &optional untracked old)
  "Unified diff text for PATH in DIR against BASE.
OLD is PATH's former name when it was renamed."
  (if untracked
      (cdr (ez-agents-git dir "diff" "--no-index" "--" "/dev/null" path))
    (cdr (apply #'ez-agents-git dir "diff" "-M" base "--" (delq nil (list old path))))))

(provide 'ez-agents-git)
;;; ez-agents-git.el ends here
