;;; ez-agents-dashboard.el --- Full-window overview of all agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; `ez-agents-dashboard' shows everything at once: status cards, then every
;; project with its sessions, each session's latest terminal output and its
;; sub-agents.  Mark agents (`m') and act on them together (approve, deny,
;; send, kill) or on the one at point; filter by status (click a card) or text
;; (`/'); `i' opens the console (`ez-agents-console') aimed at the marked set.
;; `?' lists every key.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'ez-agents)
(require 'ez-agents-ui)
(require 'ez-agents-review)
(require 'ez-agents-chats)
(require 'ez-agents-usage)

(declare-function ez-agents-console "ez-agents-console")
(declare-function ez-agents-worktree-finish "ez-agents-worktree")
(declare-function ez-agents-new-worktree "ez-agents-worktree")

(defconst ez-agents-dashboard-buffer-name "*Agents Dashboard*")

(defface ez-agents-dashboard-card
  '((t :box (:line-width (2 . 1) :style flat-button) :weight bold))
  "Status summary cards."
  :group 'ez-agents)
(defface ez-agents-dashboard-output '((t :inherit shadow)) "Terminal tail lines."
  :group 'ez-agents)
(defface ez-agents-dashboard-title
  '((t :inherit font-lock-keyword-face :weight bold :height 1.3)) "Dashboard title."
  :group 'ez-agents)

(defvar ez-agents-dashboard--collapsed (make-hash-table :test #'equal))
(defvar ez-agents-dashboard--marked (make-hash-table :test #'equal) "Marked session ids.")
(defvar ez-agents-dashboard--expanded (make-hash-table :test #'equal) "Sessions showing more output.")
(defvar ez-agents-dashboard--status-filter nil "Only show sessions with this status.")
(defvar ez-agents-dashboard--query nil "Only show sessions matching this text.")
(defcustom ez-agents-dashboard-compact-width 64
  "Windows narrower than this get the compact sidebar rendering."
  :type 'integer
  :group 'ez-agents)

(defvar ez-agents-dashboard--width 100 "Body width the dashboard is being rendered for.")
(defvar ez-agents-dashboard--compact nil "Non-nil while rendering the narrow sidebar form.")
(defvar ez-agents-dashboard--timer nil)
(defvar ez-agents-dashboard--refresh-timer nil)

(defun ez-agents-dashboard--card (label status n)
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1]
                (lambda (_e) (interactive "e") (ez-agents-dashboard-filter-status status)))
    (propertize (format (if ez-agents-dashboard--compact " %s%s %d " " %s %s %d ")
                        (if (eq status 'review)
                            (propertize "✎" 'face 'ez-agents-waiting)
                          (ez-agents-ui--glyph status))
                        (if ez-agents-dashboard--compact "" label) n)
                'face (append (list 'ez-agents-dashboard-card (ez-agents-ui--status-face status))
                              (when (eq status ez-agents-dashboard--status-filter)
                                '((:inverse-video t))))
                'keymap map 'mouse-face 'highlight
                'help-echo "Click to filter by this status (click again to clear)")))

(defun ez-agents-dashboard--match-p (s)
  "Non-nil if top-level session S passes the status and text filters."
  (and (or (null ez-agents-dashboard--status-filter)
           (if (eq ez-agents-dashboard--status-filter 'review)
               (ez-agents-review-needs-review-p s)
             (eq (ez-agent-status s) ez-agents-dashboard--status-filter)))
       (or (null ez-agents-dashboard--query)
           (let ((case-fold-search t))
             (string-match-p
              (regexp-quote ez-agents-dashboard--query)
              (string-join (list (ez-agent-name s) (symbol-name (ez-agent-kind s))
                                 (ez-agents-project-name (ez-agent-project s))
                                 (string-join (ez-agents-tail s 3) " "))
                           " "))))))

(defun ez-agents-dashboard--visible-sessions (&optional root)
  (cl-remove-if-not (lambda (s) (and (or (null root) (equal (ez-agent-project s) root))
                                     (ez-agents-dashboard--match-p s)))
                    (ez-agents-sessions)))

(defun ez-agents-dashboard--visible-projects ()
  (let (roots)
    (dolist (s (ez-agents-dashboard--visible-sessions))
      (cl-pushnew (ez-agent-project s) roots :test #'equal))
    (nreverse roots)))

(defun ez-agents-dashboard--clip (s)
  (truncate-string-to-width s (max 16 (- ez-agents-dashboard--width 10)) nil nil "…"))

(defun ez-agents-dashboard--insert-sub (sub)
  (let* ((st (ez-agent-status sub))
         (left (concat (if ez-agents-dashboard--compact "      ↳ " "        ↳ ")
                       (ez-agents-ui--glyph st) " "
                       (propertize (ez-agents-dashboard--clip (ez-agent-name sub))
                                   'face (if (eq st 'done) 'ez-agents-done 'ez-agents-sub))))
         (right (propertize (ez-agents-ui--elapsed (ez-agent-activity sub))
                            'face 'ez-agents-dim)))
    (magit-insert-section (ez-sub (ez-agent-id sub))
      (magit-insert-heading (ez-agents-ui--row left right)))))

(defun ez-agents-dashboard--insert-session (s)
  (let* ((id (ez-agent-id s))
         (st (ez-agent-status s))
         (def (cdr (assq (ez-agent-kind s) ez-agents-definitions)))
         (compact ez-agents-dashboard--compact)
         (tail (ez-agents-tail s (cond ((gethash id ez-agents-dashboard--expanded) 10)
                                       ((eq st 'waiting) (if compact 2 3))
                                       (compact 0)
                                       (t 1))))
         (stat (ez-agent-diffstat s))
         (left (concat (cond ((gethash id ez-agents-dashboard--marked)
                              (propertize " ◆ " 'face 'ez-agents-waiting))
                             ((equal id ez-agents--current-chat)
                              (propertize " ▶ " 'face 'ez-agents-project))
                             (t "   "))
                       (ez-agents-ui--chevron-in ez-agents-dashboard--collapsed id)
                       " " (ez-agents-ui--glyph st) " "
                       (ez-agents-ui--icon (plist-get def :icon) (ez-agents-ui--status-face st))
                       " " (propertize (or (ez-agents-chats-session-title s) (ez-agent-name s)) 'face 'ez-agents-session)
                       (when (and (ez-agent-branch s) (not compact))
                         (propertize (format "  ⎇ %s" (ez-agent-branch s)) 'face 'ez-agents-dim))))
         (right (if compact
                    (propertize (ez-agents-ui--elapsed (ez-agent-activity s))
                                'face (ez-agents-ui--status-face st))
                  (concat
                 (when (and stat (> (car stat) 0))
                   (propertize (format "✎ +%d −%d %df  " (nth 1 stat) (nth 2 stat) (car stat))
                               'face (if (ez-agents-review-needs-review-p s)
                                         'ez-agents-waiting 'ez-agents-dim)))
                 (propertize
                  (format "%s %s%s" st (ez-agents-ui--elapsed (ez-agent-activity s))
                          (cond ((ez-agents-detached-p s) " · detached")
                                ((ez-agent-pid s) (format " · pid %d" (ez-agent-pid s)))
                                (t "")))
                  'face (ez-agents-ui--status-face st))))))
    (magit-insert-section (ez-session id)
      (magit-insert-heading (ez-agents-ui--row left right))
      (when (and compact (or (ez-agent-branch s) (and stat (> (car stat) 0))))
        (insert (propertize
                 (concat "      "
                         (when (ez-agent-branch s)
                           (ez-agents-dashboard--clip (format "⎇ %s" (ez-agent-branch s))))
                         (when (and stat (> (car stat) 0))
                           (format "%s✎ +%d −%d %df" (if (ez-agent-branch s) "  " "")
                                   (nth 1 stat) (nth 2 stat) (car stat)))
                         "\n")
                 'face (if (ez-agents-review-needs-review-p s) 'ez-agents-waiting 'ez-agents-dim))))
      (dolist (l tail)
        (insert (propertize (concat (if compact "      │ " "        │ ")
                                    (ez-agents-dashboard--clip l) "\n")
                            'face (if (eq st 'waiting) 'ez-agents-waiting
                                    'ez-agents-dashboard-output))))
      (dolist (sub (ez-agents-sessions id))
        (ez-agents-dashboard--insert-sub sub)))))

(defun ez-agents-dashboard--insert-project (root)
  (let* ((sessions (ez-agents-dashboard--visible-sessions root))
         (waiting (cl-count 'waiting sessions :key #'ez-agent-status))
         (left (concat " " (ez-agents-ui--chevron-in ez-agents-dashboard--collapsed root) " "
                       (ez-agents-ui--icon "nf-md-folder_outline" 'ez-agents-project) " "
                       (propertize (ez-agents-project-name root) 'face 'ez-agents-project)
                       (unless ez-agents-dashboard--compact
                         (concat "  " (propertize (abbreviate-file-name root) 'face 'ez-agents-dim)))))
         (right (propertize (if ez-agents-dashboard--compact
                                (format "%d%s" (length sessions)
                                        (if (> waiting 0) (format " · %d◐" waiting) ""))
                              (format "%d session%s%s" (length sessions)
                                      (if (= 1 (length sessions)) "" "s")
                                      (if (> waiting 0) (format " · %d waiting" waiting) "")))
                            'face (if (> waiting 0) 'ez-agents-waiting 'ez-agents-dim))))
    (magit-insert-section (ez-project root)
      (magit-insert-heading (ez-agents-ui--row left right))
      (dolist (s sessions) (ez-agents-dashboard--insert-session s))
      (insert "\n"))))

(defun ez-agents-dashboard--render ()
  (when-let* ((buf (get-buffer ez-agents-dashboard-buffer-name)))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (win (get-buffer-window buf t))
             (ez-agents-dashboard--width
              (if win
                  ;; narrowest window showing the buffer, so a sidebar beside a
                  ;; wide window is still drawn compactly
                  (apply #'min (mapcar #'window-body-width
                                       (get-buffer-window-list buf nil t)))
                100))
             (ez-agents-dashboard--compact
              (< ez-agents-dashboard--width ez-agents-dashboard-compact-width))
             (state (ez-agents-ui--point-state))
             (fresh (zerop (buffer-size)))
             (starts (mapcar (lambda (w) (cons w (line-number-at-pos (window-start w))))
                             (get-buffer-window-list buf nil t)))
             (tops (ez-agents-sessions))
             (_ (ez-agents-dashboard--prune-marks))
             (subs (cl-loop for s being the hash-values of ez-agents--table
                            when (and (ez-agent-parent s) (eq (ez-agent-status s) 'working))
                            count t)))
        (erase-buffer)
        (magit-insert-section (ez-root)
          (insert "\n  " (propertize "Agents" 'face 'ez-agents-dashboard-title)
                  (if ez-agents-dashboard--compact "\n  " "\n\n  ")
                  (mapconcat (lambda (st)
                               (ez-agents-dashboard--card
                                (capitalize (symbol-name st)) st
                                (cl-count st tops :key #'ez-agent-status)))
                             '(working waiting idle error)
                             (if ez-agents-dashboard--compact "" "  "))
                  (if ez-agents-dashboard--compact "" "  ")
                  (ez-agents-dashboard--card
                         "Review" 'review
                         (cl-count-if #'ez-agents-review-needs-review-p tops))
                  (if ez-agents-dashboard--compact
                      ""
                    (concat "  " (propertize (format " ↳ %d sub-agents working " subs)
                                              'face 'ez-agents-dim)))
                  "\n\n")
          (when-let* ((cards (ez-agents-usage-cards ez-agents-dashboard--width
                                                    ez-agents-dashboard--compact)))
            (insert cards "\n"))
          (if-let* ((projects (ez-agents-dashboard--visible-projects)))
              (mapc #'ez-agents-dashboard--insert-project projects)
            (insert (propertize
                     (if (ez-agents-sessions)
                         "  No agents match the filter.   C  clear it\n"
                       "  No agents running.   c  start one\n")
                     'face 'ez-agents-dim))))
        (magit-map-sections
         (lambda (s)
           (when (and (oref s hidden) (oref s content) (not (eq s magit-root-section)))
             (magit-section-hide s))))
        (setq ez-agents-dashboard--was-compact ez-agents-dashboard--compact)
        (ez-agents-ui--restore-point state fresh)
        (dolist (w (get-buffer-window-list buf nil t)) (set-window-point w (point)))
        (pcase-dolist (`(,w . ,line) starts)
          (when (window-live-p w)
            (save-excursion
              (goto-char (point-min)) (forward-line (1- line))
              (set-window-start w (point)))))))))

