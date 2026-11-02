;;; my-tools-dashboard.el --- Start-up dashboard (ez-dashboard)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Emacs opens on a dashboard: startup time, packages, modules and custom
;; plugins, your agents with their usage, recent projects, recent Claude Code /
;; Codex conversations, recent files and what is running right now.  The engine
;; is lisp/custom-plugins/ez-dashboard/; this file wires it into the config.
;;
;;   SPC b h   open the dashboard any time
;;   In it:    RET open · j/k or TAB move · a p c f s m jump to a section
;;             g refresh · q close · ? help
;;
;; Startup stays cheap.  The first paint uses only data already in memory; the
;; slow parts (loading ez-agents, scanning chat history, asking the agents for
;; their usage) are queued on the config's idle queue (`my/after-startup-idle')
;; and run only while the dashboard is showing.  Opening files from the command
;; line, or the opt-in `my/start-in-last-project', skips the dashboard.  This
;; module is last in modules.el so everything it links to is already loaded.

(require 'cl-lib)

(declare-function my/leader "my-keys-leader")
(declare-function my/after-startup-idle "my-core-packages")
(declare-function evil-make-overriding-map "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function ez-dashboard-buffer "ez-dashboard")
(declare-function ez-dashboard "ez-dashboard")
(declare-function ez-dashboard-startup-finalize "ez-dashboard-sections")
(defvar my/start-in-last-project)
(defvar ez-dashboard-defer-function)
(defvar ez-dashboard-mode-map)

(use-package ez-dashboard
  :ensure nil
  :commands (ez-dashboard ez-dashboard-buffer)
  :init
  ;; Your name for the greeting is personal: set `ez-dashboard-name' in config.el.
  (setq ez-dashboard-defer-function #'my/after-startup-idle))

(defvar my/dashboard--startup-done nil
  "Non-nil once `emacs-startup-hook' has run (after the command line was handled).")

(defun my/dashboard--file-buffer ()
  "A buffer visiting a file or a directory, if the command line opened one."
  (cl-find-if (lambda (b)
                (or (buffer-file-name b)
                    (provided-mode-derived-p (buffer-local-value 'major-mode b) 'dired-mode)))
              (buffer-list)))

(defun my/dashboard-initial-buffer ()
  "The buffer Emacs starts on (`initial-buffer-choice'); always a live buffer.
Files given on the command line win (returning their buffer avoids a split
window with the dashboard); `my/start-in-last-project' keeps *scratch*; later
calls, such as a new emacsclient frame, get the dashboard."
  (cond
   ((bound-and-true-p my/start-in-last-project) (get-scratch-buffer-create))
   ((and (not my/dashboard--startup-done) (my/dashboard--file-buffer)))
   (t (require 'ez-dashboard-sections)
      (ez-dashboard-buffer))))

(setq initial-buffer-choice #'my/dashboard-initial-buffer)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq my/dashboard--startup-done t)
            (when (featurep 'ez-dashboard-sections) (ez-dashboard-startup-finalize)))
          90)

;; `SPC' is the leader in Evil's motion state but not in emacs state, so the
;; dashboard lives in motion state and its own keys override motion's.
(with-eval-after-load 'evil
  (evil-set-initial-state 'ez-dashboard-mode 'motion)
  (with-eval-after-load 'ez-dashboard
    (evil-make-overriding-map ez-dashboard-mode-map 'motion)))

(defun my/dashboard-open ()
  "Open the dashboard, loading its panels first."
  (interactive)
  (require 'ez-dashboard-sections)
  (ez-dashboard))

(my/leader "bh" '(my/dashboard-open :wk "dashboard"))

(provide 'my-tools-dashboard)
