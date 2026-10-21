;;; ez-agents-console.el --- Interactive console for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; A separate buffer to drive agents without leaving your window layout:
;;
;;   Claude Code · emacs.d   working 2m           <- live preview of the target
;;     │ ...last lines of its terminal...
;;   ───────────────────────────────────────
;;   → emacs.d: run the tests                     <- what you sent
;;   ❯ type a prompt here
;;
;; The target is one session, a whole project, every waiting agent, or all
;; agents (broadcast).  RET sends the prompt to every agent in the target;
;; `C-c C-r' sends a raw key (Enter, Esc, Ctrl-C, arrows, y/n, 1-3) which is
;; how you answer permission prompts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-agents)
(require 'ez-agents-ui)

(declare-function ez-agents-dashboard "ez-agents-dashboard")

(defconst ez-agents-console-buffer-name "*Agents Console*")

(defface ez-agents-console-prompt '((t :inherit font-lock-keyword-face :weight bold))
  "Console prompt."
  :group 'ez-agents)
(defface ez-agents-console-divider '((t :inherit shadow :underline t :extend t))
  "Line between preview and input."
  :group 'ez-agents)
(defface ez-agents-console-sent '((t :inherit shadow :slant italic))
  "Echo of sent prompts."
  :group 'ez-agents)

(defcustom ez-agents-console-preview-lines 14
  "Terminal lines shown in the preview of a single-session target."
  :type 'integer
  :group 'ez-agents)

(defconst ez-agents-console-keys
  '(("enter" . "\r") ("escape" . "\e") ("ctrl-c" . "\C-c") ("ctrl-d" . "\C-d")
    ("up" . "\e[A") ("down" . "\e[B") ("tab" . "\t") ("shift-tab" . "\e[Z")
    ("y" . "y") ("n" . "n") ("1" . "1") ("2" . "2") ("3" . "3"))
  "Named raw keys for `ez-agents-console-send-key'.")

