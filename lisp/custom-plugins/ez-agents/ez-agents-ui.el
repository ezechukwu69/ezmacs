;;; ez-agents-ui.el --- Sidebar for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; A magit-section buffer shown in a left side window:
;;
;;    AGENTS           ▶ 2   3 waiting   ● 1
;;
;;     ~ emacs.d                                  3
;;     ▶ ✱ Claude Code                      working 2m
;;         ▶ explore auth flow                    41s
;;         ✓ run the tests                     done 9s
;;       ✱ Codex                                idle 6m
;;
;; Folding is kept in `ez-agents-ui--collapsed' (not magit's visibility cache)
;; so the chevrons stay in sync across the 5 Hz re-render that drives the
;; spinner.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'ez-agents)

(declare-function nerd-icons-mdicon "nerd-icons")

(defgroup ez-agents-ui nil "Sidebar for ez-agents." :group 'ez-agents)

(defcustom ez-agents-ui-width 42
  "Width of the sidebar window."
  :type 'integer)

(defcustom ez-agents-ui-working-glyph "▶"
  "Static glyph shown for a working agent."
  :type 'string)

(defconst ez-agents-ui-buffer-name "*Agents*")

;;;; Faces

(defface ez-agents-title '((t :inherit font-lock-keyword-face :weight bold :height 0.9))
  "Sidebar header."
  :group 'ez-agents)
(defface ez-agents-project '((t :inherit font-lock-function-name-face :weight bold))
  "Project rows."
  :group 'ez-agents)
(defface ez-agents-session '((t :inherit default))
  "Session rows."
  :group 'ez-agents)
(defface ez-agents-sub '((t :inherit default :slant italic))
  "Sub-agent rows."
  :group 'ez-agents)
(defface ez-agents-working '((t :inherit success :weight bold)) "Working status."
  :group 'ez-agents)
(defface ez-agents-waiting '((t :inherit warning :weight bold)) "Waiting status."
  :group 'ez-agents)
(defface ez-agents-idle '((t :inherit shadow)) "Idle status."
  :group 'ez-agents)
(defface ez-agents-done '((t :inherit font-lock-comment-face)) "Finished status."
  :group 'ez-agents)
(defface ez-agents-error '((t :inherit error :weight bold)) "Failed status."
  :group 'ez-agents)
(defface ez-agents-dim '((t :inherit shadow :height 0.9)) "Secondary text."
  :group 'ez-agents)

;;;; State

(defvar ez-agents-ui--collapsed (make-hash-table :test #'equal)
  "Ids of folded sections.")
(defvar ez-agents-ui--frame 0)
(defvar ez-agents-ui--timer nil)
(defvar ez-agents-ui--refresh-timer nil)

(defun ez-agents-ui--status-face (status)
  (pcase status
    ((or 'working 'starting) 'ez-agents-working)
    ((or 'waiting 'review) 'ez-agents-waiting)
    ('error 'ez-agents-error)
    ('done 'ez-agents-done)
    (_ 'ez-agents-idle)))

(defun ez-agents-ui--glyph (status)
  (propertize
   (pcase status
     ('working ez-agents-ui-working-glyph)
     ('starting "◌")
     ('waiting "◐")
     ('error "✗")
     ('done "✓")
     (_ "●"))
   'face (ez-agents-ui--status-face status)))

(defun ez-agents-ui--chevron-in (table id)
  "Fold chevron for ID according to the fold TABLE."
  (propertize (if (gethash id table) "▸" "▾") 'face 'ez-agents-dim))

(defun ez-agents-ui--icon (name face)
  (or (and name (require 'nerd-icons nil t) (fboundp 'nerd-icons-mdicon)
           (ignore-errors (nerd-icons-mdicon name :face face)))
      (propertize "✱" 'face face)))

(defun ez-agents-ui--elapsed (since)
  (let ((s (max 0 (floor (- (float-time) since)))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm" (/ s 60)))
          (t (format "%dh%02d" (/ s 3600) (mod (/ s 60) 60))))))

(defun ez-agents-ui--chevron (id)
  (propertize (if (gethash id ez-agents-ui--collapsed) "▸" "▾") 'face 'ez-agents-dim))

(defun ez-agents-ui--row (left right)
  "LEFT text with RIGHT right-aligned."
  (concat left
          (propertize " " 'display
                      `(space :align-to (- right ,(1+ (string-width right)))))
          right))

