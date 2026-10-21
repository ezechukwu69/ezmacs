;;; ez-agents-backend.el --- Terminal backends for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Everything that touches a terminal emulator or multiplexer lives behind the
;; generic functions below, which take a session (an `ez-agent').  Backends:
;;
;;   `ghostel'       the agent is a child of the Ghostel terminal (dies with Emacs)
;;   `ghostel-tmux'  the agent runs in a detached tmux session that Ghostel
;;                   attaches to, so it survives Emacs closing
;;                   (see `ez-agents-persist.el')

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function ghostel-exec "ghostel")
(declare-function ghostel-send-string "ghostel")
(declare-function ez-agent-buffer "ez-agents")
(defvar ghostel--process)
(defvar ghostel-exit-functions)

(defcustom ez-agents-backend 'auto
  "Terminal backend used to run agents.
`auto' picks `ghostel-tmux' when `ez-agents-persistence' is non-nil and tmux
is installed, else `ghostel'."
  :type '(choice (const auto) (const ghostel) (const ghostel-tmux))
  :group 'ez-agents)

(defcustom ez-agents-persistence t
  "Non-nil: run agents in tmux so they survive Emacs closing."
  :type 'boolean
  :group 'ez-agents)

(defun ez-agents-backend-resolve ()
  "The backend symbol new sessions will use."
  (if (eq ez-agents-backend 'auto)
      (if (and ez-agents-persistence (executable-find "tmux")) 'ghostel-tmux 'ghostel)
    ez-agents-backend))

(cl-defgeneric ez-agents-backend-start (backend session program args)
  "Run PROGRAM with ARGS for SESSION using BACKEND.  Return a pid or nil.
`default-directory' is the working directory and `process-environment'
carries the EZ_AGENT_* variables.")

(cl-defgeneric ez-agents-backend-send (backend session string)
  "Send STRING as input to SESSION's terminal.")

(cl-defgeneric ez-agents-backend-alive-p (backend session)
  "Non-nil if SESSION's agent process is still running.")

(cl-defgeneric ez-agents-backend-text (backend session lines)
  "Return the last LINES non-blank lines of SESSION's terminal text.")

(cl-defgeneric ez-agents-backend-tick (backend session)
  "Return a value that changes whenever SESSION's terminal output changes.")

(cl-defgeneric ez-agents-backend-kill (backend session)
  "Terminate SESSION's agent and its terminal.")

(cl-defgeneric ez-agents-backend-attach (backend session buffer)
  "Show SESSION's terminal in BUFFER (used to reattach after Emacs restarts).")

(cl-defgeneric ez-agents-backend-install-exit-hook (backend function)
  "Arrange for FUNCTION to be called with (BUFFER EVENT) when a terminal exits.")

(defun ez-agents-backend--buffer-text (buffer lines)
  "Last LINES non-blank lines of BUFFER's text."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((text (buffer-substring-no-properties
                    (max (point-min) (- (point-max) 6000)) (point-max)))
             (rows (cl-remove-if #'string-blank-p
                                 (mapcar #'string-trim-right (split-string text "\n")))))
        (last rows lines)))))

;;;; Ghostel

(cl-defmethod ez-agents-backend-start ((_ (eql ghostel)) session program args)
  (require 'ghostel)
  (let ((proc (ghostel-exec (ez-agent-buffer session) program args)))
    (and (processp proc) (process-id proc))))

(cl-defmethod ez-agents-backend-send ((_ (eql ghostel)) session string)
  (with-current-buffer (ez-agent-buffer session)
    (ghostel-send-string string)))

(cl-defmethod ez-agents-backend-alive-p ((_ (eql ghostel)) session)
  (let ((buf (ez-agent-buffer session)))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (and (boundp 'ghostel--process) (process-live-p ghostel--process))))))

(cl-defmethod ez-agents-backend-text ((_ (eql ghostel)) session lines)
  (ez-agents-backend--buffer-text (ez-agent-buffer session) lines))

(cl-defmethod ez-agents-backend-tick ((_ (eql ghostel)) session)
  (let ((buf (ez-agent-buffer session)))
    (and (buffer-live-p buf) (buffer-chars-modified-tick buf))))

(cl-defmethod ez-agents-backend-kill ((_ (eql ghostel)) session)
  (let ((buf (ez-agent-buffer session)))
    (when (buffer-live-p buf)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

(cl-defmethod ez-agents-backend-attach ((_ (eql ghostel)) _session _buffer)
  nil)

(cl-defmethod ez-agents-backend-install-exit-hook ((_ (eql ghostel)) function)
  (with-eval-after-load 'ghostel
    (add-hook 'ghostel-exit-functions function)))

(provide 'ez-agents-backend)
;;; ez-agents-backend.el ends here
