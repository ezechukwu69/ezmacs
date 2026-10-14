;;; my-workspace-project.el --- project.el  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package project
  :ensure nil
  :custom
  (project-vc-extra-root-markers '(".project" "pubspec.yaml" "package.json" "Cargo.toml"
                                   "go.mod" "pyproject.toml" "Makefile"))
  (project-switch-commands '((project-find-file "Find file" ?f)
                             (consult-ripgrep "Ripgrep" ?g)
                             (project-dired "Dired" ?d)
                             (magit-project-status "Magit" ?m)
                             (project-eshell "Eshell" ?e)))
  :config
  ;; Directories where you keep repos; M-x project-remember-projects-under
  (defcustom my/project-search-roots '("~/development")
    "Directories scanned for projects by `my/project-discover'."
    :type '(repeat directory) :group 'project)
  (defun my/project-discover ()
    "Register every repository under `my/project-search-roots'."
    (interactive)
    (dolist (root my/project-search-roots)
      (when (file-directory-p (expand-file-name root))
        (project-remember-projects-under (expand-file-name root) t)))))

(defun my/project-forget-all ()
  "Forget every known project and the saved workspace session, then start afresh.
Open buffers and tabs are left alone; the project list is rebuilt as you visit
projects (or with `my/project-discover')."
  (interactive)
  (when (yes-or-no-p "Forget ALL known projects and the saved workspace session? ")
    (setq project--list nil)
    (when (fboundp 'project--write-project-list) (project--write-project-list))
    (when (and (boundp 'tabspaces-session-file) (file-exists-p tabspaces-session-file))
      (delete-file tabspaces-session-file))
    (message "Forgot all projects")))

(my/leader
  "pX" '(my/project-forget-all :wk "forget ALL")
  "pf" '(project-find-file :wk "find file")
  "pb" '(consult-project-buffer :wk "buffers")
  "pg" '(consult-ripgrep :wk "grep")
  "pd" '(project-dired :wk "dired")
  "pc" '(project-compile :wk "compile")
  "pk" '(project-kill-buffers :wk "kill buffers")
  "pD" '(my/project-discover :wk "discover projects")
  "px" '(project-forget-project :wk "forget")
  "p!" '(project-shell-command :wk "shell command"))

(provide 'my-workspace-project)
