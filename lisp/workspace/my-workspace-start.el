;;; my-workspace-start.el --- Start in the last project; pick one to open or run an agent  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Emacs launched from the Dock/Finder has no shell directory, so buffers start
;; in ~/.  Nothing is opened for you at startup.  Where it matters is when you
;; start an agent:
;;
;;   - from a buffer that is not in a project (e.g. *scratch*), starting or
;;     resuming an agent asks which project, offering the last one you worked in
;;     first, so RET accepts it (`my/agent-project-dir');
;;   - SPC p S (or SPC a P) picks any known project and then lets you open it,
;;     start an agent there, resume an agent chat there, start an agent in a
;;     new worktree, or open a terminal.
;;
;; `my/start-in-last-project' restores the old behaviour of opening the last
;; project in dired at launch.

(require 'cl-lib)
(require 'project)

(declare-function my/leader "my-keys-leader")
(declare-function my/terminal-here "my-tools-terminal")
(declare-function project--ensure-read-project-list "project")
(declare-function ez-agents-new "ez-agents")
(declare-function ez-agents-new-worktree "ez-agents-worktree")
(declare-function ez-agents-resume-chat "ez-agents-chats")
(defvar no-littering-var-directory)
(defvar project-switch-commands)            ; so the `let's below bind it dynamically
(defvar tabspaces-project-switch-commands)
(declare-function tabspaces-open-or-create-project-and-workspace "tabspaces")

(defcustom my/start-in-last-project nil
  "Non-nil: a launch without a directory or files opens the last project in dired.
Off by default: nothing is opened until you start an agent (see
`my/agent-project-dir') or pick a project with `my/project-start'."
  :type 'boolean :group 'project)

(defvar my/last-project-file
  (expand-file-name "last-project" (if (boundp 'no-littering-var-directory)
                                       no-littering-var-directory
                                     user-emacs-directory))
  "File remembering the last project root.")

(defvar my/last-project--cache nil)

;;;; Remembering the last project

(defun my/last-project-remember (&optional root)
  "Record ROOT (default: the current buffer's project root) as the last project."
  (ignore-errors
    (when-let* ((root (or root (when-let* ((pr (project-current))) (project-root pr)))))
      (let ((root (file-name-as-directory (expand-file-name root))))
        (unless (or (equal root my/last-project--cache)
                    (equal root (file-name-as-directory (expand-file-name "~"))))
          (setq my/last-project--cache root)
          (make-directory (file-name-directory my/last-project-file) t)
          (with-temp-file my/last-project-file (insert root)))))))

(defun my/last-project ()
  "The remembered project root if it still exists, else nil."
  (let ((root (or my/last-project--cache
                  (when (file-readable-p my/last-project-file)
                    (with-temp-buffer
                      (insert-file-contents my/last-project-file)
                      (string-trim (buffer-string)))))))
    (when (and root (not (string-empty-p root)) (file-directory-p root))
      (file-name-as-directory root))))

(add-hook 'find-file-hook #'my/last-project-remember)
(add-hook 'kill-emacs-hook #'my/last-project-remember)
(with-eval-after-load 'project
  (advice-add 'project-switch-project :after (lambda (dir) (my/last-project-remember dir))))

;;;; Opening it at startup

(defun my/start--launched-without-directory-p ()
  "Non-nil if Emacs was started from the Dock/Finder: no directory, no files."
  (and (display-graphic-p)
       (member (file-name-as-directory (expand-file-name command-line-default-directory))
               (list (file-name-as-directory (expand-file-name "~")) "/"))
       (not buffer-file-name)
       (equal (buffer-name) "*scratch*")))

(defun my/start-open-last-project ()
  "Open the last project root when launched without a directory (opt-in)."
  (when (and my/start-in-last-project (my/start--launched-without-directory-p))
    (when-let* ((root (my/last-project)))
      (when (get-buffer "*scratch*")
        (with-current-buffer "*scratch*" (setq default-directory root)))
      (setq default-directory root)
      (dired root))))

;;;; Choosing the directory when an agent is started

(defvar ez-agents-project-chooser)

(defun my/agent-project-dir ()
  "Where to start an agent when the current buffer is not in a project.
Offers the last project first (RET takes it), then the other known projects,
then the current directory."
  (project--ensure-read-project-list)
  (let* ((here (file-name-as-directory (expand-file-name default-directory)))
         (last (my/last-project))
         (others (cl-remove-if (lambda (r) (member r (list last here)))
                               (mapcar (lambda (r) (file-name-as-directory (expand-file-name r)))
                                       (project-known-project-roots))))
         (cands (append
                 (when last (list (cons (format "%s   (last project)" (abbreviate-file-name last))
                                        last)))
                 (mapcar (lambda (r) (cons (abbreviate-file-name r) r)) others)
                 (list (cons (format "%s   (this directory)" (abbreviate-file-name here)) here))))
         (table (lambda (s p a)
                  (if (eq a 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action a cands s p))))
         (pick (completing-read "Start the agent in: " table nil t nil nil (caar cands))))
    (cdr (assoc pick cands))))

(setq ez-agents-project-chooser #'my/agent-project-dir)

(add-hook 'emacs-startup-hook #'my/start-open-last-project 90)

;;;; Picking a project and what to do in it

(defconst my/project-start-actions
  '(("Open project" . open)
    ("Start an agent here" . agent)
    ("Resume an agent chat here" . resume)
    ("Start an agent in a new worktree" . worktree)
    ("Open a terminal" . terminal))
  "Things `my/project-start' can do in the chosen project.")

(defun my/project-start--noop ()
  "Do nothing (the \"project menu\" while only switching workspace)."
  (interactive))

(defun my/project-start--enter (dir)
  "Switch to DIR's workspace (creating it) without the project menu."
  (if (fboundp 'tabspaces-open-or-create-project-and-workspace)
      ;; tabspaces rebinds `project-switch-commands' to its own copy, so set that.
      (let ((tabspaces-project-switch-commands #'my/project-start--noop)
            (project-switch-commands #'my/project-start--noop))
        (tabspaces-open-or-create-project-and-workspace dir))
    (let ((project-switch-commands #'my/project-start--noop))
      (project-switch-project dir))))

(defun my/project-start (&optional dir)
  "Pick a project (DIR), then open it or run an agent there.
With tabspaces the project gets (or reuses) its own workspace, and the chosen
action then runs with the project root as `default-directory'."
  (interactive)
  (project--ensure-read-project-list)
  (let* ((dir (file-name-as-directory (expand-file-name (or dir (project-prompt-project-dir)))))
         (name (file-name-nondirectory (directory-file-name dir)))
         (pick (cdr (assoc (completing-read (format "%s: " name) my/project-start-actions nil t)
                           my/project-start-actions))))
    (my/last-project-remember dir)
    (if (eq pick 'open)
        (project-switch-project dir)               ; the usual project menu
      (my/project-start--enter dir)
      (let ((default-directory dir))
        (pcase pick
          ('agent (call-interactively #'ez-agents-new))
          ('resume (call-interactively #'ez-agents-resume-chat))
          ('worktree (call-interactively #'ez-agents-new-worktree))
          ('terminal (my/terminal-here)))))))

(my/leader
  "pS" '(my/project-start :wk "start/resume agent in a project")
  "aP" '(my/project-start :wk "project: open / start / resume agent"))

(provide 'my-workspace-start)
