;;; ez-agents-persist.el --- Agents that survive Emacs closing -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; The `ghostel-tmux' backend.  Each agent runs in a detached tmux session on a
;; private socket (`tmux -L ez-agents', with a config that makes tmux invisible);
;; Ghostel merely attaches to it.  Closing Emacs, or killing the terminal
;; buffer, detaches and leaves the agent running.  A state file remembers what
;; each session was (project, worktree, branch, review progress) so
;; `ez-agents-restore' can rebuild the registry and reattach after a restart.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-agents)

(declare-function ghostel-exec "ghostel")
(declare-function ghostel-send-string "ghostel")
(defvar ghostel--process)
(defvar ghostel-exit-functions)

(defcustom ez-agents-tmux-socket "ez-agents"
  "Name of the private tmux socket (`tmux -L')."
  :type 'string
  :group 'ez-agents)

(defcustom ez-agents-data-directory (locate-user-emacs-file "ez-agents/")
  "Where the session state file lives."
  :type 'directory
  :group 'ez-agents)

(defconst ez-agents--tmux-conf
  (expand-file-name "ez-agents-tmux.conf"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "tmux configuration used for the private server.")

;;;; tmux plumbing

(defun ez-agents--tmux (&rest args)
  "Run tmux ARGS on the private socket.  Return (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((code (condition-case nil
                    (apply #'process-file "tmux" nil t nil
                           "-L" ez-agents-tmux-socket "-f" ez-agents--tmux-conf args)
                  (file-error 127))))
      (cons code (buffer-string)))))

