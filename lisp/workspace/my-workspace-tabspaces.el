;;; my-workspace-tabspaces.el --- Per-project workspaces with isolated buffers  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; tabspaces builds on tab-bar: every tab is a workspace with its own buffer
;; list.  Opening a project creates/switches to a tab named after the project,
;; and `consult-buffer' (see my-workspace-consult) shows only that tab's buffers.

(use-package tabspaces
  :demand t
  :custom
  (tabspaces-use-filtered-buffers-as-default t)
  (tabspaces-default-tab "Default")
  (tabspaces-remove-to-default t)
  (tabspaces-include-buffers '("*scratch*" "*Messages*"))
  (tabspaces-initialize-project-with-todo nil)
  (tabspaces-session t)                  ; remember workspaces across restarts
  (tabspaces-session-auto-restore nil)   ; restore manually with SPC TAB R
  ;; Per-project sessions would otherwise be written into the project itself as
  ;; ".<project>-tabspaces-session.el".  Keep them in our var dir; the short hash
  ;; keeps same-named projects in different places apart.
  (tabspaces-session-project-session-store
   (lambda (project-root)
     (let ((root (directory-file-name (expand-file-name project-root))))
       (expand-file-name
        (format "%s-%s.el" (file-name-nondirectory root) (substring (md5 root) 0 8))
        (expand-file-name "tabspaces-sessions/" no-littering-var-directory)))))
  (tab-bar-show 1)
  (tab-bar-new-button-show nil)
  (tab-bar-close-button-show nil)
  (tab-bar-tab-hints t)
  (tab-bar-new-tab-choice "*scratch*")
  :config
  ;; Make the stock C-x p p (project-switch-project) open a workspace too.
  (setq tabspaces-project-switch-opens-workspace t)
  (tabspaces-mode 1))

(my/leader
  "pp"      '(tabspaces-open-or-create-project-and-workspace :wk "open project")
  "TAB TAB" '(tab-bar-switch-to-tab :wk "switch")
  "TAB n"   '(tab-bar-switch-to-next-tab :wk "next")
  "TAB p"   '(tab-bar-switch-to-prev-tab :wk "previous")
  "TAB l"   '(tab-bar-switch-to-recent-tab :wk "last")
  "TAB N"   '(tabspaces-switch-or-create-workspace :wk "new/switch by name")
  "TAB d"   '(tabspaces-close-workspace :wk "close (keep buffers)")
  "TAB k"   '(tabspaces-kill-buffers-close-workspace :wk "kill buffers + close")
  "TAB r"   '(tab-bar-rename-tab :wk "rename")
  "TAB b"   '(tabspaces-switch-to-buffer :wk "workspace buffer")
  "TAB B"   '(tabspaces-remove-selected-buffer :wk "remove buffer from workspace")
  "TAB s"   '(tabspaces-save-session :wk "save session")
  "TAB R"   '(tabspaces-restore-session :wk "restore session")
  "TAB c"   '(tabspaces-clear-buffers :wk "clear other buffers"))

;; Alt-1..9 jumps to workspace N.
(dotimes (i 9)
  (let ((n (1+ i)))
    (global-set-key (kbd (format "M-%d" n))
                    (lambda () (interactive) (tab-bar-select-tab n)))))

(provide 'my-workspace-tabspaces)