(defun ez-agents-ui--counts ()
  "Alist of (STATUS . N) over top-level sessions."
  (let (acc)
    (dolist (s (ez-agents-sessions))
      (cl-incf (alist-get (ez-agent-status s) acc 0)))
    acc))

;;;; Rendering

(defun ez-agents-ui--point-state ()
  "Describe point so `ez-agents-ui--restore-point' can put it back after a redraw.
Returns (IDENT OFFSET COLUMN LINE): the section at point, how many lines into it
point is, and the absolute line as a fallback."
  (let ((sec (ignore-errors (magit-current-section))))
    (list (and sec (magit-section-ident sec))
          (and sec (- (line-number-at-pos) (line-number-at-pos (oref sec start))))
          (current-column)
          (line-number-at-pos))))

(defun ez-agents-ui--restore-point (state &optional fresh type)
  "Restore point from STATE (see `ez-agents-ui--point-state') after a redraw.
Point returns to the same line *within* its section, not to the section's
heading, so output lines and blank gaps stay put.  If FRESH (the buffer was
empty), go to the first section of TYPE (default `ez-session')."
  (pcase-let ((`(,ident ,offset ,col ,line) state))
    (goto-char (point-min))
    (let ((sec (and ident (not fresh) (magit-get-section ident))))
      (cond
       (fresh
        (let (first)
          (magit-map-sections
           (lambda (s)
             (when (eq (oref s type) (or type 'ez-session))
               (let ((p (marker-position (oref s start))))
                 (when (or (null first) (< p first)) (setq first p))))))
          (if first (goto-char first) (forward-line 3))))
       (sec
        (let ((span (max 0 (- (line-number-at-pos (max (point-min) (1- (oref sec end))))
                              (line-number-at-pos (oref sec start))))))
          (goto-char (oref sec start))
          (forward-line (min (or offset 0) span))))
       (t (forward-line (1- (min line (line-number-at-pos (point-max))))))))
    (move-to-column col)))


