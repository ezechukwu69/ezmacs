;;; ez-agents-status.el --- Heuristic status detection for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Fallback status layers used when an agent sends no hook events: terminal
;; activity (output within `ez-agents-activity-window' seconds means working)
;; and the process tree (agent binaries running under a session's process show
;; up as sub-agents).  Hook events always win: a session that has ever sent one
;; is never touched by the activity heuristic.

;;; Code:

(require 'cl-lib)
(require 'ez-agents)
(require 'ez-agents-review)

(defcustom ez-agents-activity-window 1.5
  "Seconds of silence after which a heuristic-tracked session counts as idle."
  :type 'number
  :group 'ez-agents)

(defvar ez-agents--status-timer nil)

(defun ez-agents-status-ensure-timer ()
  (unless (timerp ez-agents--status-timer)
    (setq ez-agents--status-timer (run-with-timer 1 1 #'ez-agents-status-poll))))

(defun ez-agents--process-table ()
  "Return a list of (PID PPID COMM) for every process, or nil on failure."
  (ignore-errors
    (with-temp-buffer
      (when (zerop (call-process "ps" nil t nil "-A" "-o" "pid=,ppid=,comm="))
        (goto-char (point-min))
        (let (rows)
          (while (re-search-forward
                  "^ *\\([0-9]+\\) +\\([0-9]+\\) +\\(.+\\)$" nil t)
            (push (list (string-to-number (match-string 1))
                        (string-to-number (match-string 2))
                        (file-name-nondirectory (match-string 3)))
                  rows))
          rows)))))

(defun ez-agents--descendants (pid table)
  "Rows of TABLE that descend from PID."
  (let ((frontier (list pid)) found)
    (while frontier
      (let ((parent (pop frontier)))
        (dolist (row table)
          (when (and (= (nth 1 row) parent) (not (memq row found)))
            (push row found)
            (push (car row) frontier)))))
    found))

(defun ez-agents--kind-for-command (comm)
  "Agent kind whose program basename is COMM, or nil."
  (car (cl-find-if (lambda (d)
                     (equal comm (file-name-nondirectory
                                  (car (plist-get (cdr d) :command)))))
                   ez-agents-definitions)))

(defun ez-agents--poll-processes (session table)
  "Mirror agent binaries below SESSION's pid as process sub-agents."
  (let ((changed nil) (live nil))
    (dolist (row (ez-agents--descendants (ez-agent-pid session) table))
      (when-let* ((kind (ez-agents--kind-for-command (nth 2 row))))
        (let ((sid (format "proc:%d" (car row))))
          (push sid live)
          (unless (ez-agents-session sid)
            (ez-agents--add-sub session sid (symbol-name kind) 'proc kind)
            (setq changed t)))))
    (dolist (c (ez-agents-sessions (ez-agent-id session)))
      (when (and (eq (ez-agent-source c) 'proc)
                 (eq (ez-agent-status c) 'working)
                 (not (member (ez-agent-id c) live)))
        (ez-agents-set-status c 'done)
        (setq changed t)))
    changed))

(defun ez-agents--poll-activity (session)
  "Update SESSION's status from terminal output.  Return non-nil if changed."
  (when (and (not (ez-agent-hook-p session))
             (memq (ez-agent-status session) '(starting working idle)))
    (let* ((tick (ez-agents-backend-tick (ez-agents--bk session) session))
           (now (float-time)))
      (unless (eql tick (ez-agent-tick session))
        (setf (ez-agent-tick session) tick
              (ez-agent-activity session) now))
      (let ((new (cond ((< (- now (ez-agent-activity session)) ez-agents-activity-window)
                        'working)
                       ((eq (ez-agent-status session) 'starting) 'starting)
                       (t 'idle)))
            (activity (ez-agent-activity session)))
        (prog1 (ez-agents-set-status session new)
          ;; `ez-agents-set-status' stamps activity; keep the real value.
          (setf (ez-agent-activity session) activity))))))

(defun ez-agents--prune ()
  "Drop finished sub-agents older than `ez-agents-finished-ttl'."
  (let ((now (float-time)) changed)
    (dolist (s (cl-loop for s being the hash-values of ez-agents--table
                        when (and (ez-agent-parent s) (eq (ez-agent-status s) 'done)
                                  (> (- now (ez-agent-activity s)) ez-agents-finished-ttl))
                        collect s))
      (remhash (ez-agent-id s) ez-agents--table)
      (setq changed t))
    changed))

(defun ez-agents-status-poll ()
  "Timer entry point: refresh heuristic status of every session."
  (let ((sessions (ez-agents-sessions)) (changed nil) table)
    (if (null sessions)
        (progn (cancel-timer ez-agents--status-timer)
               (setq ez-agents--status-timer nil))
      (when (cl-some #'ez-agent-pid sessions)
        (setq table (ez-agents--process-table)))
      (dolist (s sessions)
        (when (or (buffer-live-p (ez-agent-buffer s)) (ez-agent-tmux s))
          (when (and (memq (ez-agent-status s) '(starting working idle waiting))
                     (not (ez-agents-live-p s))
                     (> (- (float-time) (ez-agent-started s)) 3))
            ;; Process ended without the exit hook firing.
            (when (ez-agents-set-status s 'done) (setq changed t)))
          (when (ez-agents--poll-activity s) (setq changed t))
          (when (ignore-errors (ez-agents-review-refresh-stats s)) (setq changed t))
          (when (and table (ez-agent-pid s) (ez-agents--poll-processes s table))
            (setq changed t))))
      (when (ez-agents--prune) (setq changed t))
      (when changed (ez-agents--changed)))))

(provide 'ez-agents-status)
;;; ez-agents-status.el ends here
