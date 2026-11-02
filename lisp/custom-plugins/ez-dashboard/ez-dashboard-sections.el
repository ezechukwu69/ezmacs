;;; ez-dashboard-sections.el --- Built-in dashboard panels -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; The stat tiles and sections `ez-dashboard' shows by default:
;;
;;   tiles      startup time, packages, config modules, custom plugins, Emacs,
;;              agents
;;   agents     live agents by state, each agent's own usage limits, sessions
;;   projects   recently used projects with their git branch
;;   chats      recent Claude Code / Codex conversations, across projects
;;   files      recent files
;;   session    what is running right now (buffers, workspaces, LSP, ...)
;;   config     modules per category, custom plugins, shortcuts to the config
;;
;; Everything drawn on the first paint comes from data that is already in
;; memory.  The slow parts (loading ez-agents, scanning chat history on disk,
;; asking agents for their usage) run later through `ez-dashboard-defer-function'
;; and only while the dashboard is visible; each fills a cache and asks for a
;; redraw.  Each panel is a thin gatherer plus a pure renderer, so the
;; renderers can be tested with plain data.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'project)
(require 'ez-dashboard)

(declare-function ez-agents-sessions "ez-agents")
(declare-function ez-agents-jump "ez-agents")
(declare-function ez-agents-new "ez-agents")
(declare-function ez-agents-spawn "ez-agents")
(declare-function ez-agents-dashboard "ez-agents-dashboard")
(declare-function ez-agents-git-main-root "ez-agents-git")
(declare-function ez-agents-usage "ez-agents-usage")
(declare-function ez-agents-chats--head "ez-agents-chats")
(declare-function ez-agents-chats--claude-title "ez-agents-chats")
(declare-function ez-agents-chats--codex-title "ez-agents-chats")
(declare-function ez-agents-chats--codex-root "ez-agents-chats")
(declare-function ez-agents-chats--command "ez-agents-chats")
(declare-function ez-agents-chats--json "ez-agents-chats")
(declare-function ez-agents-definition "ez-agents")
(declare-function my/project-start "my-workspace-start")
(declare-function my/last-project "my-workspace-start")
(declare-function my-modules-report "my-modules")
(declare-function eglot-current-server "eglot")
(declare-function nerd-icons-icon-for-file "nerd-icons")
(declare-function server-running-p "server")
(defvar ez-agents-definitions)
(defvar ez-agents-usage--cache)
(defvar ez-agents-change-hook)
(defvar ez-agents-usage-updated-hook)
(defvar my-modules--order)
(defvar my-modules--table)
(defvar recentf-list)
(defvar package-activated-list)
(defvar user-lisp-directory)
(defvar tab-bar-tabs-function)
(defvar gcs-done)
(defvar gc-elapsed)

(defcustom ez-dashboard-fetch-usage t
  "Ask the agents for their usage limits while the dashboard is visible.
This runs `claude -p /usage' and a short `codex app-server' (at most once per
`ez-agents-usage-cache-seconds'); turn it off to show only what is cached."
  :type 'boolean :group 'ez-dashboard)

(defcustom ez-dashboard-chat-ignore-regexp "\\`\\(/private\\)?\\(/var/folders/\\|/tmp/\\)"
  "Conversations started in directories matching this are not listed.
The default hides throwaway temporary directories."
  :type 'regexp :group 'ez-dashboard)

(defun ez-dashboard--chat-dir-ok-p (cwd)
  "Non-nil if a conversation in CWD should be listed: it exists and is not ignored."
  (and cwd (file-directory-p cwd)
       (not (and ez-dashboard-chat-ignore-regexp
                 (string-match-p ez-dashboard-chat-ignore-regexp cwd)))))

(defcustom ez-dashboard-list-length 7
  "How many projects, chats and files the lists show."
  :type 'integer :group 'ez-dashboard)

;;;; Small shared helpers

(defun ez-dashboard--dir-name (dir)
  "The last component of directory DIR, without a trailing slash."
  (file-name-nondirectory (directory-file-name dir)))

(defun ez-dashboard--field (label value &optional label-width)
  "A \"LABEL  VALUE\" line with the label dimmed and padded to LABEL-WIDTH."
  (concat (propertize (format (format "%%-%ds" (or label-width 11)) label)
                      'face 'ez-dashboard-dim)
          value))

(defun ez-dashboard--chips (items width)
  "ITEMS (strings) laid out in as many lines of WIDTH columns as needed."
  (let (lines (cur ""))
    (dolist (item items)
      (if (and (not (string-empty-p cur))
               (> (+ (string-width cur) 3 (string-width item)) width))
          (progn (push cur lines) (setq cur item))
        (setq cur (if (string-empty-p cur) item (concat cur "   " item)))))
    (unless (string-empty-p cur) (push cur lines))
    (nreverse lines)))

;;;; Startup, packages, modules, plugins

(defvar ez-dashboard--startup nil
  "Startup figures: plist :init :ready :gcs :gc-time.")

(defun ez-dashboard--init-seconds ()
  "Seconds the init files took, or nil when unknown."
  (when (and (bound-and-true-p before-init-time) (bound-and-true-p after-init-time))
    (float-time (time-subtract after-init-time before-init-time))))

(defun ez-dashboard--startup-snapshot (&optional ready)
  "Figures for how long startup took; READY non-nil also records the time to ready."
  (list :init (ez-dashboard--init-seconds)
        :ready (and ready (float-time (time-subtract (current-time) before-init-time)))
        :gcs gcs-done :gc-time gc-elapsed))

(defun ez-dashboard--startup-info ()
  "The startup figures, measured now if nothing recorded them yet."
  (or ez-dashboard--startup
      (setq ez-dashboard--startup (ez-dashboard--startup-snapshot))))

(defun ez-dashboard-startup-finalize ()
  "Record the final startup figures; put this on `emacs-startup-hook'."
  (setq ez-dashboard--startup (ez-dashboard--startup-snapshot t))
  (ez-dashboard-refresh-soon))

(defvar ez-dashboard--packages nil)

(defun ez-dashboard--package-counts ()
  "Plist :installed (package directories) and :active (activated at startup)."
  (or ez-dashboard--packages
      (setq ez-dashboard--packages
            (list :installed
                  (if (file-directory-p package-user-dir)
                      (cl-count-if (lambda (f)
                                     (and (string-match-p "-[0-9][0-9.]*\\'" f)
                                          (file-directory-p (expand-file-name f package-user-dir))))
                                   (directory-files package-user-dir nil "\\`[^.]"))
                    0)
                  :active (length package-activated-list)))))

(defun ez-dashboard--module-info ()
  "Plist :total :categories ((CATEGORY . COUNT) ...) :failed (KEYS) of my-modules."
  (when (and (boundp 'my-modules--order) my-modules--order)
    (let (cats failed)
      (dolist (key my-modules--order)
        (cl-incf (alist-get (car key) cats 0))
        (unless (eq (plist-get (gethash key my-modules--table) :status) 'loaded)
          (push key failed)))
      (list :total (length my-modules--order) :categories (nreverse cats)
            :failed (nreverse failed)))))

(defvar ez-dashboard--plugins :unset)

(defun ez-dashboard--plugins ()
  "Names of the custom plugins under lisp/custom-plugins/, sorted."
  (when (eq ez-dashboard--plugins :unset)
    (setq ez-dashboard--plugins
          (let ((dir (expand-file-name "custom-plugins"
                                       (or (bound-and-true-p user-lisp-directory)
                                           (expand-file-name "lisp" user-emacs-directory)))))
            (when (file-directory-p dir)
              (sort (cl-loop for f in (directory-files dir nil "\\`[^.]")
                             when (or (file-directory-p (expand-file-name f dir))
                                      (string-match-p "\\.el\\'" f))
                             collect (file-name-sans-extension f))
                    #'string<)))))
  ez-dashboard--plugins)

(defun ez-dashboard--build-features ()
  "Short list of notable features this Emacs was built with."
  (delq nil (list (and (fboundp 'native-comp-available-p) (native-comp-available-p) "nc")
                  (and (fboundp 'treesit-available-p) (treesit-available-p) "ts")
                  (and (featurep 'xwidget-internal) "xw"))))

;;;; Agents: state, usage, sessions

(defun ez-dashboard--agents-ready-p ()
  "Non-nil once the agent registry is loaded."
  (featurep 'ez-agents))

(defun ez-dashboard--agent-sessions ()
  "Top-level agent sessions as plists (:id :status :name :project :since :obj)."
  (when (ez-dashboard--agents-ready-p)
    (mapcar (lambda (s)
              (list :id (ez-agent-id s) :status (ez-agent-status s)
                    :name (or (ignore-errors
                                (plist-get (ez-agents-definition (ez-agent-kind s)) :name))
                              (format "%s" (ez-agent-kind s)))
                    :project (ez-dashboard--dir-name (or (ez-agent-project s) ""))
                    :since (ez-agent-started s) :obj s))
            (ez-agents-sessions))))

(defun ez-dashboard--agent-counts (sessions)
  "Alist (STATE . COUNT) over SESSIONS, states working waiting idle ended."
  (let ((counts (list (cons 'working 0) (cons 'waiting 0) (cons 'idle 0) (cons 'ended 0))))
    (dolist (s sessions)
      (cl-incf (alist-get (pcase (plist-get s :status)
                            ((or 'working 'starting) 'working)
                            ('waiting 'waiting)
                            ((or 'done 'error) 'ended)
                            (_ 'idle))
                          counts)))
    counts))

(defun ez-dashboard--usage-data ()
  "Cached usage as a list of (NAME . WINDOWS); never asks an agent."
  (when (and (ez-dashboard--agents-ready-p) (boundp 'ez-agents-usage--cache))
    (cl-loop for (kind . def) in ez-agents-definitions
             for hit = (gethash kind ez-agents-usage--cache)
             when (cdr hit)
             collect (cons (plist-get def :name) (cdr hit)))))

(defun ez-dashboard--reset-text (time)
  "A short \"when it resets\" for TIME (a float)."
  (if (equal (format-time-string "%F") (format-time-string "%F" time))
      (format "%s%s" (format-time-string "%-I:%M" time)
              (if (< (string-to-number (format-time-string "%H" time)) 12) "am" "pm"))
    (format-time-string "%b %-d" time)))

(defun ez-dashboard--usage-line (name windows width &optional name-width)
  "One line: NAME (padded to NAME-WIDTH) and a bar for each of WINDOWS in WIDTH."
  (let* ((roomy (>= width 62))
         (bar-w (if roomy 8 5))
         (parts (mapcar
                 (lambda (w)
                   (let ((p (or (plist-get w :percent) 0)))
                     (concat (propertize (format "%-5s" (plist-get w :label)) 'face 'ez-dashboard-dim)
                             (ez-dashboard--bar p bar-w)
                             (propertize (format " %3d%%" (round p))
                                         'face (cond ((< p 60) 'success) ((< p 85) 'warning)
                                                     (t 'error)))
                             (if (and roomy (plist-get w :reset))
                                 (propertize (format " ↻%s" (ez-dashboard--reset-text
                                                             (plist-get w :reset)))
                                             'face 'ez-dashboard-dim)
                               ""))))
                 windows)))
    (ez-dashboard--truncate
     (concat (propertize (ez-dashboard--pad-to name (or name-width 8)) 'face 'ez-dashboard-value)
             (string-join parts "   "))
     width)))

(defun ez-dashboard--status-glyph (status)
  "A coloured glyph for agent STATUS."
  (pcase status
    ((or 'working 'starting) (propertize "●" 'face 'success))
    ('waiting (propertize "◐" 'face 'warning))
    ('error (propertize "✗" 'face 'error))
    ('done (propertize "✓" 'face 'ez-dashboard-dim))
    (_ (propertize "○" 'face 'ez-dashboard-dim))))

(defun ez-dashboard--agents-lines (counts usage sessions ready width)
  "Lines for the agents section in WIDTH columns.
COUNTS, USAGE and SESSIONS come from the gatherers; READY is nil while the
agent registry is not loaded yet."
  (if (not ready)
      (list (propertize "loading…" 'face 'ez-dashboard-dim))
    (let (lines)
      (push (string-join
             (cl-loop for (state _glyph label) in
                      '((working "●" "working") (waiting "◐" "waiting")
                        (idle "○" "idle") (ended "✓" "ended"))
                      collect (concat (ez-dashboard--status-glyph
                                       (pcase state ('ended 'done) (_ state)))
                                      (propertize (format " %d %s" (alist-get state counts 0) label)
                                                  'face 'ez-dashboard-dim)))
             "   ")
            lines)
      (let ((name-w (1+ (apply #'max 7
                               (append (mapcar (lambda (u) (string-width (car u))) usage)
                                       (mapcar (lambda (s) (string-width (plist-get s :name)))
                                               (seq-take sessions 4)))))))
        (dolist (u usage)
          (push (ez-dashboard--usage-line (car u) (cdr u) width name-w) lines))
        (dolist (s (seq-take sessions 4))
          (push (ez-dashboard-item
                 (ez-dashboard--truncate
                  (concat (ez-dashboard--status-glyph (plist-get s :status)) " "
                          (propertize (ez-dashboard--pad-to (plist-get s :name) name-w)
                                      'face 'ez-dashboard-value)
                          (format "%-18s" (ez-dashboard--truncate (plist-get s :project) 18))
                          (propertize (ez-dashboard--ago (plist-get s :since))
                                      'face 'ez-dashboard-dim))
                  width)
                 (let ((obj (plist-get s :obj)))
                   (lambda () (ez-agents-jump obj)))
                 (plist-get s :id) "RET: go to this agent")
                lines)))
      (when (null sessions)
        (push (ez-dashboard-item
               (concat (propertize "No agents running  " 'face 'ez-dashboard-dim)
                       (propertize "start one" 'face 'ez-dashboard-key))
               (lambda () (call-interactively #'ez-agents-new)) "agent-new" "RET: start an agent")
              lines))
      (when sessions
        (push (ez-dashboard-item (propertize "all agents →" 'face 'ez-dashboard-dim)
                                 (lambda () (ez-agents-dashboard)) "agents-all"
                                 "RET: the full agents dashboard")
              lines))
      (nreverse lines))))

(defun ez-dashboard--agents-section (width)
  "Agents section body for WIDTH columns."
  (ez-dashboard--agents-lines
   (ez-dashboard--agent-counts (ez-dashboard--agent-sessions))
   (ez-dashboard--usage-data) (ez-dashboard--agent-sessions)
   (ez-dashboard--agents-ready-p) width))

;;;; Projects

(defun ez-dashboard--git-head (dir)
  "Current branch of the repository at DIR (a short hash when detached), or nil."
  (ignore-errors
    (let* ((dotgit (expand-file-name ".git" dir))
           (gitdir (cond ((file-directory-p dotgit) dotgit)
                         ((file-regular-p dotgit)
                          (with-temp-buffer
                            (insert-file-contents dotgit)
                            (when (re-search-forward "gitdir: *\\(.+\\)" nil t)
                              (expand-file-name (match-string 1) dir)))))))
      (when (and gitdir (file-readable-p (expand-file-name "HEAD" gitdir)))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "HEAD" gitdir) nil 0 256)
          (cond ((re-search-forward "ref: refs/heads/\\(.+\\)" nil t)
                 (string-trim (match-string 1)))
                ((re-search-forward "\\`[0-9a-f]\\{7\\}" nil t)
                 (match-string 0))))))))

(defun ez-dashboard--project-entries ()
  "The most recent projects as plists (:dir :name :branch :last :agents)."
  (let ((last (and (fboundp 'my/last-project) (my/last-project)))
        (sessions (ez-dashboard--agent-sessions)))
    (mapcar (lambda (root)
              (let ((dir (file-name-as-directory (expand-file-name root))))
                (list :dir dir :name (ez-dashboard--dir-name dir)
                      :branch (ez-dashboard--git-head dir)
                      :last (and last (equal dir (file-name-as-directory last)))
                      :agents (cl-count-if
                               (lambda (s) (equal (plist-get s :project) (ez-dashboard--dir-name dir)))
                               sessions))))
            (seq-take (cl-remove-if-not #'file-directory-p
                                        (project-known-project-roots))
                      ez-dashboard-list-length))))

(defun ez-dashboard--open-project (dir)
  "Open project DIR through the project menu."
  (if (fboundp 'my/project-start)
      (my/project-start dir)
    (project-switch-project dir)))

(defun ez-dashboard--project-label (entry entries)
  "The name to show for ENTRY: its folder name.
When another of ENTRIES has the same name, the parent folder is added."
  (let ((name (plist-get entry :name)))
    (if (> (cl-count name entries :key (lambda (e) (plist-get e :name)) :test #'equal) 1)
        (format "%s (%s)" name
                (ez-dashboard--dir-name (file-name-directory (directory-file-name (plist-get entry :dir)))))
      name)))

(defun ez-dashboard--project-lines (entries width)
  "Lines for ENTRIES (see `ez-dashboard--project-entries') in WIDTH columns."
  (if (null entries)
      (list (propertize "No projects yet: open one with SPC p p" 'face 'ez-dashboard-dim))
    (let* ((name-w (min 26 (apply #'max 6 (mapcar (lambda (e) (string-width (ez-dashboard--project-label e entries)))
                                                   entries))))
           (branch-w (min 16 (apply #'max 0 (mapcar (lambda (e) (string-width (or (plist-get e :branch) "")))
                                                    entries)))))
      (mapcar
       (lambda (e)
         (let* ((dir (plist-get e :dir))
                (left (concat (if (plist-get e :last)
                                  (propertize "★ " 'face 'warning)
                                (propertize "▸ " 'face 'ez-dashboard-dim))
                              (propertize (format (format "%%-%ds" name-w)
                                                  (ez-dashboard--truncate
                                                   (ez-dashboard--project-label e entries) name-w))
                                          'face 'ez-dashboard-value)
                              "  "
                              (propertize (format (format "%%-%ds" branch-w)
                                                  (ez-dashboard--truncate (or (plist-get e :branch) "") branch-w))
                                          'face 'font-lock-string-face)
                              (if (> (plist-get e :agents) 0)
                                  (propertize (format "  ● %d" (plist-get e :agents)) 'face 'success)
                                "")))
                (room (- width (string-width left) 2)))
           (ez-dashboard-item
            (concat left (if (> room 22)
                             (propertize (concat "  " (ez-dashboard--truncate (abbreviate-file-name dir) room))
                                         'face 'ez-dashboard-dim)
                           ""))
            (lambda () (ez-dashboard--open-project dir))
            dir "RET: open, start an agent, or resume a chat here")))
       entries))))

(defun ez-dashboard--projects-section (width)
  "Projects section body for WIDTH columns."
  (ez-dashboard--project-lines (ez-dashboard--project-entries) width))

;;;; Conversations

(defvar ez-dashboard--chats nil
  "Cache (TIME . CHATS) of recent conversations; see `ez-dashboard--scan-chats'.")

(defconst ez-dashboard--chat-ttl 60 "Seconds a chat scan stays fresh.")

(defun ez-dashboard--head-cwd (head)
  "The working directory named in the first lines HEAD of a Claude chat file."
  (and (string-match "\"cwd\":\"\\([^\"]+\\)\"" head) (match-string 1 head)))

(defun ez-dashboard--claude-chats (limit)
  "The LIMIT most recent Claude Code chats that still have a directory."
  (let ((root (expand-file-name "projects" (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))
        files out)
    (when (and (file-directory-p root) (require 'ez-agents-chats nil t))
      (dolist (dir (directory-files root t "\\`[^.]"))
        (when (file-directory-p dir)
          (dolist (f (directory-files dir t "\\.jsonl\\'"))
            (when-let* ((a (file-attributes f)) ((> (file-attribute-size a) 0)))
              (push (cons f (float-time (file-attribute-modification-time a))) files)))))
      (setq files (seq-take (sort files (lambda (a b) (> (cdr a) (cdr b)))) (* 4 limit)))
      (catch 'full
        (dolist (entry files)
          (let* ((cwd (ez-dashboard--head-cwd (ez-agents-chats--head (car entry) 65536)))
                 (title (and (ez-dashboard--chat-dir-ok-p cwd)
                             (ez-agents-chats--claude-title (car entry)))))
            (when title
              (push (list :kind 'claude :id (file-name-base (car entry)) :title title
                          :time (cdr entry) :dir (file-name-as-directory cwd))
                    out)
              (when (>= (length out) limit) (throw 'full nil)))))))
    (nreverse out)))

(defun ez-dashboard--codex-chats (limit)
  "The LIMIT most recent Codex chats that still have a directory."
  (let ((root (and (require 'ez-agents-chats nil t) (ez-agents-chats--codex-root))) out)
    (when (and root (file-directory-p root))
      (let ((files (seq-take (sort (directory-files-recursively root "\\`rollout-.*\\.jsonl\\'")
                                   #'string>)
                             (* 4 limit))))
        (catch 'full
          (dolist (f files)
            (let* ((first (car (split-string (ez-agents-chats--head f 65536) "\n" t)))
                   (d (and first (ez-agents-chats--json first)))
                   (p (and d (equal (alist-get 'type d) "session_meta") (alist-get 'payload d)))
                   (cwd (and p (alist-get 'cwd p)))
                   (title (and (ez-dashboard--chat-dir-ok-p cwd) (ez-agents-chats--codex-title f))))
              (when (and title (alist-get 'id p))
                (push (list :kind 'codex :id (alist-get 'id p) :title title
                            :time (float-time (file-attribute-modification-time (file-attributes f)))
                            :dir (file-name-as-directory cwd))
                      out)
                (when (>= (length out) limit) (throw 'full nil))))))))
    (nreverse out)))

(defun ez-dashboard--scan-chats ()
  "Recent Claude Code and Codex conversations, newest first."
  (let ((all (append (ez-dashboard--claude-chats ez-dashboard-list-length)
                     (ez-dashboard--codex-chats ez-dashboard-list-length))))
    (seq-take (sort all (lambda (a b) (> (plist-get a :time) (plist-get b :time))))
              ez-dashboard-list-length)))

(defun ez-dashboard--refresh-chats (&optional force)
  "Rescan chats when the cache is older than the TTL (or FORCE)."
  (when (or force (null ez-dashboard--chats)
            (> (- (float-time) (car ez-dashboard--chats)) ez-dashboard--chat-ttl))
    (setq ez-dashboard--chats (cons (float-time) (ignore-errors (ez-dashboard--scan-chats))))))

(defun ez-dashboard--resume-chat (chat)
  "Resume CHAT (a plist) in a new agent session."
  (require 'ez-agents-chats) (require 'ez-agents-git)
  (let ((kind (plist-get chat :kind)) (dir (plist-get chat :dir)))
    (unless (file-directory-p dir) (user-error "%s no longer exists" dir))
    (ez-agents-jump
     (ez-agents-spawn kind (or (ez-agents-git-main-root dir) dir)
                      (list :cwd dir :chat (plist-get chat :id)
                            :command (ez-agents-chats--command kind chat))))))

(defun ez-dashboard--chat-lines (chats width)
  "Lines for CHATS (see `ez-dashboard--scan-chats') in WIDTH columns."
  (cond
   ((eq chats :loading) (list (propertize "loading…" 'face 'ez-dashboard-dim)))
   ((null chats) (list (propertize "No conversations yet" 'face 'ez-dashboard-dim)))
   (t (mapcar
       (lambda (c)
         (let* ((claude (eq (plist-get c :kind) 'claude))
                (marker (propertize (if claude "✱" "◇")
                                    'face (if claude 'font-lock-keyword-face 'font-lock-type-face)))
                (proj (ez-dashboard--truncate (ez-dashboard--dir-name (plist-get c :dir)) 14))
                (right (concat (propertize (format "%-14s" proj) 'face 'ez-dashboard-dim) " "
                               (propertize (format "%5s" (ez-dashboard--ago (plist-get c :time)))
                                           'face 'ez-dashboard-dim)))
                (title-w (max 8 (- width 2 (string-width right) 2)))
                (title (ez-dashboard--truncate (plist-get c :title) title-w))
                (line (concat marker " " title)))
           (ez-dashboard-item
            (concat (ez-dashboard--pad-to line (+ 2 title-w)) "  " right)
            (lambda () (ez-dashboard--resume-chat c))
            (plist-get c :id) "RET: resume this conversation")))
       chats))))

(defun ez-dashboard--chats-section (width)
  "Conversations section body for WIDTH columns."
  (ez-dashboard--chat-lines (if ez-dashboard--chats (cdr ez-dashboard--chats) :loading) width))

;;;; Recent files

(defun ez-dashboard--recent-files ()
  "Recent files worth listing, newest first."
  (when (bound-and-true-p recentf-list)
    (seq-take
     (cl-remove-if
      (lambda (f)
        (or (string-match-p "\\(COMMIT_EDITMSG\\|\\.elc\\'\\|/\\.git/\\)" f)
            (string-prefix-p (expand-file-name package-user-dir) f)
            (string-prefix-p (expand-file-name temporary-file-directory) f)
            (string-prefix-p "/var/folders/" f) (string-prefix-p "/private/var/" f)
            (not (file-exists-p f))))
      recentf-list)
     ez-dashboard-list-length)))

(defun ez-dashboard--file-lines (files width)
  "Lines for FILES in WIDTH columns."
  (if (null files)
      (list (propertize "No recent files" 'face 'ez-dashboard-dim))
    (mapcar
     (lambda (f)
       (let* ((name (file-name-nondirectory f))
              (icon (or (and (require 'nerd-icons nil t) (fboundp 'nerd-icons-icon-for-file)
                             (ignore-errors (nerd-icons-icon-for-file name)))
                        (propertize "▸" 'face 'ez-dashboard-dim)))
              (left (concat icon " " (propertize name 'face 'ez-dashboard-value)))
              (room (- width (string-width left) 3)))
         (ez-dashboard-item
          (concat left (if (> room 8)
                           (propertize (concat "  " (ez-dashboard--truncate
                                                     (abbreviate-file-name (file-name-directory f)) room))
                                       'face 'ez-dashboard-dim)
                         ""))
          (lambda () (find-file f)) f "RET: open this file")))
     files)))

(defun ez-dashboard--files-section (width)
  "Recent files section body for WIDTH columns."
  (ez-dashboard--file-lines (ez-dashboard--recent-files) width))

;;;; Right now

(defun ez-dashboard--lsp-names ()
  "Project names of the running Eglot servers."
  (delete-dups
   (cl-loop for p in (process-list)
            when (and (process-live-p p) (string-prefix-p "EGLOT" (process-name p))
                      (string-match "EGLOT (\\([^/]+\\)" (process-name p)))
            collect (match-string 1 (process-name p)))))

(defun ez-dashboard--session-facts ()
  "Alist (LABEL . VALUE-STRING) describing what is running now."
  (let* ((bufs (cl-remove-if (lambda (b) (string-prefix-p " " (buffer-name b))) (buffer-list)))
         (modified (cl-count-if (lambda (b) (and (buffer-file-name b) (buffer-modified-p b))) bufs))
         (tabs (when (boundp 'tab-bar-tabs-function)
                 (mapcar (lambda (tab) (alist-get 'name tab)) (funcall tab-bar-tabs-function))))
         (lsp (ez-dashboard--lsp-names))
         (procs (cl-count-if (lambda (p) (and (process-live-p p)
                                              (not (string-prefix-p "EGLOT" (process-name p)))
                                              (process-buffer p)))
                             (process-list)))
         (mpv (cl-some (lambda (p) (and (process-live-p p) (string-match-p "mpv" (process-name p))))
                       (process-list))))
    (delq nil
          (list (cons "Buffers" (format "%d open%s" (length bufs)
                                        (if (> modified 0) (format " · %d unsaved" modified) "")))
                (cons "Workspaces" (format "%d%s" (length tabs)
                                           (if (cdr tabs) (concat " · " (string-join (seq-take tabs 4) " · ")) "")))
                (cons "LSP" (if lsp (format "%d · %s" (length lsp) (string-join lsp ", ")) "none"))
                (cons "Processes" (format "%d running" procs))
                (and (fboundp 'server-running-p)
                     (cons "Server" (if (server-running-p) "emacsclient ready" "off")))
                (and mpv (cons "Playing" "♪ mpv"))))))

(defun ez-dashboard--session-lines (facts width)
  "Lines for FACTS (alist LABEL . VALUE) in WIDTH columns."
  (mapcar (lambda (f) (ez-dashboard--truncate (ez-dashboard--field (car f) (cdr f)) width)) facts))

(defun ez-dashboard--session-section (width)
  "Right-now section body for WIDTH columns."
  (ez-dashboard--session-lines (ez-dashboard--session-facts) width))

;;;; Config

(defun ez-dashboard--config-lines (info plugins width)
  "Lines describing module INFO and PLUGINS in WIDTH columns."
  (let (lines)
    (when info
      (let ((chips (mapcar (lambda (c)
                             (concat (propertize (substring (symbol-name (car c)) 1) 'face 'ez-dashboard-dim)
                                     " " (propertize (number-to-string (cdr c)) 'face 'ez-dashboard-value)))
                           (plist-get info :categories))))
        (setq lines (append lines (ez-dashboard--chips chips width)))
        (when-let* ((failed (plist-get info :failed)))
          (setq lines (append lines
                              (list (propertize (format "✗ failed: %s"
                                                        (mapconcat (lambda (k) (format "%s/%s" (substring (symbol-name (car k)) 1) (cdr k)))
                                                                   failed ", "))
                                                'face 'error)))))))
    (when plugins
      (setq lines (append lines (list (ez-dashboard--field "Plugins" (string-join plugins " · ") 9)))))
    (append lines
            (list (concat
                   (ez-dashboard-item (propertize "modules.el" 'face 'ez-dashboard-key)
                                      (lambda () (find-file (expand-file-name "modules.el" user-emacs-directory)))
                                      "open-modules" "RET: edit the module list")
                   "   "
                   (ez-dashboard-item (propertize "module report" 'face 'ez-dashboard-key)
                                      (lambda () (when (fboundp 'my-modules-report) (my-modules-report)))
                                      "module-report" "RET: load times per module")
                   "   "
                   (ez-dashboard-item (propertize "install guide" 'face 'ez-dashboard-key)
                                      (lambda () (find-file (expand-file-name "INSTALL.md" user-emacs-directory)))
                                      "install-guide" "RET: external programs needed"))))))

(defun ez-dashboard--config-section (width)
  "Config section body for WIDTH columns."
  (ez-dashboard--config-lines (ez-dashboard--module-info) (ez-dashboard--plugins) width))

;;;; Tiles

(defun ez-dashboard--tile-startup ()
  "Stat tile: startup time."
  (let* ((s (ez-dashboard--startup-info)) (init (plist-get s :init)))
    (list :label "Startup" :icon (ez-dashboard-icon "nf-md-timer_outline" "◷" 'ez-dashboard-dim)
          :value (if init (format "%.2f s" init) "—")
          :sub (format "%d GCs · %.2fs%s" (or (plist-get s :gcs) 0) (or (plist-get s :gc-time) 0)
                       (if (plist-get s :ready) (format " · ready %.1fs" (plist-get s :ready)) ""))
          :face (cond ((null init) 'ez-dashboard-dim) ((< init 1.5) 'success)
                      ((< init 3.0) 'warning) (t 'error)))))

(defun ez-dashboard--tile-packages ()
  "Stat tile: packages."
  (let ((p (ez-dashboard--package-counts)))
    (list :label "Packages" :icon (ez-dashboard-icon "nf-md-package_variant_closed" "▣" 'ez-dashboard-dim)
          :value (number-to-string (plist-get p :installed))
          :sub (format "%d active" (plist-get p :active)) :face 'font-lock-function-name-face)))

(defun ez-dashboard--tile-modules ()
  "Stat tile: config modules."
  (when-let* ((info (ez-dashboard--module-info)))
    (let ((failed (length (plist-get info :failed))))
      (list :label "Modules" :icon (ez-dashboard-icon "nf-md-view_module_outline" "▤" 'ez-dashboard-dim)
            :value (number-to-string (plist-get info :total))
            :sub (if (> failed 0) (format "%d failed" failed)
                   (format "%d categories" (length (plist-get info :categories))))
            :face (if (> failed 0) 'error 'font-lock-type-face)
            :action (lambda () (when (fboundp 'my-modules-report) (my-modules-report)))
            :help "RET: module report"))))

(defun ez-dashboard--tile-plugins ()
  "Stat tile: custom plugins."
  (let ((names (ez-dashboard--plugins)))
    (list :label "Plugins" :icon (ez-dashboard-icon "nf-md-power_plug_outline" "⌁" 'ez-dashboard-dim)
          :value (number-to-string (length names)) :sub (string-join names " · ")
          :face 'font-lock-string-face)))

(defun ez-dashboard--tile-emacs ()
  "Stat tile: the Emacs build."
  (list :label "Emacs" :icon (ez-dashboard-icon "nf-md-code_braces" "λ" 'ez-dashboard-dim)
        :value emacs-version :sub (string-join (ez-dashboard--build-features) " · ")
        :face 'font-lock-constant-face))

(defun ez-dashboard--tile-agents ()
  "Stat tile: agents."
  (let* ((ready (ez-dashboard--agents-ready-p))
         (counts (ez-dashboard--agent-counts (ez-dashboard--agent-sessions)))
         (live (+ (alist-get 'working counts 0) (alist-get 'waiting counts 0) (alist-get 'idle counts 0))))
    (list :label "Agents" :icon (ez-dashboard-icon "nf-md-robot_outline" "✱" 'ez-dashboard-dim)
          :value (if ready (number-to-string live) "…")
          :sub (if ready
                   (let ((w (alist-get 'working counts 0)) (a (alist-get 'waiting counts 0)))
                     (if (and (= w 0) (= a 0))
                         "all quiet"
                       (string-join (delq nil (list (and (> w 0) (format "%d work" w))
                                                    (and (> a 0) (format "%d wait" a))))
                                    " · ")))
                 "loading")
          :face (cond ((> (alist-get 'waiting counts 0) 0) 'warning)
                      ((> (alist-get 'working counts 0) 0) 'success)
                      (t 'ez-dashboard-dim))
          :action (lambda () (ez-agents-dashboard)) :help "RET: the agents dashboard")))

;;;; Filling the slow parts

(defun ez-dashboard--fill ()
  "Load agent support, scan chats and ask for usage, then redraw.  Runs deferred."
  (when (or (ez-dashboard-visible-p) (not (ez-dashboard--agents-ready-p)))
    (require 'ez-agents nil t)
    (require 'ez-agents-usage nil t)
    (when (featurep 'ez-agents)
      (add-hook 'ez-agents-change-hook #'ez-dashboard-refresh-soon)
      (add-hook 'ez-agents-usage-updated-hook #'ez-dashboard-refresh-soon))
    (ez-dashboard--refresh-chats)
    (ez-dashboard--fetch-usage)
    (ez-dashboard-refresh-soon)))

(defun ez-dashboard--fetch-usage ()
  "Ask each installed agent for its usage, if allowed and the dashboard is showing."
  (when (and ez-dashboard-fetch-usage (ez-dashboard-visible-p)
             (featurep 'ez-agents-usage) (boundp 'ez-agents-definitions))
    (dolist (def ez-agents-definitions)
      (ignore-errors
        (when (executable-find (car (plist-get (cdr def) :command)))
          (ez-agents-usage (car def)))))))

(defun ez-dashboard--on-tick ()
  "Keep slow caches fresh while the dashboard is showing."
  (when (featurep 'ez-agents)
    (ez-dashboard--refresh-chats)
    (ez-dashboard--fetch-usage)))

(defun ez-dashboard-sections-install ()
  "Register the built-in tiles and sections and queue the deferred fill."
  (setq ez-dashboard-cards
        (list #'ez-dashboard--tile-startup #'ez-dashboard--tile-packages
              #'ez-dashboard--tile-modules #'ez-dashboard--tile-plugins
              #'ez-dashboard--tile-emacs #'ez-dashboard--tile-agents))
  (ez-dashboard-define-section 'agents "Agents"
                               (ez-dashboard-icon "nf-md-robot_outline" "✱" 'ez-dashboard-section)
                               #'ez-dashboard--agents-section "a")
  (ez-dashboard-define-section 'projects "Recent projects"
                               (ez-dashboard-icon "nf-md-folder_clock_outline" "▸" 'ez-dashboard-section)
                               #'ez-dashboard--projects-section "p")
  (ez-dashboard-define-section 'chats "Recent conversations"
                               (ez-dashboard-icon "nf-md-message_text_clock_outline" "✉" 'ez-dashboard-section)
                               #'ez-dashboard--chats-section "c")
  (ez-dashboard-define-section 'files "Recent files"
                               (ez-dashboard-icon "nf-md-file_clock_outline" "▤" 'ez-dashboard-section)
                               #'ez-dashboard--files-section "f")
  (ez-dashboard-define-section 'session "Right now"
                               (ez-dashboard-icon "nf-md-pulse" "◉" 'ez-dashboard-section)
                               #'ez-dashboard--session-section "s")
  (ez-dashboard-define-section 'config "Configuration"
                               (ez-dashboard-icon "nf-md-cog_outline" "⚙" 'ez-dashboard-section)
                               #'ez-dashboard--config-section "m")
  (setq ez-dashboard-fill-function #'ez-dashboard--fill)
  (add-hook 'ez-dashboard-tick-hook #'ez-dashboard--on-tick))

(ez-dashboard-sections-install)

(provide 'ez-dashboard-sections)
;;; ez-dashboard-sections.el ends here
