;;; ez-agents-worktree.el --- Branches and git worktrees for agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Give an agent its own checkout so it cannot trample your working tree or
;; another agent.  Worktrees live outside the repository, under
;; `ez-agents-worktree-root' (default ~/.emacs-worktrees/<repo>/<branch-slug>).
;; Nothing is ever deleted automatically: removing a worktree or branch is an
;; explicit, confirmed action (`ez-agents-worktree-finish') that refuses to
;; throw away uncommitted or unmerged work without a second confirmation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-agents)
(require 'ez-agents-git)

(defcustom ez-agents-worktree-root "~/.emacs-worktrees"
  "Directory that holds every agent worktree."
  :type 'directory
  :group 'ez-agents)

(defcustom ez-agents-spawn-mode 'ask
  "Where `ez-agents-new' puts an agent inside a git repository.
`ask' prompts each time, `in-place' uses the current checkout, `worktree'
always creates a new worktree."
  :type '(choice (const ask) (const in-place) (const worktree))
  :group 'ez-agents)

(defcustom ez-agents-worktree-copy-files nil
  "Files (relative to the repo root) copied into each new worktree.
Worktrees start without ignored files, so list things like \".env\" here."
  :type '(repeat string)
  :group 'ez-agents)

(defcustom ez-agents-worktree-post-create nil
  "Shell command run in each new worktree (e.g. \"npm install\"), or nil."
  :type '(choice (const nil) string)
  :group 'ez-agents)

(defvar ez-agents-worktree--last-choice (make-hash-table :test #'equal)
  "Repo root -> label chosen last time, offered as the next default.")

;;;; Paths and git

(defun ez-agents-worktree-slug (s)
  "Filesystem-safe lowercase slug of S."
  (let* ((s (downcase s))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (string-trim s "-+" "-+")))
    (if (string-empty-p s) "work" (truncate-string-to-width s 40))))

(defun ez-agents-worktree-branch-name (name)
  "NAME made safe as a git branch name (spaces and odd characters become \"-\")."
  (let* ((n (replace-regexp-in-string "[^A-Za-z0-9._/-]+" "-" (string-trim name)))
         (n (replace-regexp-in-string "/+" "/" n))
         (n (replace-regexp-in-string "\\.\\.+" "." n))
         (n (replace-regexp-in-string "\\.lock\\'" "" n))
         (n (string-trim n "[-./]+" "[-./]+")))
    (if (string-empty-p n) "agent/work" n)))

(defun ez-agents-worktree-path (repo branch)
  "A fresh worktree directory for BRANCH of REPO under the worktree root."
  (let* ((parent (expand-file-name (ez-agents-project-name repo)
                                   (expand-file-name ez-agents-worktree-root)))
         (slug (ez-agents-worktree-slug branch))
         (path (expand-file-name slug parent))
         (i 1))
    (while (file-exists-p path)
      (setq path (expand-file-name (format "%s-%d" slug (cl-incf i)) parent)))
    path))

(defun ez-agents-worktree-list (dir)
  "Worktrees of the repository containing DIR, as plists (:path :head :branch)."
  (let (out cur)
    ;; Entries are separated by blank lines, which `ez-agents-git-lines' drops.
    (dolist (line (append (let ((r (ez-agents-git dir "worktree" "list" "--porcelain")))
                            (and (eq (car r) 0) (split-string (cdr r) "\n")))
                          '("")))
      (cond ((string-prefix-p "worktree " line)
             (setq cur (list :path (file-name-as-directory (substring line 9)))))
            ((string-prefix-p "HEAD " line) (setq cur (plist-put cur :head (substring line 5))))
            ((string-prefix-p "branch " line)
             (setq cur (plist-put cur :branch (string-remove-prefix "refs/heads/" (substring line 7)))))
            ((string= line "bare") (setq cur (plist-put cur :bare t)))
            ((and (string-empty-p line) cur) (push cur out) (setq cur nil))))
    (nreverse out)))

(defun ez-agents-worktree--branch-exists-p (repo branch)
  (eq 0 (car (ez-agents-git repo "rev-parse" "--verify" "-q" (concat "refs/heads/" branch)))))

(defun ez-agents-worktree-create (repo branch base)
  "Create a worktree for BRANCH of REPO, branching from BASE if BRANCH is new.
Return its directory."
  (let* ((branch (ez-agents-worktree-branch-name branch))
         (path (ez-agents-worktree-path repo branch))
         (new (not (ez-agents-worktree--branch-exists-p repo branch)))
         (r (progn (make-directory (file-name-directory path) t)
                   (if new
                       (ez-agents-git repo "worktree" "add" "-b" branch path base)
                     (ez-agents-git repo "worktree" "add" path branch)))))
    (unless (eq (car r) 0)
      (user-error "git worktree add failed: %s" (string-trim (cdr r))))
    (ez-agents-worktree--setup repo path)
    (file-name-as-directory path)))

(defun ez-agents-worktree--setup (repo path)
  (dolist (f ez-agents-worktree-copy-files)
    (let ((src (expand-file-name f repo)))
      (when (file-exists-p src)
        (make-directory (file-name-directory (expand-file-name f path)) t)
        (copy-file src (expand-file-name f path) t))))
  (when ez-agents-worktree-post-create
    (let ((default-directory path))
      (start-process-shell-command "ez-agents-worktree-setup"
                                   (get-buffer-create "*ez-agents worktree setup*")
                                   ez-agents-worktree-post-create))))

(defun ez-agents-worktree-remove (repo path &optional force)
  "Remove the worktree at PATH of REPO.  Return t on success."
  (let ((r (apply #'ez-agents-git repo "worktree" "remove"
                  (append (and force '("--force")) (list path)))))
    (unless (eq (car r) 0)
      (user-error "git worktree remove failed: %s" (string-trim (cdr r))))
    t))

;;;; Choosing where a new agent runs

(defun ez-agents-worktree--fork-point (dir)
  "Commit in DIR that an agent's work should be reviewed against."
  (or (when-let* ((main (ez-agents-git-default-branch dir)))
        (ez-agents-git-string dir "merge-base" main "HEAD"))
      (ez-agents-git-head dir)))

(defun ez-agents-worktree--new-spec (kind repo)
  (let* ((input (string-trim (read-string
                              (format "Task or branch name (empty: %s timestamp): " kind))))
         (branch (cond ((string-empty-p input)
                        (format "agent/%s/%s" kind (format-time-string "%m%d-%H%M")))
                       ((string-match-p "/" input) (ez-agents-worktree-branch-name input))
                       (t (format "agent/%s/%s" kind (ez-agents-worktree-slug input)))))
         (existing (ez-agents-worktree--branch-exists-p repo branch))
         (base-ref (if existing branch
                     (completing-read "Branch from: " (ez-agents-git-branches repo) nil nil nil nil
                                      (or (ez-agents-git-branch repo) "HEAD"))))
         (path (ez-agents-worktree-create repo branch base-ref))
         (base (if existing
                   (ez-agents-worktree--fork-point path)
                 (ez-agents-git-string repo "rev-parse" base-ref))))
    (list :cwd path :branch branch :base base :worktree t)))

(defun ez-agents-worktree--existing-spec (repo)
  (let* ((trees (cl-remove-if (lambda (w) (or (plist-get w :bare)
                                              (equal (plist-get w :path) repo)))
                              (ez-agents-worktree-list repo)))
         (cands (mapcar (lambda (w)
                          (cons (format "%s  [%s]" (abbreviate-file-name (plist-get w :path))
                                        (or (plist-get w :branch) "detached"))
                                w))
                        trees)))
    (unless cands (user-error "This repository has no other worktrees"))
    (let* ((w (cdr (assoc (completing-read "Worktree: " cands nil t) cands)))
           (path (plist-get w :path)))
      (list :cwd path :branch (plist-get w :branch)
            :base (ez-agents-worktree--fork-point path)
            :worktree (string-prefix-p (file-name-as-directory
                                        (expand-file-name ez-agents-worktree-root))
                                       path)))))

(defun ez-agents-worktree-choose-spec (kind dir &optional force)
  "Decide where agent KIND starts for DIR; return a spawn SPEC (or nil).
FORCE is `in-place', `worktree' or `existing' to skip the prompt."
  (let ((repo (and (ez-agents-git-root dir) (ez-agents-git-main-root dir))))
    (if (not repo)
        nil
      (let* ((mode (or force
                       (if (eq ez-agents-spawn-mode 'ask)
                           (let* ((default (gethash repo ez-agents-worktree--last-choice
                                                    "in place (current checkout)"))
                                  (pick (completing-read
                                         (format "Run %s: " kind)
                                         '("in place (current checkout)"
                                           "new worktree"
                                           "existing worktree")
                                         nil t nil nil default)))
                             (puthash repo pick ez-agents-worktree--last-choice)
                             (cond ((string-prefix-p "new" pick) 'worktree)
                                   ((string-prefix-p "existing" pick) 'existing)
                                   (t 'in-place)))
                         ez-agents-spawn-mode))))
        (pcase mode
          ('worktree (ez-agents-worktree--new-spec kind repo))
          ('existing (ez-agents-worktree--existing-spec repo))
          (_ (list :cwd dir)))))))

;;;###autoload
(defun ez-agents-new-worktree (kind &optional prompt-project)
  "Start agent KIND in a fresh git worktree of the current project."
  (interactive (list (ez-agents--read-kind) current-prefix-arg))
  (let* ((dir (ez-agents--normalize-root
               (if prompt-project (project-prompt-project-dir) (ez-agents--current-root))))
         (spec (or (ez-agents-worktree-choose-spec kind dir 'worktree)
                   (user-error "%s is not inside a git repository" dir)))
         (repo (ez-agents-git-main-root dir)))
    (ez-agents-jump (ez-agents-spawn kind repo spec))))

;;;; Finishing

(defun ez-agents-worktree--ensure (session)
  (unless (and (ez-agent-worktree session) (ez-agent-branch session))
    (user-error "%s is not running in a managed worktree" (ez-agent-name session))))

(defun ez-agents-worktree--stop-agent-p (session)
  (or (not (ez-agents-live-p session))
      (when (y-or-n-p (format "%s is still running; stop it first? " (ez-agent-name session)))
        (ez-agents-kill session)
        t)))

;;;###autoload
(defun ez-agents-worktree-finish (session)
  "Wrap up SESSION's branch: open a PR, merge it, or remove the worktree/branch."
  (interactive (list (ez-agents-read-session "Finish which agent: ")))
  (ez-agents-worktree--ensure session)
  (let* ((repo (ez-agent-project session))
         (path (ez-agent-cwd session))
         (branch (ez-agent-branch session))
         (choice (completing-read
                  (format "%s (%s): " (ez-agent-name session) branch)
                  '("open pull request (gh)" "merge into the repo's current branch"
                    "remove worktree" "remove worktree and delete branch" "cancel")
                  nil t)))
    (pcase choice
      ("open pull request (gh)"
       (unless (executable-find "gh") (user-error "gh is not installed"))
       (when (y-or-n-p (format "Push %s to origin and open a PR? " branch))
         (let ((default-directory path))
           (compile (format "git push -u origin %s && gh pr create --fill --head %s"
                            (shell-quote-argument branch) (shell-quote-argument branch))))))
      ("merge into the repo's current branch"
       (let ((into (or (ez-agents-git-branch repo) "HEAD")))
         (when (y-or-n-p (format "Merge %s into %s in %s? " branch into
                                 (abbreviate-file-name repo)))
           (when (ez-agents-git-dirty-p repo)
             (user-error "%s has uncommitted changes; commit or stash first"
                         (abbreviate-file-name repo)))
           (let ((default-directory repo))
             (compile (format "git merge --no-ff %s" (shell-quote-argument branch)))))))
      ((or "remove worktree" "remove worktree and delete branch")
       (when (ez-agents-worktree--stop-agent-p session)
         (let ((force nil))
           (when (ez-agents-git-dirty-p path)
             (unless (y-or-n-p (format "%s has uncommitted changes that will be LOST. Remove anyway? "
                                       (abbreviate-file-name path)))
               (user-error "Cancelled"))
             (setq force t))
           (ez-agents-worktree-remove repo path force)
           (ez-agents--remove (ez-agent-id session))
           (ez-agents--changed)
           (message "Removed worktree %s" (abbreviate-file-name path))
           (when (equal choice "remove worktree and delete branch")
             (let ((r (ez-agents-git repo "branch" "-d" branch)))
               (if (eq (car r) 0)
                   (message "Removed worktree and deleted branch %s" branch)
                 (when (y-or-n-p (format "%s is not fully merged (%s). Delete it anyway? "
                                         branch (string-trim (cdr r))))
                   (ez-agents-git repo "branch" "-D" branch)
                   (message "Deleted branch %s" branch)))))))))))

(provide 'ez-agents-worktree)
;;; ez-agents-worktree.el ends here