(defvar ez-agents--tmux-cache (make-hash-table :test #'equal)
  "Short-lived cache of tmux answers: key -> (TIME . VALUE).")

(defun ez-agents--tmux-cached (key ttl thunk)
  "Value of THUNK, reused for TTL seconds under KEY.
The dashboard redraws twice a second; without this each redraw spawned several
tmux processes per agent from the UI thread."
  (let ((hit (gethash key ez-agents--tmux-cache)))
    (if (and hit (< (- (float-time) (car hit)) ttl))
        (cdr hit)
      (let ((v (funcall thunk)))
        (puthash key (cons (float-time) v) ez-agents--tmux-cache)
        v))))

(defun ez-agents--tmux-name (id) (concat "ez-" id))

(defun ez-agents--tmux-target (name) (concat "=" name ":"))

(defun ez-agents--tmux-has-p (name)
  (ez-agents--tmux-cached (list 'has name) 1.0
                          (lambda ()
                            (eq 0 (car (ez-agents--tmux "has-session" "-t" (concat "=" name)))))))

(defun ez-agents--tmux-session-names ()
  (let ((r (ez-agents--tmux "list-sessions" "-F" "#{session_name}")))
    (and (eq (car r) 0) (split-string (cdr r) "\n" t))))

(defun ez-agents--tmux-pane-pid (name)
  (let ((r (ez-agents--tmux "display-message" "-p" "-t" (ez-agents--tmux-target name)
                            "#{pane_pid}")))
    (and (eq (car r) 0) (string-to-number (string-trim (cdr r))))))

(defun ez-agents--tmux-new-session (name cwd env program args)
  "Create detached session NAME in CWD running PROGRAM with ARGS and ENV."
  (apply #'ez-agents--tmux "new-session" "-d" "-s" name "-c" (expand-file-name cwd)
         "-x" "200" "-y" "50"
         (append (cl-loop for e in env append (list "-e" e))
                 (list program) args)))

(defun ez-agents--tmux-send-literal (name string)
  "Type STRING into session NAME; carriage returns become Enter key presses."
  (let ((target (ez-agents--tmux-target name))
        (parts (split-string string "\r")))
    (cl-loop for (part . rest) on parts
             do (unless (string-empty-p part)
                  (ez-agents--tmux "send-keys" "-t" target "-l" "--" part))
             when rest do (ez-agents--tmux "send-keys" "-t" target "Enter"))))

(defun ez-agents--tmux-capture (name lines)
  (ez-agents--tmux-cached
   (list 'capture name lines) 1.0
   (lambda ()
     (let ((r (ez-agents--tmux "capture-pane" "-p" "-J" "-t" (ez-agents--tmux-target name)
                               "-S" (format "-%d" (* 4 (max lines 10))))))
       (when (eq (car r) 0)
         (last (cl-remove-if #'string-blank-p
                             (mapcar #'string-trim-right (split-string (cdr r) "\n")))
               lines))))))

(defun ez-agents--terminal-live-p (buffer)
  "Non-nil if BUFFER holds a Ghostel terminal with a running process."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (boundp 'ghostel--process) (process-live-p ghostel--process)))))

(defun ez-agents--tmux-attach (session buffer)
  "Attach SESSION's tmux session inside the Ghostel BUFFER."
  (require 'ghostel)
  (let ((default-directory (or (ez-agent-cwd session) default-directory)))
    (ez-agents--log "attach %s in %S: cwd=%s tmux=%s TERMINFO=%s"
                    (ez-agent-id session) buffer default-directory
                    (executable-find "tmux") (getenv "TERMINFO"))
    ;; `env' pins TERM to something every tmux has a terminfo entry for.
    (condition-case err
        (ghostel-exec buffer "env"
                      (list "TERM=xterm-256color"
                            (or (executable-find "tmux") "tmux")
                            "-L" ez-agents-tmux-socket "-f" ez-agents--tmux-conf
                            "attach-session" "-t" (concat "=" (ez-agent-tmux session))))
      (error (message "ez-agents: could not attach to %s: %s"
                      (ez-agent-tmux session) (error-message-string err))
             (signal (car err) (cdr err))))))

;;;; Backend methods

(cl-defmethod ez-agents-backend-start ((_ (eql ghostel-tmux)) session program args)
  (clrhash ez-agents--tmux-cache)
  (let* ((name (ez-agents--tmux-name (ez-agent-id session)))
         (env (append (cl-remove-if-not (lambda (e) (string-prefix-p "EZ_AGENT_" e))
                                        process-environment)
                      (list (concat "PATH=" (getenv "PATH")))))
         (r (ez-agents--tmux-new-session name default-directory env program args)))
    (unless (eq (car r) 0)
      (error "tmux could not start the agent: %s" (string-trim (cdr r))))
    (setf (ez-agent-tmux session) name)
    (ez-agents--tmux-attach session (ez-agent-buffer session))
    (ez-agents--tmux-pane-pid name)))

(cl-defmethod ez-agents-backend-send ((_ (eql ghostel-tmux)) session string)
  (let ((buf (ez-agent-buffer session)))
    (if (ez-agents--terminal-live-p buf)
        (with-current-buffer buf (ghostel-send-string string))
      (ez-agents--tmux-send-literal (ez-agent-tmux session) string))))

(cl-defmethod ez-agents-backend-alive-p ((_ (eql ghostel-tmux)) session)
  (and (ez-agent-tmux session) (ez-agents--tmux-has-p (ez-agent-tmux session))))

(cl-defmethod ez-agents-backend-text ((_ (eql ghostel-tmux)) session lines)
  (if (ez-agents--terminal-live-p (ez-agent-buffer session))
      (ez-agents-backend--buffer-text (ez-agent-buffer session) lines)
    (and (ez-agent-tmux session) (ez-agents--tmux-capture (ez-agent-tmux session) lines))))

(cl-defmethod ez-agents-backend-tick ((_ (eql ghostel-tmux)) session)
  (if (ez-agents--terminal-live-p (ez-agent-buffer session))
      (buffer-chars-modified-tick (ez-agent-buffer session))
    (and (ez-agent-tmux session)
         (sxhash-equal (ez-agents--tmux-capture (ez-agent-tmux session) 40)))))

(cl-defmethod ez-agents-backend-kill ((_ (eql ghostel-tmux)) session)
  (clrhash ez-agents--tmux-cache)
  (when (ez-agent-tmux session)
    (ez-agents--tmux "kill-session" "-t" (concat "=" (ez-agent-tmux session))))
  (let ((buf (ez-agent-buffer session)))
    (when (buffer-live-p buf)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

(cl-defmethod ez-agents-backend-attach ((_ (eql ghostel-tmux)) session buffer)
  (ez-agents--tmux-attach session buffer))

(cl-defmethod ez-agents-backend-install-exit-hook ((_ (eql ghostel-tmux)) function)
  (with-eval-after-load 'ghostel
    (add-hook 'ghostel-exit-functions function)))

;;;; State file

(defun ez-agents--state-file ()
  (expand-file-name "sessions.eld" ez-agents-data-directory))

(defun ez-agents--session->plist (s)
  (list :id (ez-agent-id s) :kind (ez-agent-kind s) :project (ez-agent-project s)
        :cwd (ez-agent-cwd s) :branch (ez-agent-branch s) :base (ez-agent-base s)
        :worktree (ez-agent-worktree s) :name (ez-agent-name s)
        :started (ez-agent-started s) :tmux (ez-agent-tmux s) :chat (ez-agent-chat s)
        :review-state (ez-agent-review-state s)
        :notes (ez-agent-notes s)
        :reviewed (let (acc)
                    (when (hash-table-p (ez-agent-reviewed s))
                      (maphash (lambda (k v) (push (cons k v) acc)) (ez-agent-reviewed s)))
                    acc)))

(defun ez-agents-save-state ()
  "Write persistent sessions to the state file."
  (let ((data (mapcar #'ez-agents--session->plist
                      (cl-remove-if-not #'ez-agent-tmux (ez-agents-sessions)))))
    ;; Nothing to remember and nothing to forget: leave the disk alone, so a
    ;; batch process (a compiler, a test run) that merely loaded this file
    ;; never creates state in the user's directory.
    (when (or data (file-exists-p (ez-agents--state-file)))
      (make-directory ez-agents-data-directory t)
      (let ((print-length nil) (print-level nil))
        (with-temp-file (ez-agents--state-file)
          (insert ";; ez-agents session state -*- mode: lisp-data -*-\n")
          (prin1 data (current-buffer))
          (insert "\n"))))))

(defun ez-agents--read-state ()
  (let ((f (ez-agents--state-file)))
    (when (file-readable-p f)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents f)
          (goto-char (point-min))
          (read (current-buffer)))))))

(defvar ez-agents--save-timer nil)

(defun ez-agents--schedule-save ()
  (unless (timerp ez-agents--save-timer)
    (setq ez-agents--save-timer
          (run-with-idle-timer 0.5 nil
                               (lambda ()
                                 (setq ez-agents--save-timer nil)
                                 (ignore-errors (ez-agents-save-state)))))))

;;;; Restore

(defun ez-agents--plist->session (p alive)
  (let ((h (make-hash-table :test #'equal)))
    (dolist (c (plist-get p :reviewed)) (puthash (car c) (cdr c) h))
    (ez-agent--create
     :id (plist-get p :id) :kind (plist-get p :kind) :project (plist-get p :project)
     :cwd (plist-get p :cwd) :branch (plist-get p :branch) :base (plist-get p :base)
     :worktree (plist-get p :worktree) :name (plist-get p :name)
     :started (or (plist-get p :started) (float-time)) :activity (float-time)
     :tmux (plist-get p :tmux) :chat (plist-get p :chat)
     :backend 'ghostel-tmux :source 'restored
     :review-state (plist-get p :review-state) :notes (plist-get p :notes)
     :reviewed h :status (if alive 'idle 'done)
     :pid (and alive (ez-agents--tmux-pane-pid (plist-get p :tmux))))))

(defun ez-agents--adopt-orphan (name)
  "Register the running tmux session NAME that Emacs has no record of.
Returns the session, or nil when its agent cannot be identified."
  (let* ((r (ez-agents--tmux "display-message" "-p" "-t" (ez-agents--tmux-target name)
                             "#{pane_start_command}\t#{pane_current_path}\t#{session_created}"))
         (f (and (eq (car r) 0) (split-string (string-trim-right (cdr r) "\n") "\t")))
         (program (and f (file-name-nondirectory
                          (car (split-string (string-trim (car f) "[\"']+" "[\"']+") " " t)))))
         (kind (and program
                    (car (cl-find-if
                          (lambda (d) (equal program (file-name-nondirectory
                                                      (car (plist-get (cdr d) :command)))))
                          ez-agents-definitions))))
         (cwd (and f (nth 1 f))))
    (when (and kind cwd (file-directory-p cwd))
      (require 'ez-agents-git)
      (let* ((cwd (file-name-as-directory cwd))
             (id (string-remove-prefix "ez-" name))
             (root (or (ez-agents-git-main-root cwd) cwd))
             (s (ez-agent--create
                 :id id :kind kind :project root :cwd cwd :tmux name :backend 'ghostel-tmux
                 :name (let ((base (plist-get (ez-agents-definition kind) :name))
                             (n (1+ (cl-count-if (lambda (o) (and (eq (ez-agent-kind o) kind)
                                                                  (equal (ez-agent-project o) root)))
                                                 (ez-agents-sessions)))))
                         (if (> n 1) (format "%s #%d" base n) base))
                 :status 'idle
                 :started (or (and (nth 2 f) (string-to-number (nth 2 f))) (float-time))
                 :activity (float-time) :source 'adopted
                 :pid (ez-agents--tmux-pane-pid name)
                 :base (ez-agents-git-head cwd) :branch (ez-agents-git-branch cwd)
                 :reviewed (make-hash-table :test #'equal))))
        (puthash id s ez-agents--table)
        s))))

;;;###autoload
(defun ez-agents-restore (&optional quiet)
  "Rebuild sessions from the state file and the running tmux sessions.
Agents still running come back detached; use `RET' on them to reattach.
Agents whose tmux session is gone come back as ended (see `ez-agents-resume').
Running agent sessions with no record (Emacs ended before saving, or the state
file was lost) are adopted too, so nothing keeps running out of reach."
  (interactive)
  (let ((live (ez-agents--tmux-session-names)) (n 0))
    (dolist (p (ez-agents--read-state))
      (let ((id (plist-get p :id)))
        (unless (or (null id) (ez-agents-session id))
          (let ((alive (member (plist-get p :tmux) live)))
            (puthash id (ez-agents--plist->session p alive) ez-agents--table)
            (cl-incf n)))))
    (dolist (name live)
      (when (and (string-prefix-p "ez-" name)
                 (not (cl-find name (ez-agents-sessions) :key #'ez-agent-tmux :test #'equal)))
        (when (ez-agents--adopt-orphan name) (cl-incf n))))
    (when (> n 0)
      (ez-agents--changed)
      (require 'ez-agents-status)
      (ez-agents-status-ensure-timer))
    (unless quiet (message "ez-agents: restored %d session%s" n (if (= n 1) "" "s")))
    n))

;;;###autoload
(defun ez-agents-attach (session &optional quiet)
  "Reattach SESSION's terminal (a detached persistent session) and show it.
With QUIET, only create the terminal buffer and do not display it."
  (interactive (list (ez-agents-read-session "Attach: ")))
  (unless (ez-agents-live-p session) (user-error "That session has ended"))
  (let ((buf (generate-new-buffer
              (format "*agent:%s:%s*" (ez-agents-project-name (ez-agent-project session))
                      (ez-agent-id session)))))
    (setf (ez-agent-buffer session) buf)
    (ez-agents--tmux-attach session buf)
    (ez-agents--install-buffer-hook session)
    (ez-agents-backend-install-exit-hook 'ghostel-tmux #'ez-agents--on-exit)
    (ez-agents--changed)
    (unless quiet (ez-agents-jump session))))

(add-hook 'ez-agents-change-hook #'ez-agents--schedule-save)
(add-hook 'kill-emacs-hook #'ez-agents-save-state)

(provide 'ez-agents-persist)
;;; ez-agents-persist.el ends here