(defvar-local ez-agents-console--target 'all)
(defvar-local ez-agents-console--divider nil)
(defvar-local ez-agents-console--input-start nil)
(defvar-local ez-agents-console--sent nil "Recent (LABEL . TEXT), newest first.")
(defvar-local ez-agents-console--history nil)
(defvar-local ez-agents-console--history-index -1)
(defvar ez-agents-console--timer nil)

;;;; Preview

(defun ez-agents-console--preview ()
  (let* ((sessions (ez-agents-resolve-target ez-agents-console--target))
         (w (max 20 (- (window-width) 6)))
         (clip (lambda (s) (truncate-string-to-width s w nil nil "…"))))
    (concat
     "\n"
     (cond
      ((null sessions)
       (propertize (format "  No live agents for target: %s\n"
                           (ez-agents-target-label ez-agents-console--target))
                   'face 'ez-agents-dim))
      ((null (cdr sessions))
       (let* ((s (car sessions)) (st (ez-agent-status s)))
         (concat
          "  " (ez-agents-ui--glyph st) " "
          (propertize (ez-agent-name s) 'face 'ez-agents-project) " · "
          (propertize (ez-agents-project-name (ez-agent-project s)) 'face 'ez-agents-dim)
          "   " (propertize (format "%s %s" st (ez-agents-ui--elapsed (ez-agent-activity s)))
                             'face (ez-agents-ui--status-face st))
          "\n"
          (mapconcat (lambda (l) (propertize (concat "    │ " (funcall clip l))
                                             'face 'ez-agents-dashboard-output))
                     (ez-agents-tail s ez-agents-console-preview-lines) "\n")
          "\n")))
      (t
       (mapconcat
        (lambda (s)
          (let ((st (ez-agent-status s)))
            (concat "  " (ez-agents-ui--glyph st) " "
                    (propertize (format "%-14s" (ez-agent-name s)) 'face 'ez-agents-session)
                    (propertize (format "%-10s" (ez-agents-project-name (ez-agent-project s)))
                                'face 'ez-agents-dim)
                    (propertize (funcall clip (or (car (ez-agents-tail s 1)) ""))
                                'face 'ez-agents-dashboard-output)
                    "\n")))
        sessions "")))
     (when ez-agents-console--sent
       (concat "\n"
               (mapconcat (lambda (e)
                            (propertize (funcall clip (format "  → %s: %s" (car e) (cdr e)))
                                        'face 'ez-agents-console-sent))
                          (reverse (cl-subseq ez-agents-console--sent
                                              0 (min 4 (length ez-agents-console--sent))))
                          "\n")
               "\n")))))

(defun ez-agents-console--lock (beg end)
  (add-text-properties beg end '(read-only t rear-nonsticky t front-sticky nil)))

(defun ez-agents-console--refresh ()
  (when-let* ((buf (get-buffer ez-agents-console-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (modified (buffer-modified-p)))
        (save-excursion
          (delete-region (point-min) ez-agents-console--divider)
          (goto-char (point-min))
          (let ((beg (point)))
            (insert (ez-agents-console--preview))
            (ez-agents-console--lock beg (point))))
        (set-buffer-modified-p modified)))))

(defun ez-agents-console--tick ()
  (if (not (get-buffer-window ez-agents-console-buffer-name t))
      (progn (when (timerp ez-agents-console--timer) (cancel-timer ez-agents-console--timer))
             (setq ez-agents-console--timer nil))
    (ez-agents-console--refresh)))

(defun ez-agents-console--header ()
  (concat " " (propertize " TARGET " 'face 'ez-agents-title) " "
          (propertize (ez-agents-target-label ez-agents-console--target) 'face 'ez-agents-project)
          (propertize (format "  (%d live)"
                              (length (ez-agents-resolve-target ez-agents-console--target)))
                      'face 'ez-agents-dim)
          (propertize "   RET send · M-RET newline · C-c C-t target · C-c C-r key · C-c C-j jump"
                      'face 'ez-agents-dim)))

;;;; Mode

(defvar-keymap ez-agents-console-mode-map
  :doc "Keymap for `ez-agents-console-mode'."
  "RET" #'ez-agents-console-send
  "C-c C-c" #'ez-agents-console-send
  "M-RET" #'newline
  "S-<return>" #'newline
  "C-c C-t" #'ez-agents-console-set-target
  "C-c C-r" #'ez-agents-console-send-key
  "C-c C-k" #'ez-agents-console-interrupt
  "C-c C-j" #'ez-agents-console-jump
  "C-c C-d" #'ez-agents-console-dashboard
  "M-p" #'ez-agents-console-history-prev
  "M-n" #'ez-agents-console-history-next
  "C-c C-q" #'quit-window)

(define-derived-mode ez-agents-console-mode text-mode "Agents-Console"
  "Compose prompts for, and watch, terminal agents."
  ;; Font-lock would strip the `face' properties these buffers set themselves;
  ;; switch it off after the mode and global font-lock have run.
  :after-hook (font-lock-mode -1)
  (setq-local header-line-format '(:eval (ez-agents-console--header))
              truncate-lines t
              line-spacing 0.2)
  (add-hook 'ez-agents-change-hook #'ez-agents-console--refresh))

(defun ez-agents-console--init ()
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "\n")
    ;; Stays put while the separator is inserted after it, then advances when
    ;; `ez-agents-console--refresh' inserts the preview before it.
    (setq ez-agents-console--divider (copy-marker (point)))
    (let ((beg (point)))
      (insert (propertize " " 'display '(space :align-to right) 'face 'ez-agents-console-divider)
              "\n"
              (propertize "❯ " 'face 'ez-agents-console-prompt))
      (ez-agents-console--lock beg (point)))
    (set-marker-insertion-type ez-agents-console--divider t)
    (setq ez-agents-console--input-start (copy-marker (point)))
    (set-marker-insertion-type ez-agents-console--input-start nil)))

;;;; Commands

(defun ez-agents-console--input ()
  (string-trim (buffer-substring-no-properties ez-agents-console--input-start (point-max))))

(defun ez-agents-console--clear-input ()
  (delete-region ez-agents-console--input-start (point-max))
  (goto-char (point-max)))

(defun ez-agents-console--targets-or-error ()
  (or (ez-agents-resolve-target ez-agents-console--target)
      (user-error "No live agents for target: %s"
                  (ez-agents-target-label ez-agents-console--target))))

(defun ez-agents-console-send ()
  "Send the prompt to every agent in the target.  An empty prompt sends Enter."
  (interactive)
  (let* ((text (ez-agents-console--input))
         (sessions (ez-agents-console--targets-or-error)))
    (when (and (cdr sessions) (not (string-empty-p text))
               (not (y-or-n-p (format "Send to %d agents? " (length sessions)))))
      (user-error "Cancelled"))
    (dolist (s sessions) (ez-agents-send s text))
    (unless (string-empty-p text)
      (push text ez-agents-console--history)
      (push (cons (ez-agents-target-label ez-agents-console--target) text)
            ez-agents-console--sent))
    (setq ez-agents-console--history-index -1)
    (ez-agents-console--clear-input)
    (ez-agents-console--refresh)))

(defun ez-agents-console-send-key (key)
  "Send the raw KEY (a name from `ez-agents-console-keys') to the target."
  (interactive (list (completing-read "Key: " (mapcar #'car ez-agents-console-keys) nil t)))
  (let ((seq (cdr (assoc key ez-agents-console-keys))))
    (dolist (s (ez-agents-console--targets-or-error))
      (ez-agents-send-raw s seq))
    (message "Sent %s to %s" key (ez-agents-target-label ez-agents-console--target))))

(defun ez-agents-console-interrupt ()
  "Send Ctrl-C to the target."
  (interactive)
  (ez-agents-console-send-key "ctrl-c"))

(defun ez-agents-console--target-candidates ()
  (append
   '(("All agents" . all) ("All waiting for input" . waiting))
   (mapcar (lambda (r) (cons (format "Project: %s" (ez-agents-project-name r))
                             (cons 'project r)))
           (ez-agents-projects))
   (mapcar (lambda (s) (cons (format "Session: %s (%s)" (ez-agent-name s)
                                     (ez-agents-project-name (ez-agent-project s)))
                             (cons 'session (ez-agent-id s))))
           (ez-agents-sessions))))

(defun ez-agents-console-set-target ()
  "Choose which agents the console talks to."
  (interactive)
  (let* ((cands (ez-agents-console--target-candidates))
         (pick (completing-read "Target: " cands nil t)))
    (setq ez-agents-console--target (cdr (assoc pick cands)))
    (ez-agents-console--refresh)))

(defun ez-agents-console-jump ()
  "Jump to the terminal of the first agent in the target."
  (interactive)
  (ez-agents-jump (car (ez-agents-console--targets-or-error))))

(defun ez-agents-console-dashboard ()
  "Open the dashboard."
  (interactive)
  (require 'ez-agents-dashboard)
  (ez-agents-dashboard))

(defun ez-agents-console--history-move (step)
  (let ((n (+ ez-agents-console--history-index step)))
    (when (and (>= n -1) (< n (length ez-agents-console--history)))
      (setq ez-agents-console--history-index n)
      (ez-agents-console--clear-input)
      (when (>= n 0) (insert (nth n ez-agents-console--history))))))

(defun ez-agents-console-history-prev () (interactive) (ez-agents-console--history-move 1))
(defun ez-agents-console-history-next () (interactive) (ez-agents-console--history-move -1))

;;;###autoload
(defun ez-agents-console (&optional target)
  "Open the agents console.  TARGET defaults to all agents.
Interactively, a prefix argument asks for the target."
  (interactive (list (when current-prefix-arg
                       (let ((c (ez-agents-console--target-candidates)))
                         (cdr (assoc (completing-read "Target: " c nil t) c))))))
  (let ((buf (get-buffer-create ez-agents-console-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-agents-console-mode)
        (ez-agents-console-mode)
        (ez-agents-console--init))
      (when target (setq ez-agents-console--target target)))
    (ez-agents-console--refresh)
    (select-window
     (display-buffer buf '((display-buffer-reuse-window display-buffer-pop-up-window)
                           (inhibit-same-window . t))))
    (goto-char (point-max))
    (unless (timerp ez-agents-console--timer)
      (setq ez-agents-console--timer (run-with-timer 1 1 #'ez-agents-console--tick)))
    buf))

(provide 'ez-agents-console)
;;; ez-agents-console.el ends here
