;;; ez-agents.el --- Manage terminal coding agents (Claude Code, Codex, ...) -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Author: Ezechukwu Ojukwu
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ghostel "0.1") (magit-section "4.0"))
;; Keywords: tools, processes, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Optional: nerd-icons (agent and project icons; plain glyphs without it).

;;; Commentary:

;; Run several terminal coding agents at once, each in its own terminal buffer,
;; and watch them from a sidebar (see `ez-agents-ui'): project -> session ->
;; sub-agents.  Status comes from three layers, strongest first:
;;
;;   1. Agent hooks (Claude Code): `ez-agents-install-hooks' wires a project's
;;      `.claude/settings.local.json' to `ez-agents-hook.sh', which calls
;;      `ez-agents-event' in this Emacs.  This is the only source of "waiting
;;      for input" and of Task/sub-agent lifecycles.
;;   2. Process tree: agent binaries running under a session's process.
;;   3. Terminal activity: output seen within the last second means "working".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'json)
(require 'ez-agents-backend)

(declare-function ez-agents-status-ensure-timer "ez-agents-status")
(defvar server-name)
(defvar server-use-tcp)
(defvar server-socket-dir)

(defgroup ez-agents nil
  "Manage multiple terminal coding agents."
  :group 'tools
  :prefix "ez-agents-")

(defcustom ez-agents-debug t
  "Non-nil: append attach/layout/exit events to `ez-agents-debug-log-file'."
  :type 'boolean)

(defvar ez-agents-data-directory)

(defun ez-agents-debug-log-file ()
  "File the debug log is written to."
  (expand-file-name "ez-agents-debug.log"
                    (if (boundp 'ez-agents-data-directory)
                        ez-agents-data-directory
                      (locate-user-emacs-file "ez-agents/"))))

(defun ez-agents--log (fmt &rest args)
  "Append a timestamped line to the debug log (never signals)."
  (when ez-agents-debug
    (ignore-errors
      (let ((file (ez-agents-debug-log-file)))
        (make-directory (file-name-directory file) t)
        (when (> (or (file-attribute-size (file-attributes file)) 0) 400000)
          (with-temp-file file (insert "[log truncated]\n")))
        (write-region (format "[%s emacs=%d] %s\n" (format-time-string "%H:%M:%S.%3N") (emacs-pid)
                              (apply #'format fmt args))
                      nil file t 'silent)))))

(defun ez-agents--layout-string ()
  "The selected frame's windows as text, for the debug log."
  (mapconcat (lambda (w) (format "%s[%dx%d%s]" (buffer-name (window-buffer w))
                                 (window-total-width w) (window-total-height w)
                                 (if (eq w (selected-window)) "*" "")))
             (window-list nil 'no-minibuf) " "))

(defun ez-agents--log-snapshot (label session)
  "Log the state of SESSION's terminal and the window layout."
  (let ((buf (ez-agent-buffer session)))
    (ez-agents--log "%s %s: buffer=%S live=%S process=%S terminal-live=%S layout=%s"
                    label (ez-agent-id session) buf (buffer-live-p buf)
                    (and (buffer-live-p buf)
                         (condition-case nil (buffer-local-value 'ghostel--process buf) (error nil)))
                    (and (fboundp 'ez-agents--terminal-live-p) (ez-agents--terminal-live-p buf))
                    (ez-agents--layout-string))))

(defun ez-agents-debug-report ()
  "Show the debug log."
  (interactive)
  (find-file-other-window (ez-agents-debug-log-file))
  (goto-char (point-max)))

(defvar ez-agents--own-server nil)

(defun ez-agents--server-socket ()
  "Socket of an emacsclient server that belongs to *this* Emacs, or nil.
When another Emacs already owns the default server, start a uniquely named one
so agents report their status here and not to that other Emacs."
  (require 'server)
  (unless (and (boundp 'server-process) (process-live-p server-process))
    (let ((server-name (format "ez-agents-%d" (emacs-pid))))
      (ignore-errors (server-start))))
  (and (boundp 'server-process) (process-live-p server-process)
       (not (bound-and-true-p server-use-tcp))
       (let ((svc (process-contact server-process :service)))
         (and (stringp svc) svc))))

(defcustom ez-agents-definitions
  '((claude :name "Claude Code" :command ("claude") :icon "nf-md-creation" :hooks claude
            :resume ("claude" "--continue") :resume-id ("claude" "--resume" :id)
            :chats ez-agents-chats--claude)
    (codex  :name "Codex"       :command ("codex")  :icon "nf-md-hexagon_multiple_outline"
            :resume ("codex" "resume" "--last") :resume-id ("codex" "resume" :id)
            :chats ez-agents-chats--codex)
    (cursor :name "Cursor"      :command ("cursor-agent") :icon "nf-md-cursor_default_outline"
            :resume ("cursor-agent" "resume"))
    (gemini :name "Gemini"      :command ("gemini") :icon "nf-md-google"
            :resume ("gemini" "--resume" "latest")))
  "Agents that can be started.  Each entry is (KIND . PLIST).
PLIST keys: `:name' display name, `:command' program and arguments,
`:icon' a nerd-icons mdicon name, `:hooks' set to `claude' when the agent
understands Claude Code hooks, `:resume' the command that continues its last
conversation, `:resume-id' the same with `:id' standing for a chat id, and
`:chats' a function listing the chats stored for a directory (see
`ez-agents-chats.el')."
  :type '(alist :key-type symbol :value-type plist))

(defcustom ez-agents-install-hooks-policy 'ask
  "What to do when a hook-capable agent starts in a project without hooks.
`ask' prompts once per project per Emacs session, `always' installs
silently, `never' relies on the process and activity heuristics."
  :type '(choice (const ask) (const always) (const never)))

(defcustom ez-agents-notify-function #'ez-agents-default-notify
  "Called with a session when it starts waiting for input."
  :type 'function)

(defcustom ez-agents-finished-ttl 120
  "Seconds a finished sub-agent stays in the sidebar."
  :type 'integer)

(defvar ez-agents-change-hook nil
  "Hook run after any session is added, removed or changes status.")

(defconst ez-agents--hook-script
  (expand-file-name "ez-agents-hook.sh"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "Script that forwards agent hook payloads to Emacs.")

;;;; Registry

(cl-defstruct (ez-agent (:constructor ez-agent--create) (:copier nil))
  id kind project buffer name status parent title started activity
  tick hook-p pid source
  ;; where it runs and what it changes
  cwd branch base worktree
  ;; terminal backend, tmux session name (persistent sessions)
  backend tmux
  ;; review: diffstat (FILES ADD DEL), stats-time, reviewed (path -> diff hash),
  ;; notes ((PATH LINE TEXT) ...), review-state (approved / changes / nil)
  diffstat stats-time reviewed notes review-state
  ;; the agent's own conversation id (from hooks or a resumed chat)
  chat
  ;; why and how its terminal ended: (REASON LAST-OUTPUT-LINE ...)
  exit-note)

(defvar ez-agents--table (make-hash-table :test #'equal)
  "Session id -> `ez-agent'.")

(defvar ez-agents--counter 0)
(defvar ez-agents--hooks-declined nil "Project roots whose hook prompt was declined.")

(defun ez-agents--changed ()
  (run-hooks 'ez-agents-change-hook))

(defun ez-agents-session (id)
  "Return the session with ID, or nil."
  (gethash id ez-agents--table))

(defun ez-agents-sessions (&optional parent)
  "Sessions whose parent id is PARENT (nil: top-level), oldest first."
  (sort (cl-loop for s being the hash-values of ez-agents--table
                 when (equal (ez-agent-parent s) parent) collect s)
        (lambda (a b) (< (ez-agent-started a) (ez-agent-started b)))))

(defun ez-agents-projects ()
  "Project roots that have top-level sessions, in order of first use."
  (let (roots)
    (dolist (s (ez-agents-sessions))
      (cl-pushnew (ez-agent-project s) roots :test #'equal))
    (nreverse roots)))

(defun ez-agents-project-name (root)
  (file-name-nondirectory (directory-file-name root)))

(defun ez-agents-definition (kind)
  (or (cdr (assq kind ez-agents-definitions))
      (user-error "Unknown agent kind: %s" kind)))

(defun ez-agents--normalize-root (dir)
  (file-name-as-directory (expand-file-name dir)))

(defcustom ez-agents-project-chooser nil
  "Function returning the directory to start an agent in, or nil.
Called when the current buffer is not inside a project (typically *scratch* in
the home directory), so you choose where the agent runs at the moment you start
it.  When nil, the current directory is used."
  :type '(choice (const :tag "Use the current directory" nil) function))

(defun ez-agents--current-root ()
  "Directory an agent should start in: the current project's root, else whatever
`ez-agents-project-chooser' picks, else the current directory."
  (ez-agents--normalize-root
   (cond ((project-current) (project-root (project-current)))
         (ez-agents-project-chooser (funcall ez-agents-project-chooser))
         (t default-directory))))

(defun ez-agents--remove (id)
  "Remove session ID and its children."
  (dolist (c (ez-agents-sessions id))
    (ez-agents--remove (ez-agent-id c)))
  (remhash id ez-agents--table))

(defun ez-agents-set-status (session status)
  "Set SESSION's STATUS.  Return non-nil when it changed."
  (unless (eq (ez-agent-status session) status)
    (setf (ez-agent-status session) status
          (ez-agent-activity session) (float-time))
    (when (and (eq status 'waiting) (not (ez-agent-parent session)))
      (funcall ez-agents-notify-function session))
    t))

(defun ez-agents-default-notify (session)
  (message "Agent %s (%s) needs your input"
           (ez-agent-name session)
           (ez-agents-project-name (ez-agent-project session))))

(defun ez-agents--bk (session)
  "The backend symbol SESSION runs on."
  (or (ez-agent-backend session) 'ghostel))

(defun ez-agents-live-p (session)
  (ez-agents-backend-alive-p (ez-agents--bk session) session))

(defun ez-agents-detached-p (session)
  "Non-nil if SESSION's agent runs but no Emacs terminal is attached to it."
  (and (ez-agent-tmux session)
       (not (and (buffer-live-p (ez-agent-buffer session))
                 (fboundp 'ez-agents--terminal-live-p)
                 (ez-agents--terminal-live-p (ez-agent-buffer session))))
       (ez-agents-live-p session)))

;;;; Spawning

(defvar ghostel-kill-buffer-on-exit)
(declare-function ez-agents--terminal-live-p "ez-agents-persist")
(declare-function ez-agents-attach "ez-agents-persist")
(declare-function ez-agents-git-head "ez-agents-git")
(declare-function ez-agents-git-branch "ez-agents-git")
(declare-function ez-agents-git-main-root "ez-agents-git")
(declare-function ez-agents-worktree-choose-spec "ez-agents-worktree")

(defun ez-agents--new-id ()
  "A short random id, unique in the registry and across restarts."
  (let (id)
    (while (or (null id) (ez-agents-session id))
      (setq id (format "a%06x" (random #xffffff))))
    id))

(defun ez-agents--buffer-killed (id)
  "A session's terminal buffer was killed: detach, or keep it as ended.
Only an explicit kill (`ez-agents-kill') forgets a session, so one whose agent
ended unexpectedly stays visible with the reason."
  (ez-agents--log "terminal buffer of %s killed; status=%S; called from:\n%s" id
                  (and (ez-agents-session id) (ez-agent-status (ez-agents-session id)))
                  (let ((bt (ignore-errors (backtrace-to-string))))
                    (string-join (seq-take (split-string (or bt "") "\n" t) 14) "\n")))
  (when-let* ((s (ez-agents-session id)))
    (setf (ez-agent-buffer s) nil)
    (unless (or (and (ez-agent-tmux s) (ez-agents-live-p s))
                (memq (ez-agent-status s) '(done error)))
      (ez-agents-set-status s 'done)))
  (ez-agents--changed))

(defun ez-agents--install-buffer-hook (session)
  (let ((id (ez-agent-id session)) (buf (ez-agent-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (add-hook 'kill-buffer-hook (lambda () (ez-agents--buffer-killed id)) nil t)))))

;;;###autoload
(defun ez-agents-spawn (kind &optional project spec)
  "Start agent KIND in PROJECT (a directory; default the current project).
SPEC is a plist: `:cwd' working directory (a worktree), `:branch', `:base'
(the commit reviews diff against), `:worktree' non-nil if SPEC's cwd is a
managed worktree, `:command' to replace the agent's usual command."
  (require 'ez-agents-git)
  (let* ((def (ez-agents-definition kind))
         (root (ez-agents--normalize-root (or project (ez-agents--current-root))))
         (cwd (ez-agents--normalize-root (or (plist-get spec :cwd) root)))
         (id (ez-agents--new-id))
         (label (plist-get def :name))
         (n (1+ (cl-count-if (lambda (s) (and (eq (ez-agent-kind s) kind)
                                              (equal (ez-agent-project s) root)))
                             (ez-agents-sessions))))
         (backend (ez-agents-backend-resolve))
         (cmd (or (plist-get spec :command) (plist-get def :command)))
         (buf (generate-new-buffer
               (format "*agent:%s:%s-%d*" (ez-agents-project-name root) kind n))))
    (unless (executable-find (car cmd))
      (kill-buffer buf)
      (user-error "%s not found in PATH" (car cmd)))
    (when (eq backend 'ghostel-tmux) (require 'ez-agents-persist))
    (when (plist-get def :hooks)
      (ez-agents--maybe-install-hooks cwd))
    (let* ((default-directory cwd)
           (process-environment
            (append (list (format "EZ_AGENT_SESSION=%s" id))
                    (when-let* ((c (executable-find "emacsclient")))
                      (list (format "EZ_AGENT_EMACSCLIENT=%s" c)))
                    (when-let* ((sock (ez-agents--server-socket)))
                      (list (format "EZ_AGENT_SOCKET=%s" sock)))
                    process-environment))
           (session (ez-agent--create
                     :id id :kind kind :project root :cwd cwd :buffer buf
                     :name (if (> n 1) (format "%s #%d" label n) label)
                     :status 'starting :started (float-time)
                     :activity (float-time) :source 'spawn :backend backend
                     :base (or (plist-get spec :base) (ez-agents-git-head cwd))
                     :branch (or (plist-get spec :branch) (ez-agents-git-branch cwd))
                     :worktree (plist-get spec :worktree)
                     :chat (plist-get spec :chat)
                     :reviewed (make-hash-table :test #'equal))))
      (puthash id session ez-agents--table)
      (ez-agents--log "spawn %s kind=%s backend=%s cwd=%s command=%S" id kind backend cwd cmd)
      (condition-case err
          (setf (ez-agent-pid session)
                (ez-agents-backend-start backend session (car cmd) (cdr cmd)))
        (error (ignore-errors (ez-agents-backend-kill backend session)) ; no orphaned tmux session
               (remhash id ez-agents--table)
               (when (buffer-live-p buf) (kill-buffer buf))
               (signal (car err) (cdr err))))
      (ez-agents--install-buffer-hook session)
      (ez-agents-backend-install-exit-hook backend #'ez-agents--on-exit)
      (ez-agents--changed)
      (require 'ez-agents-status)
      (ez-agents-status-ensure-timer)
      (ez-agents--watch session "spawned")
      session)))

(defun ez-agents--watch (session label)
  "Log SESSION's terminal state now and shortly after, to catch early deaths."
  (ez-agents--log-snapshot label session)
  (dolist (delay '(0.5 2 6))
    (run-at-time delay nil
                 (lambda ()
                   (when (ez-agents-session (ez-agent-id session))
                     (ez-agents--log-snapshot (format "+%ss" delay) session))))))

(defun ez-agents--on-exit (buffer event)
  "A session's terminal process exited (EVENT says how).
Runs inside Ghostel's sentinel, which kills BUFFER right after this hook, so
keep it (the agent's last words are the reason it stopped) and decide what
happened a moment later, once tmux has dropped the session of an agent that
just exited."
  (when-let* ((s (cl-find buffer (ez-agents-sessions) :key #'ez-agent-buffer)))
    (let ((tail (ez-agents-backend--buffer-text buffer 12)))
      (setf (ez-agent-exit-note s) (cons (format "terminal exited: %s" (string-trim event)) tail))
      (ez-agents--log "terminal of %s exited: event=%S last output:\n  %s"
                      (ez-agent-id s) event (string-join (or tail '("(nothing)")) "\n  ")))
    (with-current-buffer buffer (setq-local ghostel-kill-buffer-on-exit nil))
    (run-at-time 0.4 nil #'ez-agents--settle-exit (ez-agent-id s) event)))

(defun ez-agents--settle-exit (id event)
  "Decide, shortly after a terminal exit, whether agent ID ended or only detached."
  (when-let* ((s (ez-agents-session id)))
    (when (boundp 'ez-agents--tmux-cache) (clrhash ez-agents--tmux-cache))
    (let ((alive (and (ez-agent-tmux s) (ez-agents-live-p s))))
      (ez-agents--log "settled exit of %s: agent still running in tmux=%S" id alive)
      (if alive
          (message "ez-agents: %s's terminal exited (%s) but the agent is still running in tmux; RET reattaches"
                   (ez-agent-name s) (string-trim event))
        (let* ((quick (< (- (float-time) (ez-agent-started s)) 20))
               (why (string-join (last (cl-remove-if #'string-blank-p
                                                     (cdr (ez-agent-exit-note s)))
                                       2)
                                 " ")))
          (ez-agents-set-status s (if (or quick (not (string-match-p "\\`finished" event)))
                                      'error 'done))
          (dolist (c (ez-agents-sessions id)) (ez-agents-set-status c 'done))
          (message "ez-agents: %s %s%s" (ez-agent-name s)
                   (if quick "stopped right after starting" "ended")
                   (if (string-empty-p why) "" (concat ": " why))))))
    (ez-agents--changed)))

(defun ez-agents-read-session (prompt)
  "Read a top-level session with completion."
  (let* ((cands (mapcar (lambda (s)
                          (cons (format "%s · %s  [%s]"
                                        (ez-agents-project-name (ez-agent-project s))
                                        (ez-agent-name s) (ez-agent-status s))
                                s))
                        (ez-agents-sessions)))
         (pick (and cands (completing-read prompt cands nil t))))
    (if pick (cdr (assoc pick cands)) (user-error "No agent sessions"))))

;;;###autoload
(defun ez-agents--resume-command (kind &optional chat-id)
  "Command that resumes agent KIND's chat CHAT-ID, or its latest chat when nil."
  (let* ((def (ez-agents-definition kind))
         (tpl (plist-get def :resume-id)))
    (if (and chat-id tpl)
        (mapcar (lambda (x) (if (eq x :id) chat-id x)) tpl)
      (plist-get def :resume))))

;;;###autoload
(defun ez-agents-resume (session)
  "Start SESSION's agent again with its resume command, in the same place.
For an agent that ended (or its tmux session died) this continues the
conversation, but not any work that was in flight."
  (interactive (list (ez-agents-read-session "Resume: ")))
  (let ((cmd (ez-agents--resume-command (ez-agent-kind session) (ez-agent-chat session))))
    (unless cmd (user-error "%s has no resume command" (ez-agent-name session)))
    (when (ez-agents-live-p session) (user-error "That agent is still running"))
    (let ((new (ez-agents-spawn (ez-agent-kind session) (ez-agent-project session)
                                (list :cwd (ez-agent-cwd session) :branch (ez-agent-branch session)
                                      :base (ez-agent-base session)
                                      :worktree (ez-agent-worktree session) :command cmd
                                      :chat (ez-agent-chat session)))))
      (setf (ez-agent-reviewed new) (ez-agent-reviewed session)
            (ez-agent-notes new) (ez-agent-notes session)
            (ez-agent-name new) (ez-agent-name session))
      (ez-agents--remove (ez-agent-id session))
      (ez-agents--changed)
      (ez-agents-jump new))))

;;;; Hook events

(defun ez-agents--decode (b64)
  (when (and b64 (not (string-empty-p b64)))
    (ignore-errors
      (json-parse-string (decode-coding-string (base64-decode-string b64) 'utf-8)
                         :object-type 'alist))))

(defun ez-agents--agent-tool-p (tool)
  (member tool '("Task" "Agent")))

;;;###autoload
(defun ez-agents-event (id event &optional payload)
  "Handle hook EVENT for session ID; PAYLOAD is the base64 JSON hook input.
Called from `ez-agents-hook.sh' through emacsclient."
  (let ((s (ez-agents-session id))
        (data (ez-agents--decode payload)))
    (if (not s)
        "unknown"
      (setf (ez-agent-hook-p s) t)
      (when-let* ((chat (alist-get 'session_id data)))
        (setf (ez-agent-chat s) chat))
      (let* ((tool (alist-get 'tool_name data))
             (use-id (alist-get 'tool_use_id data))
             (changed
              (pcase event
                ((or "SessionStart" "Stop")
                 (prog1 (ez-agents-set-status s 'idle)
                   (when (equal event "Stop")
                     (dolist (c (ez-agents-sessions id))
                       (when (eq (ez-agent-status c) 'working)
                         (ez-agents-set-status c 'done))))))
                ("Notification" (ez-agents-set-status s 'waiting))
                ("SessionEnd" (ez-agents-set-status s 'done))
                ("PreToolUse"
                 (when (and (ez-agents--agent-tool-p tool) use-id)
                   (ez-agents--add-sub s (concat "sub:" use-id)
                                       (or (alist-get 'description (alist-get 'tool_input data))
                                           "sub-agent")
                                       'hook))
                 (ez-agents-set-status s 'working)
                 t)
                ("PostToolUse"
                 (when-let* (((ez-agents--agent-tool-p tool))
                             (sub (ez-agents-session (concat "sub:" (or use-id "")))))
                   (ez-agents-set-status sub 'done))
                 t)
                (_ (ez-agents-set-status s 'working)))))
        (when changed (ez-agents--changed))
        "ok"))))

(defun ez-agents--add-sub (parent sub-id title source &optional kind)
  "Ensure a working sub-agent SUB-ID exists under PARENT."
  (unless (ez-agents-session sub-id)
    (puthash sub-id
             (ez-agent--create :id sub-id :kind (or kind (ez-agent-kind parent))
                               :project (ez-agent-project parent)
                               :parent (ez-agent-id parent) :name title :title title
                               :status 'working :started (float-time)
                               :activity (float-time) :source source)
             ez-agents--table)))

;;;; Commands

(defun ez-agents--read-kind ()
  (intern (completing-read "Agent: " (mapcar (lambda (d) (symbol-name (car d)))
                                             ez-agents-definitions)
                           nil t)))

;;;###autoload
(defun ez-agents-new (kind &optional prompt-project)
  "Start agent KIND in the current project.
With PROMPT-PROJECT (prefix arg), choose the project directory."
  (interactive (list (ez-agents--read-kind) current-prefix-arg))
  (require 'ez-agents-worktree)
  (let* ((dir (ez-agents--normalize-root
               (if prompt-project (project-prompt-project-dir) (ez-agents--current-root))))
         (spec (ez-agents-worktree-choose-spec kind dir))
         (resume (progn (require 'ez-agents-chats)
                        (ez-agents-chats-choose kind (or (plist-get spec :cwd) dir))))
         (spec (if resume
                   (append (list :command (car resume) :chat (cdr resume)) spec)
                 spec))
         (s (ez-agents-spawn kind (or (ez-agents-git-main-root dir) dir) spec)))
    (ez-agents-jump s)
    s))

(defcustom ez-agents-workspace-trigger 'always
  "When selecting or starting an agent turns the frame into dashboard + chat.
`dashboard': only from the dashboard (or while the layout is already up),
`always': from anywhere (the earlier layout is restored by `q' in the sidebar),
`never': show the chat in another window as before."
  :type '(choice (const dashboard) (const always) (const never))
  :group 'ez-agents)

(defcustom ez-agents-workspace-width 44
  "Columns the dashboard keeps as a sidebar while a chat is open."
  :type 'integer
  :group 'ez-agents)

(defvar ez-agents--workspace nil
  "While the dashboard+chat layout is up: (SAVED-CONFIGURATION FRAME).")

(defvar ez-agents--current-chat nil "Id of the agent whose chat was opened last.")

(declare-function ez-agents-workspace-active-p "ez-agents-dashboard")
(declare-function ez-agents-workspace-show "ez-agents-dashboard")

(defun ez-agents--ensure-terminal (top)
  "A live terminal buffer for TOP, reattaching a detached persistent session."
  (let ((buf (ez-agent-buffer top)))
    (cond
     ((and (buffer-live-p buf)
           (or (null (ez-agent-tmux top)) (ez-agents--terminal-live-p buf)))
      buf)
     ((and (ez-agent-tmux top) (ez-agents-live-p top))
      (require 'ez-agents-persist)
      (when (buffer-live-p buf)           ; a dead terminal left behind by an exit
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))
      (ez-agents-attach top t)
      (ez-agent-buffer top))
     (t (user-error "No terminal for this session (it has ended: try `ez-agents-resume')")))))

(defun ez-agents--workspace-wanted-p ()
  (pcase ez-agents-workspace-trigger
    ('never nil)
    ('always t)
    (_ (or (derived-mode-p 'ez-agents-dashboard-mode)
           (and (fboundp 'ez-agents-workspace-active-p) (ez-agents-workspace-active-p))))))

(defun ez-agents-jump (session)
  "Show SESSION's chat.
From the dashboard (see `ez-agents-workspace-trigger') the frame becomes the
dashboard as a sidebar with the chat beside it; otherwise the chat opens in a
window other than the sidebar.  A detached persistent session is reattached."
  (let* ((top (if-let* ((p (ez-agent-parent session))) (ez-agents-session p) session))
         (buf (progn (unless top (user-error "No such session"))
                     (ez-agents--log "jump to %s from %S (mode %s), workspace wanted=%S"
                                     (ez-agent-id top) (buffer-name) major-mode
                                     (ez-agents--workspace-wanted-p))
                     (condition-case err (ez-agents--ensure-terminal top)
                       (error (ez-agents--log "ensure-terminal FAILED: %S" err)
                              (signal (car err) (cdr err)))))))
    (setq ez-agents--current-chat (ez-agent-id top))
    (if (ez-agents--workspace-wanted-p)
        (progn (require 'ez-agents-dashboard)
               (ez-agents-workspace-show top buf)
               (ez-agents--watch top "after workspace-show"))
      (select-window
       (display-buffer buf '((display-buffer-reuse-window
                              display-buffer-use-some-window
                              display-buffer-pop-up-window)
                             (inhibit-same-window . t)))))))

;;;; Fullscreen

(defcustom ez-agents-fullscreen-frame nil
  "Non-nil: also make the whole frame fullscreen while an agent is zoomed."
  :type 'boolean
  :group 'ez-agents)

(defvar ez-agents--zoom nil
  "State saved while an agent is fullscreen: (CONFIGURATION FRAME OLD-FULLSCREEN).")

(defun ez-agents-current-session ()
  "The session whose terminal is the current buffer, or nil."
  (cl-find (current-buffer) (ez-agents-sessions) :key #'ez-agent-buffer))

(defun ez-agents-fullscreen-p ()
  "Non-nil while an agent is fullscreen."
  (and ez-agents--zoom (frame-live-p (nth 1 ez-agents--zoom))))

(defun ez-agents--unzoom ()
  (pcase-let ((`(,config ,frame ,old) ez-agents--zoom))
    (setq ez-agents--zoom nil)
    (when (frame-live-p frame)
      (when ez-agents-fullscreen-frame
        (set-frame-parameter frame 'fullscreen old))
      (set-window-configuration config))))

;;;###autoload
(defun ez-agents-toggle-fullscreen (&optional session)
  "Give an agent's terminal the whole frame, or restore the previous layout.
Acts on SESSION, else the agent in the current buffer, else asks.  Side
windows (the sidebar) are closed while zoomed and come back on restore."
  (interactive)
  (if (ez-agents-fullscreen-p)
      (progn (ez-agents--unzoom) (message "Restored the previous layout"))
    (setq ez-agents--zoom nil)
    (let* ((s (or session (ez-agents-current-session) (ez-agents-read-session "Fullscreen: ")))
           (frame (selected-frame))
           (zoom (list (current-window-configuration frame) frame
                       (frame-parameter frame 'fullscreen))))
      (ez-agents-jump s)
      (let ((ignore-window-parameters t))
        (delete-other-windows))
      (when ez-agents-fullscreen-frame
        (set-frame-parameter frame 'fullscreen 'fullboth))
      (setq ez-agents--zoom zoom)
      (message "%s fullscreen: press the key again to restore" (ez-agent-name s)))))

;;;###autoload
(defun ez-agents-goto-waiting ()
  "Jump to the first session that is waiting for input."
  (interactive)
  (if-let* ((s (cl-find-if (lambda (s) (eq (ez-agent-status s) 'waiting))
                           (ez-agents-sessions))))
      (ez-agents-jump s)
    (message "No agent is waiting for input")))

;;;###autoload
(defun ez-agents-switch ()
  "Pick a session with completion and jump to it."
  (interactive)
  (let* ((cands (mapcar (lambda (s)
                          (cons (format "%-10s %s  [%s]"
                                        (ez-agents-project-name (ez-agent-project s))
                                        (ez-agent-name s) (ez-agent-status s))
                                s))
                        (ez-agents-sessions)))
         (pick (and cands (completing-read "Agent session: " cands nil t))))
    (if pick (ez-agents-jump (cdr (assoc pick cands)))
      (user-error "No agent sessions"))))

(defun ez-agents-kill (session)
  "Kill SESSION's terminal and forget it."
  (let ((top (if-let* ((p (ez-agent-parent session))) (ez-agents-session p) session)))
    (if (eq top session)
        (progn (ez-agents--remove (ez-agent-id session))
               (ignore-errors
                 (ez-agents-backend-kill (ez-agents--bk session) session))
               (when (ez-agent-worktree session)
                 (message "Worktree kept at %s (finish it with `ez-agents-worktree-finish')"
                          (abbreviate-file-name (ez-agent-cwd session)))))
      (ez-agents--remove (ez-agent-id session)))
    (ez-agents--changed)))

(defun ez-agents-ended-sessions ()
  "Top-level sessions whose agent has ended (nothing left running to attach to)."
  (cl-remove-if (lambda (s) (or (not (memq (ez-agent-status s) '(done error)))
                                (ez-agents-live-p s)))
                (ez-agents-sessions)))

;;;###autoload
(defun ez-agents-clear-ended ()
  "Forget every ended session (and its dead terminal), after confirming."
  (interactive)
  (let ((ended (ez-agents-ended-sessions)))
    (cond ((null ended) (message "No ended agents to clear"))
          ((y-or-n-p (format "Clear %d ended agent%s? " (length ended)
                             (if (cdr ended) "s" "")))
           (dolist (s ended) (ez-agents-kill s))
           (message "Cleared %d ended agent%s" (length ended) (if (cdr ended) "s" ""))))))

(defun ez-agents-rename (session name)
  (setf (ez-agent-name session) name)
  (ez-agents--changed))

(defun ez-agents-send (session text)
  "Send TEXT followed by RET to SESSION's terminal."
  (let ((top (ez-agents--top session)))
    (ez-agents-backend-send (ez-agents--bk top) top (concat text "\r"))))

(defun ez-agents-send-paste (session text)
  "Send multi-line TEXT to SESSION as one bracketed paste, then RET.
Plain RET inside TEXT would submit the prompt early."
  (let ((top (ez-agents--top session)))
    (ez-agents-backend-send (ez-agents--bk top) top
                            (concat "\e[200~" text "\e[201~"))
    (run-at-time 0.3 nil (lambda () (ignore-errors
                                      (ez-agents-backend-send (ez-agents--bk top) top "\r"))))))

;;;; Output, targets and raw input (used by the dashboard and console)

(defun ez-agents--top (session)
  (if-let* ((p (ez-agent-parent session))) (ez-agents-session p) session))

(defun ez-agents-tail (session &optional lines)
  "Return the last LINES (default 12) non-blank terminal lines of SESSION."
  (when-let* ((top (and session (ez-agents--top session))))
    (if (and (memq (ez-agent-status top) '(done error)) (ez-agent-exit-note top))
        (last (ez-agent-exit-note top) (or lines 12))
      (ez-agents-backend-text (ez-agents--bk top) top (or lines 12)))))

(defun ez-agents-resolve-target (target)
  "Live top-level sessions designated by TARGET.
TARGET is `all', `waiting', (project . ROOT), (session . ID) or (ids . IDS)."
  (cl-remove-if-not
   #'ez-agents-live-p
   (pcase target
     ('all (ez-agents-sessions))
     ('waiting (cl-remove-if-not (lambda (s) (eq (ez-agent-status s) 'waiting))
                                 (ez-agents-sessions)))
     (`(project . ,root) (cl-remove-if-not
                          (lambda (s) (equal (ez-agent-project s) root))
                          (ez-agents-sessions)))
     (`(session . ,id) (when-let* ((s (ez-agents-session id)))
                         (list (ez-agents--top s))))
     (`(ids . ,ids) (cl-remove-duplicates
                     (delq nil (mapcar (lambda (id)
                                         (when-let* ((s (ez-agents-session id)))
                                           (ez-agents--top s)))
                                       ids))
                     :from-end t)))))

(defun ez-agents-target-label (target)
  (pcase target
    ('all "all agents")
    ('waiting "agents waiting for input")
    (`(project . ,root) (format "project %s" (ez-agents-project-name root)))
    (`(ids . ,ids) (format "%d selected agents" (length ids)))
    (`(session . ,id) (if-let* ((s (ez-agents-session id)))
                          (format "%s (%s)" (ez-agent-name s)
                                  (ez-agents-project-name (ez-agent-project s)))
                        "closed session"))))

(defun ez-agents-send-raw (session string)
  "Send STRING to SESSION's terminal unchanged (no trailing newline)."
  (let ((top (ez-agents--top session)))
    (ez-agents-backend-send (ez-agents--bk top) top string)))

;;;; Claude Code hook installation

(defconst ez-agents--claude-events
  '(("SessionStart") ("UserPromptSubmit") ("PreToolUse")
    ("PostToolUse" . "Task|Agent") ("Notification") ("Stop") ("SessionEnd"))
  "Claude Code hook events to forward, as (EVENT . MATCHER).")

(defun ez-agents--settings-file (root)
  (expand-file-name ".claude/settings.local.json" root))

(defun ez-agents-hooks-installed-p (root)
  (let ((f (ez-agents--settings-file root)))
    (and (file-exists-p f)
         (with-temp-buffer
           (insert-file-contents f)
           (search-forward "ez-agents-hook" nil t)))))

(defun ez-agents--read-settings (file)
  (if (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (if (zerop (buffer-size)) (make-hash-table :test #'equal)
          (goto-char (point-min))
          (json-parse-buffer :object-type 'hash-table :array-type 'array)))
    (make-hash-table :test #'equal)))

(defun ez-agents--ours-p (entry)
  (cl-some (lambda (h) (string-match-p "ez-agents-hook" (or (gethash "command" h) "")))
           (gethash "hooks" entry [])))

(defun ez-agents--edit-hooks (settings install)
  "Return SETTINGS with our hook entries added (INSTALL) or removed."
  (let ((hooks (or (gethash "hooks" settings) (make-hash-table :test #'equal))))
    (dolist (ev ez-agents--claude-events)
      (let* ((name (car ev))
             (kept (cl-remove-if #'ez-agents--ours-p (gethash name hooks [])))
             (ours
              (when install
                (let ((e (make-hash-table :test #'equal))
                      (h (make-hash-table :test #'equal)))
                  (puthash "type" "command" h)
                  (puthash "command" (format "sh '%s' %s" ez-agents--hook-script name) h)
                  (puthash "matcher" (or (cdr ev) "") e)
                  (puthash "hooks" (vector h) e)
                  (list e))))
             (all (vconcat kept ours)))
        (if (zerop (length all)) (remhash name hooks) (puthash name all hooks))))
    (if (zerop (hash-table-count hooks)) (remhash "hooks" settings)
      (puthash "hooks" hooks settings))
    settings))

(defun ez-agents--write-settings (file settings)
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (json-serialize settings))
    (json-pretty-print-buffer)
    (insert "\n")))

;;;###autoload
(defun ez-agents-install-hooks (&optional root)
  "Install Claude Code hooks for ROOT's project (project-local, git-ignored)."
  (interactive)
  (let* ((root (or root (ez-agents--current-root)))
         (file (ez-agents--settings-file root)))
    (ez-agents--write-settings
     file (ez-agents--edit-hooks (ez-agents--read-settings file) t))
    (message "Installed ez-agents hooks in %s" (abbreviate-file-name file))))

;;;###autoload
(defun ez-agents-uninstall-hooks (&optional root)
  "Remove the ez-agents hooks from ROOT's project."
  (interactive)
  (let* ((root (or root (ez-agents--current-root)))
         (file (ez-agents--settings-file root)))
    (when (file-exists-p file)
      (ez-agents--write-settings
       file (ez-agents--edit-hooks (ez-agents--read-settings file) nil))
      (message "Removed ez-agents hooks from %s" (abbreviate-file-name file)))))

(defun ez-agents--maybe-install-hooks (root)
  (unless (or (eq ez-agents-install-hooks-policy 'never)
              (ez-agents-hooks-installed-p root)
              (member root ez-agents--hooks-declined))
    (if (or (eq ez-agents-install-hooks-policy 'always)
            (y-or-n-p (format "Install status hooks in %s? (accurate status + sub-agents) "
                              (abbreviate-file-name (ez-agents--settings-file root)))))
        (ez-agents-install-hooks root)
      (push root ez-agents--hooks-declined))))

(provide 'ez-agents)
;;; ez-agents.el ends here