(defun ez-agents-dashboard-refresh ()
  "Re-render the dashboard (debounced)."
  (interactive)
  (unless (timerp ez-agents-dashboard--refresh-timer)
    (setq ez-agents-dashboard--refresh-timer
          (run-with-idle-timer 0.05 nil
                               (lambda ()
                                 (setq ez-agents-dashboard--refresh-timer nil)
                                 (ez-agents-dashboard--render))))))

(defun ez-agents-dashboard--tick ()
  (if (not (get-buffer-window ez-agents-dashboard-buffer-name t))
      (progn (when (timerp ez-agents-dashboard--timer) (cancel-timer ez-agents-dashboard--timer))
             (setq ez-agents-dashboard--timer nil))
    (cl-incf ez-agents-ui--frame)
    (ez-agents-dashboard--render)))

(defun ez-agents-dashboard--visibility (section)
  (when (memq (oref section type) '(ez-project ez-session))
    (if (gethash (oref section value) ez-agents-dashboard--collapsed) 'hide 'show)))

(defun ez-agents-dashboard--live-marks ()
  (sort (delq nil (mapcar #'ez-agents-session (hash-table-keys ez-agents-dashboard--marked)))
        (lambda (a b) (< (ez-agent-started a) (ez-agent-started b)))))

(defun ez-agents-dashboard--prune-marks ()
  (dolist (id (hash-table-keys ez-agents-dashboard--marked))
    (unless (ez-agents-session id) (remhash id ez-agents-dashboard--marked)))
  nil)

(defun ez-agents-dashboard--header ()
  (let ((marks (length (ez-agents-dashboard--live-marks))))
    (concat
     (propertize (if (ez-agents-workspace-active-p)
                     "  ? help · RET open · c new · l expand · q close"
                   "  ? help · n/p move · m mark · a approve · S send · R review · B worktree · i console")
                 'face 'ez-agents-dim)
     (when ez-agents-dashboard--status-filter
       (propertize (format " · filter: %s" ez-agents-dashboard--status-filter)
                   'face 'ez-agents-waiting))
     (when ez-agents-dashboard--query
       (propertize (format " · /%s" ez-agents-dashboard--query) 'face 'ez-agents-waiting))
     (when (> marks 0)
       (propertize (format " · ◆ %d marked" marks) 'face 'ez-agents-waiting)))))

(defvar-keymap ez-agents-dashboard-mode-map
  :doc "Keymap for `ez-agents-dashboard-mode'."
  "RET" #'ez-agents-ui-visit
  "<mouse-1>" #'ez-agents-dashboard-mouse-visit
  "TAB" #'ez-agents-dashboard-toggle
  "<tab>" #'ez-agents-dashboard-toggle
  "SPC" #'ez-agents-dashboard-peek
  "n" #'ez-agents-dashboard-next
  "p" #'ez-agents-dashboard-previous
  "W" #'ez-agents-dashboard-next-waiting
  "m" #'ez-agents-dashboard-mark
  "u" #'ez-agents-dashboard-unmark
  "t" #'ez-agents-dashboard-toggle-mark
  "M" #'ez-agents-dashboard-mark-waiting
  "U" #'ez-agents-dashboard-unmark-all
  "a" #'ez-agents-dashboard-approve
  "d" #'ez-agents-dashboard-deny
  "!" #'ez-agents-dashboard-interrupt
  "S" #'ez-agents-dashboard-send
  "s" #'ez-agents-dashboard-send
  "K" #'ez-agents-dashboard-kill
  "x" #'ez-agents-ui-kill
  "r" #'ez-agents-ui-rename
  "i" #'ez-agents-dashboard-interact
  "b" #'ez-agents-dashboard-broadcast
  "c" #'ez-agents-dashboard-new
  "B" #'ez-agents-dashboard-new-worktree
  "R" #'ez-agents-dashboard-review
  "z" #'ez-agents-dashboard-fullscreen
  "P" #'ez-agents-dashboard-finish
  "X" #'ez-agents-clear-ended
  "Z" #'ez-agents-dashboard-resume
  "h" #'ez-agents-dashboard-resume-chat
  "f" #'ez-agents-dashboard-filter-status
  "/" #'ez-agents-dashboard-filter-text
  "C" #'ez-agents-dashboard-clear-filters
  "w" #'ez-agents-goto-waiting
  "g" #'ez-agents-dashboard-refresh
  "?" #'ez-agents-dashboard-help
  "l" #'ez-agents-dashboard-toggle-layout
  "q" #'ez-agents-dashboard-quit)

(define-derived-mode ez-agents-dashboard-mode magit-section-mode "Agents-Dash"
  "Overview of every terminal agent."
  ;; Font-lock would strip the `face' properties these buffers set themselves;
  ;; switch it off after the mode and global font-lock have run.
  :after-hook (font-lock-mode -1)
  (setq-local truncate-lines t
              cursor-type nil
              line-spacing 0.2
              header-line-format '(:eval (ez-agents-dashboard--header))
              magit-section-visibility-indicators nil
              magit-section-highlight-hook nil)
  (hl-line-mode 1)
  (add-hook 'magit-section-set-visibility-hook #'ez-agents-dashboard--visibility nil t)
  (add-hook 'ez-agents-change-hook #'ez-agents-dashboard-refresh))

;;;; Workspace: dashboard as a sidebar, chat on the right

(defun ez-agents-dashboard--ensure-buffer ()
  (let ((buf (get-buffer-create ez-agents-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-agents-dashboard-mode) (ez-agents-dashboard-mode)))
    buf))

(defun ez-agents-workspace-active-p ()
  "Non-nil while the dashboard-sidebar + chat layout is up."
  (and ez-agents--workspace
       (frame-live-p (nth 1 ez-agents--workspace))
       (get-buffer-window ez-agents-dashboard-buffer-name (nth 1 ez-agents--workspace))
       t))

(defun ez-agents-workspace--chat-window (frame)
  "The window of FRAME that holds the chat (any non-dashboard window)."
  (let ((dash (get-buffer ez-agents-dashboard-buffer-name)))
    (or (let ((sel (frame-selected-window frame)))
          (and (not (eq (window-buffer sel) dash)) (not (window-minibuffer-p sel)) sel))
        (cl-find-if (lambda (w) (not (eq (window-buffer w) dash)))
                    (window-list frame 'no-minibuf)))))

(defun ez-agents-workspace-show (session buffer)
  "Lay the frame out as dashboard sidebar (left) and BUFFER's chat (right).
SESSION is the agent being shown.  Calling it again just swaps the chat."
  (let* ((frame (selected-frame))
         (dash (ez-agents-dashboard--ensure-buffer))
         (active (ez-agents-workspace-active-p))
         (saved (if active (car ez-agents--workspace) (current-window-configuration frame)))
         (right (and active (ez-agents-workspace--chat-window frame))))
    (setq ez-agents--current-chat (ez-agent-id session))
    (condition-case err
        (if right
            (progn (set-window-buffer right buffer) (select-window right))
          (let ((ignore-window-parameters t)) (delete-other-windows))
          (let* ((left (selected-window))
                 (right (split-window-right ez-agents-workspace-width)))
            ;; The chat first: a new window starts as a copy of the dashboard, so
            ;; anything failing after this must not leave it that way.
            (set-window-buffer right buffer)
            (set-window-buffer left dash)
            (ignore-errors (set-window-dedicated-p left t))
            (ignore-errors (window-preserve-size left t t))
            (select-window right)))
      (error (set-window-configuration saved)
             (signal (car err) (cdr err))))
    (setq ez-agents--workspace (list saved frame))
    (unless (timerp ez-agents-dashboard--timer)
      (setq ez-agents-dashboard--timer (run-with-timer 0.5 0.5 #'ez-agents-dashboard--tick)))
    (ez-agents-dashboard--render)))

(defun ez-agents-workspace-close ()
  "Leave the dashboard+chat layout, restoring the windows from before it."
  (interactive)
  (let ((cfg (car ez-agents--workspace)))
    (setq ez-agents--workspace nil)
    (when cfg (set-window-configuration cfg))))

(defun ez-agents-dashboard-quit ()
  "Close the sidebar layout, or bury the dashboard when it is not in one."
  (interactive)
  (if (ez-agents-workspace-active-p) (ez-agents-workspace-close) (quit-window)))

(defun ez-agents-dashboard-toggle-layout ()
  "Switch between the full dashboard and the sidebar-with-chat layout."
  (interactive)
  (if (ez-agents-workspace-active-p)
      (let ((win (get-buffer-window ez-agents-dashboard-buffer-name
                                    (nth 1 ez-agents--workspace))))
        (select-window win)
        (set-window-dedicated-p win nil)
        (let ((ignore-window-parameters t)) (delete-other-windows win))
        (setq ez-agents--workspace nil)
        (ez-agents-dashboard--render))
    (if-let* ((s (and ez-agents--current-chat (ez-agents-session ez-agents--current-chat))))
        (ez-agents-jump s)
      (user-error "Select an agent first (RET), then `l' shows it beside the list"))))

(defun ez-agents-dashboard--on-resize (_frame)
  "Redraw the dashboard when its window changes between compact and wide."
  (when-let* ((win (get-buffer-window ez-agents-dashboard-buffer-name t)))
    (let ((compact (< (window-body-width win) ez-agents-dashboard-compact-width)))
      (unless (eq compact (buffer-local-value 'ez-agents-dashboard--was-compact
                                              (window-buffer win)))
        (ez-agents-dashboard-refresh)))))

(defvar-local ez-agents-dashboard--was-compact nil)
(add-hook 'window-size-change-functions #'ez-agents-dashboard--on-resize)

(defun ez-agents-dashboard-toggle ()
  "Fold or unfold the project or session at point."
  (interactive)
  (let ((sec (magit-current-section)))
    (while (and sec (not (memq (oref sec type) '(ez-project ez-session))))
      (setq sec (oref sec parent)))
    (when sec
      (let ((id (oref sec value)))
        (if (gethash id ez-agents-dashboard--collapsed)
            (remhash id ez-agents-dashboard--collapsed)
          (puthash id t ez-agents-dashboard--collapsed))
        (ez-agents-dashboard--render)))))

(defun ez-agents-dashboard--top-at-point ()
  (when-let* ((s (ez-agents-ui--session-at-point)))
    (ez-agents--top s)))

(defun ez-agents-dashboard--targets ()
  "Live marked sessions, else the session at point."
  (or (cl-remove-if-not #'ez-agents-live-p (ez-agents-dashboard--live-marks))
      (when-let* ((s (ez-agents-dashboard--top-at-point))) (list s))
      (user-error "No agent at point and nothing marked")))

(defun ez-agents-dashboard--confirm (verb sessions)
  (or (null (cdr sessions))
      (y-or-n-p (format "%s %d agents? " verb (length sessions)))
      (user-error "Cancelled")))

;;;; Navigation

(defun ez-agents-dashboard--row-positions (&optional pred)
  (let (ps)
    (magit-map-sections
     (lambda (sec)
       (when (and (eq (oref sec type) 'ez-session)
                  (or (null pred)
                      (when-let* ((s (ez-agents-session (oref sec value))))
                        (funcall pred s))))
         (push (marker-position (oref sec start)) ps))))
    (sort ps #'<)))

(defun ez-agents-dashboard--move (direction &optional pred)
  (let* ((here (line-beginning-position))
         (ps (ez-agents-dashboard--row-positions pred))
         (target (if (> direction 0)
                     (cl-find-if (lambda (p) (> p here)) ps)
                   (cl-find-if (lambda (p) (< p here)) (reverse ps)))))
    (if target (goto-char target) (message "No more agents in that direction"))))

(defun ez-agents-dashboard-next () "Move to the next session." (interactive)
       (ez-agents-dashboard--move 1))
(defun ez-agents-dashboard-previous () "Move to the previous session." (interactive)
       (ez-agents-dashboard--move -1))
(defun ez-agents-dashboard-next-waiting ()
  "Move to the next session that is waiting for input (wraps around)."
  (interactive)
  (let ((pred (lambda (s) (eq (ez-agent-status s) 'waiting))))
    (unless (ignore-errors (let ((here (point)))
                             (ez-agents-dashboard--move 1 pred)
                             (> (point) here)))
      (let ((first (car (ez-agents-dashboard--row-positions pred))))
        (if first (goto-char first) (message "No agent is waiting for input"))))))

(defun ez-agents-dashboard-mouse-visit (event)
  "Click: jump to the agent under the mouse, or fold the project."
  (interactive "e")
  (mouse-set-point event)
  (ez-agents-ui-visit))

(defun ez-agents-dashboard-peek ()
  "Show more (or less) terminal output for the session at point."
  (interactive)
  (if-let* ((s (ez-agents-dashboard--top-at-point)))
      (progn (if (gethash (ez-agent-id s) ez-agents-dashboard--expanded)
                 (remhash (ez-agent-id s) ez-agents-dashboard--expanded)
               (puthash (ez-agent-id s) t ez-agents-dashboard--expanded))
             (ez-agents-dashboard--render))
    (user-error "No agent at point")))

;;;; Marks

(defun ez-agents-dashboard--set-mark (on)
  (if-let* ((s (ez-agents-dashboard--top-at-point)))
      (progn (if on (puthash (ez-agent-id s) t ez-agents-dashboard--marked)
               (remhash (ez-agent-id s) ez-agents-dashboard--marked))
             (ez-agents-dashboard--render)
             (ez-agents-dashboard--move 1))
    (user-error "No agent at point")))

(defun ez-agents-dashboard-mark () "Mark the agent at point." (interactive)
       (ez-agents-dashboard--set-mark t))
(defun ez-agents-dashboard-unmark () "Unmark the agent at point." (interactive)
       (ez-agents-dashboard--set-mark nil))
(defun ez-agents-dashboard-toggle-mark ()
  "Toggle the mark on the agent at point."
  (interactive)
  (ez-agents-dashboard--set-mark
   (not (when-let* ((s (ez-agents-dashboard--top-at-point)))
          (gethash (ez-agent-id s) ez-agents-dashboard--marked)))))
(defun ez-agents-dashboard-mark-waiting ()
  "Mark every visible agent that is waiting for input."
  (interactive)
  (dolist (s (ez-agents-dashboard--visible-sessions))
    (when (eq (ez-agent-status s) 'waiting)
      (puthash (ez-agent-id s) t ez-agents-dashboard--marked)))
  (ez-agents-dashboard--render))
(defun ez-agents-dashboard-unmark-all () "Clear all marks." (interactive)
       (clrhash ez-agents-dashboard--marked) (ez-agents-dashboard--render))

;;;; Acting on the marked set (or the agent at point)

(defun ez-agents-dashboard--raw (verb key)
  (let ((ss (ez-agents-dashboard--targets)))
    (ez-agents-dashboard--confirm verb ss)
    (dolist (s ss) (ez-agents-send-raw s key))
    (message "%s: %s" verb (mapconcat #'ez-agent-name ss ", "))))

(defun ez-agents-dashboard-approve ()
  "Press Enter in the marked agents' terminals (or the one at point)."
  (interactive) (ez-agents-dashboard--raw "Approve" "\r"))
(defun ez-agents-dashboard-deny ()
  "Press Escape in the marked agents' terminals (or the one at point)."
  (interactive) (ez-agents-dashboard--raw "Deny" "\e"))
(defun ez-agents-dashboard-interrupt ()
  "Send Ctrl-C to the marked agents (or the one at point)."
  (interactive) (ez-agents-dashboard--raw "Interrupt" "\C-c"))

(defun ez-agents-dashboard-send ()
  "Send a prompt to the marked agents (or the one at point)."
  (interactive)
  (let* ((ss (ez-agents-dashboard--targets))
         (text (read-string (format "Prompt for %s: "
                                    (if (cdr ss) (format "%d agents" (length ss))
                                      (ez-agent-name (car ss)))))))
    (ez-agents-dashboard--confirm "Send to" ss)
    (dolist (s ss) (ez-agents-send s text))))

(defun ez-agents-dashboard-kill ()
  "Kill the marked agents (or the one at point)."
  (interactive)
  (let ((ss (ez-agents-dashboard--targets)))
    (when (y-or-n-p (format "Kill %s? " (if (cdr ss) (format "%d agents" (length ss))
                                          (ez-agent-name (car ss)))))
      (mapc #'ez-agents-kill ss))))

;;;; Filters

(defun ez-agents-dashboard-filter-status (&optional status)
  "Show only agents with STATUS; with the same status again, or \"all\", clear."
  (interactive
   (list (let ((pick (completing-read "Status: " '("all" "working" "waiting" "idle" "error"
                                                   "needs-review")
                                      nil t)))
           (if (equal pick "needs-review") 'review (intern-soft pick)))))
  (setq ez-agents-dashboard--status-filter
        (unless (or (null status) (eq status 'all)
                    (eq status ez-agents-dashboard--status-filter))
          status))
  (ez-agents-dashboard--render))

(defun ez-agents-dashboard-filter-text (query)
  "Show only agents whose name, project or recent output matches QUERY."
  (interactive (list (read-string "Filter (empty clears): "
                                  ez-agents-dashboard--query)))
  (setq ez-agents-dashboard--query (unless (string-empty-p query) query))
  (ez-agents-dashboard--render))

(defun ez-agents-dashboard-clear-filters ()
  "Remove the status and text filters."
  (interactive)
  (setq ez-agents-dashboard--status-filter nil ez-agents-dashboard--query nil)
  (ez-agents-dashboard--render))

(defun ez-agents-dashboard--require-top ()
  (or (ez-agents-dashboard--top-at-point) (user-error "No agent at point")))

(defun ez-agents-dashboard-review ()
  "Review the changes the agent at point has made."
  (interactive)
  (ez-agents-review (ez-agents-dashboard--require-top)))

(defun ez-agents-dashboard-fullscreen ()
  "Fullscreen the agent at point (press the toggle key in its terminal to restore)."
  (interactive)
  (ez-agents-toggle-fullscreen (ez-agents-dashboard--require-top)))

(defun ez-agents-dashboard--project-at-point ()
  "Root of the project the line at point belongs to, or nil."
  (let ((sec (magit-current-section)))
    (while (and sec (not (memq (oref sec type) '(ez-project ez-session ez-sub))))
      (setq sec (oref sec parent)))
    (pcase (and sec (oref sec type))
      ('ez-project (oref sec value))
      ((or 'ez-session 'ez-sub)
       (when-let* ((s (ez-agents-session (oref sec value))))
         (ez-agent-project s))))))

(defun ez-agents-dashboard-new ()
  "Start an agent in the project at point (not the last project visited)."
  (interactive)
  (let ((default-directory (or (ez-agents-dashboard--project-at-point) default-directory)))
    (call-interactively #'ez-agents-new)))

(defun ez-agents-dashboard-new-worktree ()
  "Start an agent in a new git worktree of the project at point."
  (interactive)
  (require 'ez-agents-worktree)
  (let ((default-directory (or (ez-agents-dashboard--project-at-point) default-directory)))
    (call-interactively #'ez-agents-new-worktree)))

(defun ez-agents-dashboard-finish ()
  "Open a PR, merge, or remove the worktree of the agent at point."
  (interactive)
  (require 'ez-agents-worktree)
  (ez-agents-worktree-finish (ez-agents-dashboard--require-top)))

(defun ez-agents-dashboard-resume-chat ()
  "Start an agent resuming an existing chat in the directory at point."
  (interactive)
  (require 'ez-agents-chats)
  (let* ((s (ez-agents-dashboard--top-at-point))
         (sec (magit-current-section))
         (dir (cond (s (ez-agent-cwd s))
                    ((and sec (eq (oref sec type) 'ez-project)) (oref sec value)))))
    (ez-agents-resume-chat (ez-agents--read-kind) dir)))

(defun ez-agents-dashboard-resume ()
  "Restart the ended agent at point with its resume command."
  (interactive)
  (ez-agents-resume (ez-agents-dashboard--require-top)))

(defun ez-agents-dashboard-help ()
  "Show the dashboard key bindings."
  (interactive)
  (with-help-window "*Agents Dashboard Help*"
    (princ "Agents dashboard\n\n")
    (princ "Move      n/p session   W next waiting   TAB fold   SPC peek output   click row/card\n")
    (princ "Mark      m mark   u unmark   t toggle   M mark all waiting   U clear marks\n")
    (princ "Act       a approve (Enter)   d deny (Esc)   ! Ctrl-C   S/s send prompt\n")
    (princ "          K kill   x kill at point   r rename   c new agent\n")
    (princ "          Acts on the marked agents, or the one at point if none are marked.\n")
    (princ "Review    R review changes   B new agent in a worktree   P finish (PR/merge/remove)\n")
    (princ "          X clear every ended agent\n")
    (princ "          h resume an existing chat in this directory   Z restart an ended agent\n")
    (princ "          (RET also reattaches a detached agent)\n")
    (princ "Layout    selecting (RET) or starting (c) an agent turns this into a sidebar with the chat\n")
    (princ "          on the right;  l expands it back to the full dashboard;  q closes the layout\n")
    (princ "Zoom      z fullscreen the agent at point (toggle it off again from the terminal)\n")
    (princ "Jump      RET terminal   w first waiting   i console   b broadcast console\n")
    (princ "Filter    f status (incl. needs-review)   / text   C clear   (click a status card)\n")
    (princ "Other     g refresh   ? help   q quit\n")))

(defun ez-agents-dashboard-interact ()
  "Open the console on the marked agents, else the agent or project at point."
  (interactive)
  (require 'ez-agents-console)
  (if-let* ((marks (ez-agents-dashboard--live-marks)))
      (ez-agents-console (cons 'ids (mapcar #'ez-agent-id marks)))
    (let ((sec (magit-current-section)))
      (while (and sec (not (memq (oref sec type) '(ez-project ez-session ez-sub))))
        (setq sec (oref sec parent)))
      (ez-agents-console
       (pcase (and sec (oref sec type))
         ('ez-project (cons 'project (oref sec value)))
         ((or 'ez-session 'ez-sub) (cons 'session (oref sec value)))
         (_ 'all))))))

(defun ez-agents-dashboard-broadcast ()
  "Open the console aimed at every agent."
  (interactive)
  (require 'ez-agents-console)
  (ez-agents-console 'all))

;;;###autoload
(defun ez-agents-dashboard ()
  "Show the agents dashboard in the selected window."
  (interactive)
  (let ((buf (get-buffer-create ez-agents-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-agents-dashboard-mode) (ez-agents-dashboard-mode)))
    (ez-agents-dashboard--render)
    (if (ez-agents-workspace-active-p)
        (select-window (get-buffer-window buf (nth 1 ez-agents--workspace)))
      (pop-to-buffer-same-window buf))
    (unless (timerp ez-agents-dashboard--timer)
      (setq ez-agents-dashboard--timer (run-with-timer 0.5 0.5 #'ez-agents-dashboard--tick)))
    buf))

;;;; The sidebar (same window setup as the layout opened from the dashboard)

(defun ez-agents-dashboard-sidebar-show ()
  "Show the dashboard as a left sidebar; a chat only opens when one is selected in it."
  (let* ((dash (ez-agents-dashboard--ensure-buffer))
         (win (or (get-buffer-window dash)
                  (let ((w (split-window (frame-root-window) (- ez-agents-workspace-width) 'left)))
                    (set-window-buffer w dash)
                    (ignore-errors (set-window-dedicated-p w t))
                    (ignore-errors (window-preserve-size w t t))
                    w))))
    (ez-agents-dashboard--render)
    (unless (timerp ez-agents-dashboard--timer)
      (setq ez-agents-dashboard--timer (run-with-timer 0.5 0.5 #'ez-agents-dashboard--tick)))
    win))

(defun ez-agents-dashboard-sidebar-toggle ()
  "Toggle the dashboard sidebar."
  (if (ez-agents-workspace-active-p)
      ;; one press closes the chat and the sidebar together
      (progn (ez-agents-workspace-close)
             (when-let* ((win (get-buffer-window ez-agents-dashboard-buffer-name)))
               (set-window-dedicated-p win nil)
               (if (window-parent win) (delete-window win) (quit-window nil win))))
    (if-let* ((win (get-buffer-window ez-agents-dashboard-buffer-name)))
        (progn (set-window-dedicated-p win nil)
               (if (window-parent win) (delete-window win) (quit-window nil win)))
      (select-window (ez-agents-dashboard-sidebar-show)))))

(provide 'ez-agents-dashboard)
;;; ez-agents-dashboard.el ends here
