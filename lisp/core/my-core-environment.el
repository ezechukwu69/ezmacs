;;; my-core-environment.el --- Shell environment (PATH for LSP servers, node, ...)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Asking a login shell for its environment takes 0.3-1.5s, so startup never
;; waits for it: the environment of the last run is read from a cache file, and a
;; few idle seconds later a login shell is queried in the background and PATH and
;; the API keys are updated if they changed.  Only the very first start, with no
;; cache yet, asks the shell synchronously.  `M-x my/shell-env-refresh' forces a
;; background refresh at any time.

(defvar my/data-dir)                    ; defined in early-init.el

(defconst my/shell-env-variables
  '("PATH" "MANPATH" "ANTHROPIC_API_KEY" "OPENAI_API_KEY" "GEMINI_API_KEY"))

(defconst my/shell-env-cache-file (expand-file-name "shell-env.eld" my/data-dir)
  "Cached environment.  Holds API keys, so only you can read it.")

(defconst my/shell-env-refresh-delay 5
  "Idle seconds after startup before the background refresh.")

(defun my/shell-env--read-cache ()
  (ignore-errors
    (when (file-readable-p my/shell-env-cache-file)
      (with-temp-buffer
        (insert-file-contents my/shell-env-cache-file)
        (read (current-buffer))))))

(defun my/shell-env--write-cache (env)
  (ignore-errors
    (make-directory (file-name-directory my/shell-env-cache-file) t)
    (with-temp-file my/shell-env-cache-file
      (let ((print-length nil) (print-level nil))
        (prin1 (list :time (float-time) :env env) (current-buffer))))
    (set-file-modes my/shell-env-cache-file #o600)))

(defun my/shell-env--apply (env)
  "Set ENV, an alist of (NAME . VALUE).  Return the names whose value changed."
  (let (changed)
    (dolist (entry env)
      (unless (equal (getenv (car entry)) (cdr entry))
        (push (car entry) changed)
        (setenv (car entry) (cdr entry))))
    (when-let* ((path (cdr (assoc "PATH" env))))
      (setq exec-path (append (parse-colon-path path) (list exec-directory)))
      (when (boundp 'eshell-path-env)
        (setq eshell-path-env path)))
    changed))

;;; Synchronous (first start only) ------------------------------------------

(use-package exec-path-from-shell
  :if (memq window-system '(mac ns x pgtk))
  :defer t
  :init
  (setq exec-path-from-shell-arguments '("-l")
        exec-path-from-shell-variables my/shell-env-variables))

(defun my/shell-env-init ()
  "Set the environment from the cache; ask a login shell only if there is none."
  (if-let* ((cache (my/shell-env--read-cache)))
      (my/shell-env--apply (plist-get cache :env))
    (require 'exec-path-from-shell)
    (exec-path-from-shell-initialize)
    (my/shell-env--write-cache
     (delq nil (mapcar (lambda (var) (when-let* ((val (getenv var))) (cons var val)))
                       my/shell-env-variables)))))

;;; Background refresh -------------------------------------------------------

(defvar my/shell-env--process nil)

;; Prints \037NAME\036VALUE for every variable; anything else the shell's startup
;; files print comes before the first \037 and is ignored.
(defconst my/shell-env--script
  (concat "for v in " (mapconcat #'identity my/shell-env-variables " ")
          "; do printf '\\037%s\\036%s' \"$v\" \"$(printenv \"$v\")\"; done"))

(defun my/shell-env--parse (output)
  "Alist of (NAME . VALUE) parsed from OUTPUT of `my/shell-env--script'.
Variables the shell leaves unset are not included."
  (let (env)
    (dolist (chunk (cdr (split-string output "\037")))
      (when-let* ((sep (string-search "\036" chunk))
                  (name (substring chunk 0 sep))
                  (value (string-trim-right (substring chunk (1+ sep)) "[\n\r]+"))
                  ((member name my/shell-env-variables))
                  ((not (string-empty-p value))))
        (push (cons name value) env)))
    (nreverse env)))

(defun my/shell-env--finish (output status verbose)
  (let ((env (my/shell-env--parse output)))
    (cond
     ((or (not (eq status 0)) (not (assoc "PATH" env)))
      (when verbose (message "Shell environment refresh failed (exit %s)" status)))
     (t
      (let ((changed (my/shell-env--apply env)))
        ;; A variable the shell no longer sets (a key removed from its startup files).
        (dolist (var my/shell-env-variables)
          (when (and (not (assoc var env)) (getenv var))
            (setenv var nil)
            (push var changed)))
        (my/shell-env--write-cache env)
        (when (or verbose changed)
          (message "Shell environment %s"
                   (if changed
                       (format "updated: %s" (string-join (nreverse changed) ", "))
                     "is up to date"))))))))

(defun my/shell-env-refresh (&optional quiet)
  "Query a login shell in the background and apply the latest PATH and API keys.
Never blocks.  With QUIET (as from the startup timer), only report changes."
  (interactive)
  (unless (process-live-p my/shell-env--process)
    (let ((output "")
          ;; Start from what Emacs was launched with, not from the values we set
          ;; ourselves: the shell would otherwise hand back stale PATH entries
          ;; and keys that have since been removed from its startup files.
          (process-environment initial-environment))
      (setq my/shell-env--process
            (make-process
             :name "shell-env" :buffer nil :noquery t :connection-type 'pipe
             :command (list (or (getenv "SHELL") "/bin/zsh") "-l" "-c" my/shell-env--script)
             :filter (lambda (_proc chunk) (setq output (concat output chunk)))
             :sentinel (lambda (proc _event)
                         (when (memq (process-status proc) '(exit signal))
                           (my/shell-env--finish output (process-exit-status proc)
                                                 (not quiet)))))))))

(when (memq window-system '(mac ns x pgtk))
  (my/shell-env-init)
  (add-hook 'emacs-startup-hook
            (lambda ()
              (run-with-idle-timer my/shell-env-refresh-delay nil
                                   #'my/shell-env-refresh t))))

(provide 'my-core-environment)