(defun ez-agents-ui--insert-sub (sub)
  (let* ((st (ez-agent-status sub))
         (face (if (eq st 'done) 'ez-agents-done 'ez-agents-sub))
         (left (concat "      " (ez-agents-ui--glyph st) " "
                       (propertize (truncate-string-to-width
                                    (ez-agent-name sub) (- ez-agents-ui-width 22) nil nil "…")
                                   'face face)))
         (right (propertize (ez-agents-ui--elapsed (ez-agent-activity sub))
                            'face 'ez-agents-dim)))
    (magit-insert-section (ez-sub (ez-agent-id sub))
      (magit-insert-heading (ez-agents-ui--row left right)))))

(defun ez-agents-ui--insert-session (s)
  (let* ((id (ez-agent-id s))
         (subs (ez-agents-sessions id))
         (st (ez-agent-status s))
         (def (cdr (assq (ez-agent-kind s) ez-agents-definitions)))
         (left (concat " "
                       (if subs (ez-agents-ui--chevron id) " ")
                       " " (ez-agents-ui--glyph st) " "
                       (ez-agents-ui--icon (plist-get def :icon)
                                           (ez-agents-ui--status-face st))
                       " " (propertize (ez-agent-name s) 'face 'ez-agents-session)))
         (right (propertize (format "%s %s" st (ez-agents-ui--elapsed (ez-agent-activity s)))
                            'face (ez-agents-ui--status-face st))))
    (magit-insert-section (ez-session id (and subs (gethash id ez-agents-ui--collapsed)))
      (magit-insert-heading (ez-agents-ui--row left right))
      (dolist (sub subs) (ez-agents-ui--insert-sub sub)))))

(defun ez-agents-ui--insert-project (root)
  (let* ((sessions (cl-remove-if-not (lambda (s) (equal (ez-agent-project s) root))
                                     (ez-agents-sessions)))
         (left (concat " " (ez-agents-ui--chevron root) " "
                       (ez-agents-ui--icon "nf-md-folder_outline" 'ez-agents-project) " "
                       (propertize (ez-agents-project-name root) 'face 'ez-agents-project)))
         (right (propertize (number-to-string (length sessions)) 'face 'ez-agents-dim)))
    (magit-insert-section (ez-project root (gethash root ez-agents-ui--collapsed))
      (magit-insert-heading (ez-agents-ui--row left right))
      (dolist (s sessions) (ez-agents-ui--insert-session s))
      (insert "\n"))))

(defun ez-agents-ui--header ()
  (let ((counts (ez-agents-ui--counts)))
    (concat " " (propertize " AGENTS " 'face 'ez-agents-title)
            "  "
            (mapconcat
             (lambda (st)
               (when-let* ((n (alist-get st counts)))
                 (concat (ez-agents-ui--glyph st) " "
                         (propertize (format "%d" n) 'face (ez-agents-ui--status-face st)))))
             (cl-remove-if-not (lambda (st) (alist-get st counts))
                               '(working waiting idle error))
             "  "))))

(defun ez-agents-ui--render ()
  (when-let* ((buf (get-buffer ez-agents-ui-buffer-name)))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (state (ez-agents-ui--point-state))
             (fresh (zerop (buffer-size)))
             (starts (mapcar (lambda (w) (cons w (line-number-at-pos (window-start w))))
                             (get-buffer-window-list buf nil t))))
        (erase-buffer)
        (magit-insert-section (ez-root)
          (insert "\n")
          (if-let* ((projects (ez-agents-projects)))
              (mapc #'ez-agents-ui--insert-project projects)
            (insert (propertize "  No agents running.\n\n  c  start one\n" 'face 'ez-agents-dim)))
          (insert (propertize "\n  RET jump · TAB fold · c new · x kill · w waiting\n"
                              'face 'ez-agents-dim)))
        ;; magit-section only records the HIDE flag at insert time; apply it.
        (magit-map-sections
         (lambda (s)
           (when (and (oref s hidden) (oref s content)
                      (not (eq s magit-root-section)))
             (magit-section-hide s))))
        (ez-agents-ui--restore-point state fresh)
        (dolist (w (get-buffer-window-list buf nil t))
          (set-window-point w (point)))
        (pcase-dolist (`(,w . ,line) starts)
          (when (window-live-p w)
            (save-excursion
              (goto-char (point-min)) (forward-line (1- line))
              (set-window-start w (point)))))))))

(defun ez-agents-ui-refresh ()
  "Re-render the sidebar (debounced)."
  (interactive)
  (unless (timerp ez-agents-ui--refresh-timer)
    (setq ez-agents-ui--refresh-timer
          (run-with-idle-timer 0.03 nil
                               (lambda ()
                                 (setq ez-agents-ui--refresh-timer nil)
                                 (ez-agents-ui--render))))))

(defun ez-agents-ui--tick ()
  (if (not (get-buffer-window ez-agents-ui-buffer-name t))
      (progn (when (timerp ez-agents-ui--timer) (cancel-timer ez-agents-ui--timer))
             (setq ez-agents-ui--timer nil))
    (when (cl-some (lambda (s) (memq (ez-agent-status s) '(working starting)))
                   (cl-loop for s being the hash-values of ez-agents--table collect s))
      (cl-incf ez-agents-ui--frame)
      (ez-agents-ui--render))))

;;;; Mode

(defun ez-agents-ui--panel-background ()
  (let ((bg (face-background 'default nil t)))
    (when (and bg (color-defined-p bg))
      (if (eq (frame-parameter nil 'background-mode) 'dark)
          (color-lighten-name bg 4)
        (color-darken-name bg 3)))))

(defun ez-agents-ui--visibility (section)
  "Visibility hook function: fold sections per `ez-agents-ui--collapsed'."
  (when (memq (oref section type) '(ez-project ez-session))
    (if (gethash (oref section value) ez-agents-ui--collapsed) 'hide 'show)))

(defvar-keymap ez-agents-mode-map
  :doc "Keymap for `ez-agents-mode'."
  "RET" #'ez-agents-ui-visit
  "TAB" #'ez-agents-ui-toggle
  "<tab>" #'ez-agents-ui-toggle
  "c" #'ez-agents-new
  "x" #'ez-agents-ui-kill
  "r" #'ez-agents-ui-rename
  "s" #'ez-agents-ui-send
  "w" #'ez-agents-goto-waiting
  "g" #'ez-agents-ui-refresh
  "q" #'quit-window)

(define-derived-mode ez-agents-mode magit-section-mode "Agents"
  "Sidebar listing terminal agents by project."
  ;; Font-lock would strip the `face' properties these buffers set themselves;
  ;; switch it off after the mode and global font-lock have run.
  :after-hook (font-lock-mode -1)
  (setq-local truncate-lines t
              cursor-type nil
              line-spacing 0.25
              left-fringe-width 4
              right-fringe-width 4
              mode-line-format nil
              header-line-format '(:eval (ez-agents-ui--header))
              magit-section-visibility-indicators nil
              magit-section-highlight-hook nil)
  (when-let* ((bg (ez-agents-ui--panel-background)))
    (face-remap-add-relative 'default :background bg)
    (face-remap-add-relative 'fringe :background bg)
    (face-remap-add-relative 'header-line :background bg :box nil :underline nil))
  (hl-line-mode 1)
  (add-hook 'magit-section-set-visibility-hook #'ez-agents-ui--visibility nil t)
  (add-hook 'ez-agents-change-hook #'ez-agents-ui-refresh))

;;;; Commands

(defun ez-agents-ui--session-at-point ()
  (let ((sec (magit-current-section)))
    (while (and sec (not (memq (oref sec type) '(ez-session ez-sub))))
      (setq sec (oref sec parent)))
    (and sec (ez-agents-session (oref sec value)))))

(defun ez-agents-ui--require-session ()
  (or (ez-agents-ui--session-at-point) (user-error "No agent on this line")))

(defun ez-agents-ui-visit ()
  "Jump to the terminal of the agent at point."
  (interactive)
  (if-let* ((s (ez-agents-ui--session-at-point)))
      (ez-agents-jump s)
    (ez-agents-ui-toggle)))

(defun ez-agents-ui-toggle ()
  "Fold or unfold the project or session at point."
  (interactive)
  (let ((sec (magit-current-section)))
    (while (and sec (not (memq (oref sec type) '(ez-project ez-session))))
      (setq sec (oref sec parent)))
    (when sec
      (let ((id (oref sec value)))
        (if (gethash id ez-agents-ui--collapsed)
            (remhash id ez-agents-ui--collapsed)
          (puthash id t ez-agents-ui--collapsed))
        (ez-agents-ui--render)))))

(defun ez-agents-ui-kill ()
  "Kill the agent at point."
  (interactive)
  (let ((s (ez-agents-ui--require-session)))
    (when (y-or-n-p (format "Kill %s? " (ez-agent-name s)))
      (ez-agents-kill s))))

(defun ez-agents-ui-rename ()
  "Rename the agent at point."
  (interactive)
  (let ((s (ez-agents-ui--require-session)))
    (ez-agents-rename s (read-string "Name: " (ez-agent-name s)))))

(defun ez-agents-ui-send ()
  "Send a prompt to the agent at point."
  (interactive)
  (let ((s (ez-agents-ui--require-session)))
    (ez-agents-send s (read-string (format "Prompt for %s: " (ez-agent-name s))))))

;; The sidebar is the dashboard (see `ez-agents-dashboard'), so the sidebar and the
;; layout opened by selecting an agent are one and the same.

;;;###autoload
(defun ez-agents-sidebar-show ()
  "Show the agents sidebar (the dashboard as a narrow left window)."
  (interactive)
  (require 'ez-agents-dashboard)
  (ez-agents-dashboard-sidebar-show))

;;;###autoload
(defun ez-agents-sidebar-toggle ()
  "Toggle the agents sidebar (the dashboard as a narrow left window)."
  (interactive)
  (require 'ez-agents-dashboard)
  (ez-agents-dashboard-sidebar-toggle))

(provide 'ez-agents-ui)
;;; ez-agents-ui.el ends here
