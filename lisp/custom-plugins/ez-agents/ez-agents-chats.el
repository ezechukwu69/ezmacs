;;; ez-agents-chats.el --- Resume an agent's existing chat in a directory -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Agents keep their conversations on disk per working directory.  This finds
;; them (read-only) so starting an agent in a directory can offer to carry on
;; an earlier chat instead of opening a blank one:
;;
;;   Claude Code  ~/.claude/projects/<dir>/<uuid>.jsonl      -> claude --resume <id>
;;   Codex        ~/.codex/sessions/Y/M/D/rollout-*.jsonl     -> codex resume <id>
;;
;; Cursor and Gemini keep chats where we cannot list them, so for those only
;; "continue the latest" is offered (and only on request).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'project)
(require 'ez-agents)

(declare-function ez-agents-git-main-root "ez-agents-git")

(defcustom ez-agents-resume-prompt 'ask
  "What starting an agent does when the directory already has chats.
`ask' offers to resume one, `latest' silently continues the most recent,
`never' always starts a new chat."
  :type '(choice (const ask) (const latest) (const never))
  :group 'ez-agents)

(defcustom ez-agents-chats-limit 30
  "Most chats listed per directory."
  :type 'integer
  :group 'ez-agents)

;;;; Reading helpers

(defun ez-agents-chats--head (file &optional bytes)
  "The first BYTES (default 256 KB) of FILE as a string."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file nil 0 (or bytes 262144)))
    (buffer-string)))

(defun ez-agents-chats--json (line)
  (ignore-errors (json-parse-string line :object-type 'alist :array-type 'list)))

(defun ez-agents-chats--text (content)
  "Plain text of a message CONTENT (a string, or a list of blocks)."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b) (if (listp b) (or (alist-get 'text b) "") "")) content " "))
        (t "")))

(defun ez-agents-chats--tidy (text)
  "TEXT without tags and newlines, shortened for a menu."
  (let* ((s (replace-regexp-in-string "<[^>]*>" "" text))
         (s (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " s))))
    (truncate-string-to-width s 70 nil nil "…")))

(defun ez-agents-chats--age (time)
  (let ((s (max 0 (floor (- (float-time) time)))))
    (cond ((< s 60) "just now")
          ((< s 3600) (format "%dm ago" (/ s 60)))
          ((< s 86400) (format "%dh ago" (/ s 3600)))
          ((< s (* 14 86400)) (format "%dd ago" (/ s 86400)))
          (t (format-time-string "%b %d" time)))))

(defun ez-agents-chats--mtime (file)
  (float-time (file-attribute-modification-time (file-attributes file))))

;;;; Claude Code

(defun ez-agents-chats--claude-dir (dir)
  (expand-file-name
   (replace-regexp-in-string "[^A-Za-z0-9]" "-" (directory-file-name (expand-file-name dir)))
   (expand-file-name "projects" (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude"))))

(defun ez-agents-chats--claude-title (file)
  "Return the chat title for FILE, or nil if it holds no conversation."
  (let ((title nil) (first-user nil) (has-user nil))
    (dolist (line (split-string (ez-agents-chats--head file) "\n" t))
      (when (string-match-p "\"type\":\"\\(ai-title\\|agent-name\\|user\\|last-prompt\\)\"" line)
        (when-let* ((d (ez-agents-chats--json line)))
          (pcase (alist-get 'type d)
            ("ai-title" (unless title (setq title (alist-get 'aiTitle d))))
            ("agent-name" (unless title (setq title (alist-get 'agentName d))))
            ("last-prompt" (unless first-user (setq first-user (alist-get 'lastPrompt d))))
            ("user"
             (setq has-user t)
             (unless first-user
               (let ((text (ez-agents-chats--text (alist-get 'content (alist-get 'message d)))))
                 (unless (string-empty-p (ez-agents-chats--tidy text))
                   (setq first-user text)))))))))
    (when has-user
      (ez-agents-chats--tidy (or title first-user "(untitled)")))))

(defun ez-agents-chats--claude-live ()
  "Hash of the Claude chats being run right now: session id -> its kind.
Claude records every live process in `<config>/sessions/<pid>.json'."
  (let ((h (make-hash-table :test #'equal))
        (dir (expand-file-name "sessions" (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude"))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\.json\\'"))
        (when-let* ((d (ez-agents-chats--json (ez-agents-chats--head f 8192)))
                    (pid (alist-get 'pid d))
                    (id (alist-get 'sessionId d))
                    ((process-attributes pid)))
          (puthash id (or (alist-get 'kind d) "interactive") h))))
    h))

(defun ez-agents-chats--claude (dir)
  (let ((root (ez-agents-chats--claude-dir dir)) (live (ez-agents-chats--claude-live)) out)
    (when (file-directory-p root)
      (dolist (f (directory-files root t "\\.jsonl\\'"))
        (when (> (file-attribute-size (file-attributes f)) 0)
          (when-let* ((title (ez-agents-chats--claude-title f)))
            (push (list :id (file-name-base f) :title title :time (ez-agents-chats--mtime f)
                        :live (gethash (file-name-base f) live))
                  out)))))
    out))

;;;; Codex

(defun ez-agents-chats--codex-root ()
  (expand-file-name "sessions" (or (getenv "CODEX_HOME") "~/.codex")))

(defconst ez-agents-chats--codex-boilerplate
  "\\`[ \t\n]*\\(<environment_context\\|<user_instructions\\|<INSTRUCTIONS\\|<permissions\\|# AGENTS\\)"
  "Start of the context Codex injects as a user message before the real prompt.")

(defun ez-agents-chats--codex-title (file)
  "Title of Codex chat FILE (its first real prompt), or nil if it has none."
  (catch 'found
    (dolist (line (split-string (ez-agents-chats--head file 524288) "\n" t))
      (when (string-match-p "\"role\":\"user\"" line)
        (when-let* ((d (ez-agents-chats--json line))
                    (p (alist-get 'payload d))
                    ((equal (alist-get 'role p) "user"))
                    (raw (ez-agents-chats--text (alist-get 'content p)))
                    ((not (string-match-p ez-agents-chats--codex-boilerplate raw)))
                    (text (ez-agents-chats--tidy raw))
                    ((not (string-empty-p text))))
          (throw 'found text))))
    nil))

(defun ez-agents-chats--codex (dir)
  (let* ((want (file-name-as-directory (expand-file-name dir)))
         (root (ez-agents-chats--codex-root))
         (files (and (file-directory-p root)
                     (sort (directory-files-recursively root "\\`rollout-.*\\.jsonl\\'")
                           #'string>)))
         out)
    (dolist (f (seq-take files 600))
      (let* ((first (car (split-string (ez-agents-chats--head f 65536) "\n" t)))
             (d (and first (ez-agents-chats--json first)))
             (p (and d (equal (alist-get 'type d) "session_meta") (alist-get 'payload d))))
        (when (and p (alist-get 'cwd p) (alist-get 'id p)
                   (equal (file-name-as-directory (alist-get 'cwd p)) want))
          (when-let* ((title (ez-agents-chats--codex-title f)))
            (push (list :id (alist-get 'id p) :title title :time (ez-agents-chats--mtime f))
                  out)))))
    out))

;;;; Title of a running session

(defvar ez-agents-chats--title-cache (make-hash-table :test #'equal)
  "Chat file -> (MTIME . TITLE), so dashboard refreshes do not re-parse chats.")

(defun ez-agents-chats-session-title (session)
  "Title of SESSION's Claude chat, or nil when it has none yet."
  (when-let* (((eq (ez-agent-kind session) 'claude))
              (chat (ez-agent-chat session))
              (dir (or (ez-agent-cwd session) (ez-agent-project session)))
              (file (expand-file-name (concat chat ".jsonl") (ez-agents-chats--claude-dir dir)))
              ((file-readable-p file)))
    (let ((mtime (ez-agents-chats--mtime file))
          (hit (gethash file ez-agents-chats--title-cache)))
      (if (and hit (= (car hit) mtime))
          (cdr hit)
        (let ((title (ignore-errors (ez-agents-chats--claude-title file))))
          (puthash file (cons mtime title) ez-agents-chats--title-cache)
          title)))))

;;;; Public

(defun ez-agents-chats (kind dir)
  "Existing chats of agent KIND in DIR, newest first (plists :id :title :time).
Nil for agents whose chats cannot be listed."
  (when-let* ((fn (plist-get (ez-agents-definition kind) :chats)))
    (seq-take (sort (funcall fn dir) (lambda (a b) (> (plist-get a :time) (plist-get b :time))))
              ez-agents-chats-limit)))

(defun ez-agents-chats--read (prompt candidates)
  "Completing-read over alist CANDIDATES keeping their order; return the value."
  (let* ((table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action candidates string pred))))
         (pick (completing-read prompt table nil t)))
    (cdr (assoc pick candidates))))

(defun ez-agents-chats--label (chat)
  (format "%-9s %s%s" (ez-agents-chats--age (plist-get chat :time)) (plist-get chat :title)
          (if (plist-get chat :live) "   ● running now (opens a copy)" "")))

(defun ez-agents-chats--command (kind chat)
  "Command that resumes CHAT of agent KIND.
Claude refuses to resume a chat that is running as a background agent
(\"currently running ... add --fork-session\"), and two processes appending to
one chat file is unwise anyway, so a chat that is live right now is opened as
a copy."
  (let ((cmd (ez-agents--resume-command kind (plist-get chat :id))))
    (if (and (plist-get chat :live) (eq kind 'claude) (plist-get chat :id))
        (append cmd '("--fork-session"))
      cmd)))

(defun ez-agents-chats-choose (kind dir)
  "Offer to resume a chat of KIND in DIR.
Return (COMMAND . CHAT-ID) when one should be resumed, nil to start a new chat."
  (unless (eq ez-agents-resume-prompt 'never)
    (when-let* ((chats (ez-agents-chats kind dir)))
      (let* ((latest (car chats))
             (pick (if (eq ez-agents-resume-prompt 'latest)
                       latest
                     (ez-agents-chats--read
                      (format "%s chat in %s: " (plist-get (ez-agents-definition kind) :name)
                              (abbreviate-file-name dir))
                      (append (list (cons "New chat" nil)
                                    (cons (format "Continue most recent · %s"
                                                  (ez-agents-chats--label latest))
                                          latest))
                              (mapcar (lambda (c) (cons (ez-agents-chats--label c) c))
                                      (cdr chats)))))))
        (when pick
          (cons (ez-agents-chats--command kind pick) (plist-get pick :id)))))))

;;;###autoload
(defun ez-agents-resume-chat (kind &optional dir)
  "Start agent KIND resuming one of its chats in DIR (default: this project).
With a prefix argument, choose the directory.  Agents whose chats cannot be
listed continue their most recent one."
  (interactive (list (ez-agents--read-kind)
                     (when current-prefix-arg (project-prompt-project-dir))))
  (require 'ez-agents-git)
  (let* ((dir (ez-agents--normalize-root (or dir (ez-agents--current-root))))
         (def (ez-agents-definition kind))
         (chats (ez-agents-chats kind dir))
         (pick (cond
                (chats (ez-agents-chats--read
                        (format "Resume %s chat in %s: " (plist-get def :name)
                                (abbreviate-file-name dir))
                        (mapcar (lambda (c) (cons (ez-agents-chats--label c) c)) chats)))
                ((plist-get def :chats)
                 (user-error "No %s chats found in %s" (plist-get def :name)
                             (abbreviate-file-name dir)))
                ((plist-get def :resume)
                 (if (y-or-n-p (format "Continue the most recent %s chat in %s? "
                                       (plist-get def :name) (abbreviate-file-name dir)))
                     (list :id nil)
                   (user-error "Cancelled")))
                (t (user-error "%s cannot resume chats" (plist-get def :name)))))
         (id (plist-get pick :id))
         (session (ez-agents-spawn kind (or (ez-agents-git-main-root dir) dir)
                                   (list :cwd dir :chat id
                                         :command (ez-agents-chats--command kind pick)))))
    (ez-agents-jump session)
    session))

(provide 'ez-agents-chats)
;;; ez-agents-chats.el ends here
