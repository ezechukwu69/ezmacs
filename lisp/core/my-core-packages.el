;;; my-core-packages.el --- package.el + use-package bootstrap  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'package)
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))

;; `package-initialize' also parses the archive indexes (6000+ packages, ~0.13s)
;; on every start.  Activating the installed packages is all startup needs; the
;; indexes are read when something is installed or `list-packages' runs, and
;; `use-package-always-ensure' refreshes them by itself if a package is missing.
(package-activate-all)

(require 'use-package)
(setq use-package-always-ensure t     ; install anything declared via use-package
      ;; Deferred unless a form says `:demand t': a package loads when a command,
      ;; hook, mode, key or file type that needs it is used.  Anything that must
      ;; be active from startup (a global mode in :config) needs `:demand t'.
      use-package-always-defer t
      use-package-expand-minimally t)

;; Keep ~/.emacs.d clean: must be loaded before other packages write files.
(use-package no-littering
  :demand t
  :config
  ;; no-littering moves `package-quickstart-file' to <data>/var/, but startup
  ;; reads the file early-init.el chose (<data>/package-quickstart.el).  Left
  ;; alone, every install refreshed the var/ copy that nothing reads, so new
  ;; packages ("Cannot open load file") stayed invisible until a manual refresh.
  (setq package-quickstart-file (expand-file-name "package-quickstart.el" my/data-dir)))

;; Work that should happen after startup but not before you can type.  Idle
;; timers run to completion, so a dozen of them (each 0.1-0.5s) froze the
;; keyboard for seconds.  Tasks queued here run one at a time, only after
;; `my/idle-task-delay' seconds without input, with a gap between them in which
;; keys are handled, and a task waits again if a key is already pending.
(defconst my/idle-task-delay 0.4
  "Seconds without input before the next queued startup task runs.")

(defvar my/idle-tasks nil "Functions waiting to run, next first.")
(defvar my/idle-task-timer nil)

(defun my/idle-task-arm (&optional delay)
  (unless (or my/idle-task-timer (null my/idle-tasks))
    (setq my/idle-task-timer
          (run-with-idle-timer (or delay my/idle-task-delay) nil #'my/idle-task-run))))

(defun my/idle-task-run ()
  (setq my/idle-task-timer nil)
  (if (input-pending-p)
      (my/idle-task-arm)
    (when-let* ((task (pop my/idle-tasks)))
      (with-demoted-errors "Startup task: %S" (funcall task))))
  ;; Re-arm from an ordinary timer: an idle timer set while already idle would
  ;; fire at once and the tasks would run back to back.
  (when my/idle-tasks
    (run-with-timer 0.3 nil #'my/idle-task-arm)))

(defun my/after-startup-idle (task &optional first)
  "Run TASK, a function, once Emacs is idle; with FIRST, before queued tasks."
  (setq my/idle-tasks (if first (cons task my/idle-tasks) (append my/idle-tasks (list task))))
  (when after-init-time (my/idle-task-arm))
  (add-hook 'emacs-startup-hook #'my/idle-task-arm))

(defun my/load-when-file-opened (feature &optional predicate)
  "Load FEATURE the first time a file buffer satisfying PREDICATE is opened.
PREDICATE is called in the new buffer (default: any file).  The load goes
through the idle queue, first in line, so opening the file never waits for it."
  (letrec ((hook (lambda ()
                   (when (or (null predicate) (funcall predicate))
                     (remove-hook 'find-file-hook hook)
                     (my/after-startup-idle (lambda () (require feature)) t)))))
    (add-hook 'find-file-hook hook)))

(defun my/code-or-text-buffer-p ()
  "Non-nil in a programming, text or config buffer."
  (derived-mode-p 'prog-mode 'text-mode 'conf-mode))

;; Restore GC settings once Emacs is idle.  Doing it in `emacs-startup-hook'
;; makes the first collection (all of startup's garbage) run before the first frame.
(my/after-startup-idle
 (lambda ()
   (setq gc-cons-threshold (* 64 1024 1024)
         gc-cons-percentage 0.2)))

(setq read-process-output-max (* 4 1024 1024)) ; LSP servers push big payloads

(provide 'my-core-packages)
