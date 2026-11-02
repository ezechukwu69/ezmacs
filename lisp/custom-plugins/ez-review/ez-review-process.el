;;; ez-review-process.el --- Run the gh and glab CLIs for ez-review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Every call to `gh' or `glab' goes through here.  Commands are always an
;; argv list, never a shell string, so titles and branch names cannot inject
;; shell syntax.  Asynchronous calls keep Emacs responsive; failures carry the
;; CLI's stderr so the user sees why a call failed instead of nothing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defgroup ez-review nil
  "Review pull requests and merge requests from Emacs."
  :group 'tools
  :prefix "ez-review-")

(defcustom ez-review-gh-program "gh"
  "Name or path of the GitHub CLI executable."
  :type 'string
  :group 'ez-review)

(defcustom ez-review-glab-program "glab"
  "Name or path of the GitLab CLI executable."
  :type 'string
  :group 'ez-review)

(define-error 'ez-review-error "ez-review error")

(defun ez-review-process--program-path (program)
  "Absolute path of PROGRAM, or signal a helpful `ez-review-error'."
  (or (executable-find program)
      (signal 'ez-review-error
              (list (format "`%s' not found in `exec-path'; install it or customize ez-review-gh-program / ez-review-glab-program"
                            program)))))

(defun ez-review-process--env (env)
  "Prepend ENV, an alist of (NAME . VALUE), to `process-environment'."
  (append (mapcar (lambda (kv) (format "%s=%s" (car kv) (cdr kv))) env)
          process-environment))

(cl-defun ez-review-process-sync (program args &key dir env input)
  "Run PROGRAM with ARGS in DIR, waiting for it.
ENV is an alist of extra environment variables.  INPUT is a string sent on
stdin.  Return (EXIT-CODE STDOUT STDERR)."
  (let* ((default-directory (or dir default-directory))
         (process-environment (ez-review-process--env env))
         (path (ez-review-process--program-path program))
         (err-file (make-temp-file "ez-review-err"))
         (in-file (when input (make-temp-file "ez-review-in"))))
    (unwind-protect
        (progn
          (when in-file
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region input nil in-file nil 'silent)))
          (with-temp-buffer
            (let ((code (apply #'call-process path in-file (list t err-file) nil args)))
              (list code
                    (buffer-string)
                    (with-temp-buffer
                      (insert-file-contents err-file)
                      (string-trim (buffer-string)))))))
      (delete-file err-file)
      (when in-file (delete-file in-file)))))

(cl-defun ez-review-process-run (program args callback &key dir env input)
  "Run PROGRAM with ARGS asynchronously in DIR.
CALLBACK is called as (CALLBACK EXIT-CODE STDOUT STDERR) when it finishes.
ENV is an alist of extra environment variables; INPUT a string for stdin."
  (let* ((default-directory (or dir default-directory))
         (process-environment (ez-review-process--env env))
         (path (ez-review-process--program-path program))
         (out (generate-new-buffer " *ez-review-out*"))
         (err (generate-new-buffer " *ez-review-err*"))
         (proc (make-process
                :name "ez-review"
                :buffer out
                :stderr err
                :command (cons path args)
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :sentinel
                (lambda (p _event)
                  (unless (process-live-p p)
                    ;; stderr is a separate pipe process: let it drain before reading.
                    (when-let* ((ep (get-buffer-process err)))
                      (let ((deadline (+ (float-time) 1.0)))
                        (while (and (process-live-p ep) (< (float-time) deadline))
                          (accept-process-output ep 0.02))))
                    (let ((code (process-exit-status p))
                          (stdout (with-current-buffer out (buffer-string)))
                          (stderr (with-current-buffer err (string-trim (buffer-string)))))
                      (kill-buffer out)
                      (kill-buffer err)
                      (funcall callback code stdout stderr)))))))
    ;; Emacs would otherwise append "Process ... finished" to the stderr buffer.
    (when-let* ((ep (get-buffer-process err)))
      (set-process-sentinel ep #'ignore))
    (when input
      (process-send-string proc input)
      (process-send-eof proc))
    proc))

(defun ez-review-process-parse-json (string)
  "Parse STRING as JSON into plists and lists; nil for empty STRING."
  (let ((s (string-trim string)))
    (unless (string-empty-p s)
      (json-parse-string s :object-type 'plist :array-type 'list
                         :null-object nil :false-object nil))))

;; Run several asynchronous jobs and join their results.
(defun ez-review-process-gather (thunks callback)
  "Run THUNKS, functions of one callback argument, and join the results.
CALLBACK gets the list of results in THUNKS order, or the first error string."
  (let* ((total (length thunks))
         (results (make-list total nil))
         (left total)
         (failed nil))
    (if (zerop total)
        (funcall callback nil)
      (cl-loop
       for thunk in thunks
       for i from 0
       do (let ((i i))
            (funcall thunk
                     (lambda (result)
                       (unless failed
                         (if (stringp result)
                             (progn (setq failed t) (funcall callback result))
                           (setf (nth i results) result)
                           (cl-decf left)
                           (when (zerop left) (funcall callback results)))))))))))

(defun ez-review-process-json (object)
  "Encode OBJECT (a plist with vectors for arrays) as a JSON string."
  (json-serialize object :null-object :null :false-object :false))

;; `gh api' and `glab api' print the server's reason as JSON on stdout while
;; stderr only has the status line, so an error needs both to be useful.
(defun ez-review-process-error-text (code stdout stderr program)
  "A readable failure message for PROGRAM from exit CODE, STDOUT and STDERR."
  (let* ((err (string-trim (or stderr "")))
         (detail
          (ignore-errors
            (let ((j (ez-review-process-parse-json stdout)))
              (when (and (consp j) (keywordp (car j)))
                (let ((msg (plist-get j :message))
                      (errs (plist-get j :errors)))
                  (string-join
                   (delq nil
                         (list (and (stringp msg) msg)
                               (cond ((stringp errs) errs)
                                     ((consp errs)
                                      (mapconcat (lambda (e) (if (stringp e) e (or (plist-get e :message) "")))
                                                 errs "; "))
                                     (t nil))))
                   " — "))))))
         (plain (string-trim (if (string-empty-p err) (or stdout "") ""))))
    (cond ((and detail (not (string-empty-p detail)))
           (if (string-empty-p err) detail (format "%s: %s" err detail)))
          ((not (string-empty-p err)) err)
          ((not (string-empty-p plain)) plain)
          (t (format "%s exited %s" program code)))))

(defun ez-review-process-check (result what)
  "Return stdout of RESULT (EXIT STDOUT STDERR) or signal for WHAT."
  (pcase-let ((`(,code ,out ,err) result))
    (if (eql code 0)
        out
      (signal 'ez-review-error
              (list (format "%s failed (exit %s)%s" what code
                            (if (string-empty-p err) "" (concat ": " err))))))))

(provide 'ez-review-process)
;;; ez-review-process.el ends here
