;;; my-workspace-popups.el --- Transient buffers as popups (popper)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Buffers that are looked at briefly (help, diagnostics, compilation output,
;; search results, terminals, ...) open as a popup at the bottom instead of
;; rearranging your windows.  Popups are grouped per workspace: each tabspaces
;; workspace only cycles through / toggles its own popups.
;;
;;   SPC ' or C-'   hide all popups / bring them back    SPC "   cycle through popups
;;   C-u -1 SPC "   cycle backwards                       SPC b P  popup <-> normal buffer
;;
;; "This workspace's popups" is tracked here, not by popper: see the section
;; "Which popup belongs to which workspace" below and MAINTAINING.md.

(require 'cl-lib)
(require 'seq)

(declare-function my/leader "my-keys-leader")

(defun my/popper-group ()
  "Return a stable identifier for the current workspace (tab).
A tab's *name* cannot be used for that unless it was set explicitly: unnamed
tabs are renamed after the buffer they display (\"*scratch*\", \"*Messages*\"),
so every popup would end up in a group of its own.  Tabspaces names project
tabs explicitly; other tabs are identified by their position."
  (let ((tab (tab-bar--current-tab)))
    (if (alist-get 'explicit-name tab)
        (alist-get 'name tab)
      (format "tab-%d" (tab-bar--current-tab-index)))))

(use-package popper
  :demand t
  :custom
  (popper-reference-buffers
   '(;; by name
     "\\*Messages\\*" "\\*Warnings\\*" "\\*Backtrace\\*" "\\*Compile-Log\\*"
     "\\*Async Shell Command\\*" "\\*Shell Command Output\\*" "\\*eldoc\\*"
     "\\*Completions\\*" "\\*Agenda Commands\\*" "\\*Org Select\\*" "\\*Org Help\\*"
     "\\*Flymake diagnostics" "\\*xref\\*" "\\*dape-repl\\*" "\\*eglot-help"
     "^\\*Occur" "^\\*grep\\*" "Output\\*$"
     ;; by major mode
     help-mode helpful-mode apropos-mode compilation-mode grep-mode occur-mode
     messages-buffer-mode special-mode
     flymake-diagnostics-buffer-mode flymake-project-diagnostics-mode
     xref--xref-buffer-mode ghostel-mode ghostel-compile-mode
     "^\\*.*ghostel\\*$"))
  (popper-group-function #'my/popper-group)
  (popper-window-height 0.35)
  :config
  (popper-mode 1)
  (popper-echo-mode 1))                  ; popup names in the echo area while cycling

;;;; Which popup belongs to which workspace
;;
;; popper files a popup under whichever tab is current *when its bookkeeping
;; runs*.  Open a popup in workspace A, switch to B, and it is re-filed under B:
;; `SPC "' in B then cycled through A's popups and A lost them.  And popups that
;; popper has not yet seen on screen never joined the cycle at all.  So the
;; commands below do not use popper's lists.  Which popups a workspace owns is
;; asked of tabspaces (the same buffer lists `consult-buffer' shows); without
;; tabspaces a popup belongs to the workspace it was last shown in, and one
;; never shown anywhere to every workspace until it is.  What is on screen is
;; read from the windows themselves.

(defvar my/popper--home (make-hash-table :test #'eq :weakness 'key)
  "Popup buffer -> group (see `my/popper-group') it was last shown in.")

(defvar my/popper--ring nil
  "Alist GROUP -> that workspace's popup buffers, in the order `SPC \"' cycles them.")

(defvar my/popper--hidden nil
  "Alist GROUP -> popup buffers hidden by the last `my/popper-toggle' there.")

(defun my/popper--popup-p (buf)
  "Non-nil if BUF is a live popup that popper manages."
  (and (buffer-live-p buf) (not (minibufferp buf))
       (let ((status (buffer-local-value 'popper-popup-status buf)))
         (cond ((memq status '(popup user-popup)) t)
               ((memq status '(raised suppressed)) nil)
               (t (popper-popup-p buf))))))

(defun my/popper--note-homes (&rest _)
  "Record that the popups on screen in this workspace belong to it."
  (when (bound-and-true-p popper-mode)
    (let ((group (my/popper-group)))
      (dolist (win (window-list nil 'no-mini))
        (when (my/popper--popup-p (window-buffer win))
          (puthash (window-buffer win) group my/popper--home))))))

(add-hook 'window-buffer-change-functions #'my/popper--note-homes)

(defvar tabspaces-mode)
(declare-function tabspaces--local-buffer-p "tabspaces")

(defun my/popper--belongs-p (buf group)
  "Non-nil if popup BUF belongs to the current workspace, named GROUP.
With tabspaces running, that is tabspaces' own answer: the buffer is one of the
workspace's buffers, or one shared by all (`tabspaces-include-buffers', here
*Messages*).  Without it, a popup belongs to the workspace it was last shown in,
and one never shown anywhere belongs to every workspace until it is.  Internal
buffers (names starting with a space) are never cycled."
  (and (not (string-prefix-p " " (buffer-name buf)))
       (if (bound-and-true-p tabspaces-mode)
           (and (tabspaces--local-buffer-p buf) t)
         (let ((home (gethash buf my/popper--home)))
           (or (null home) (equal home group))))))

(defun my/popper--candidates ()
  "Popup buffers of this workspace, most recently shown first."
  (let ((group (my/popper-group)))
    (cl-remove-if-not
     (lambda (buf) (and (my/popper--popup-p buf) (my/popper--belongs-p buf group)))
     (mapcar #'cdr (popper--find-popups (buffer-list))))))

(defun my/popper--ring-for (group candidates)
  "GROUP's cycling order over the popups CANDIDATES, kept stable.
Popups already in the order keep their place; new ones go last."
  (let* ((old (alist-get group my/popper--ring nil nil #'equal))
         (kept (cl-remove-if-not (lambda (b) (memq b candidates)) old))
         (new (cl-remove-if (lambda (b) (memq b kept)) (reverse candidates))))
    (setf (alist-get group my/popper--ring nil nil #'equal) (append kept new))))

(defun my/popper--show (buf win)
  "Show popup BUF in window WIN (one that holds another popup), else in a new one."
  (if (window-live-p win)
      (set-window-buffer win buf)
    (display-buffer buf))
  (when-let* ((w (get-buffer-window buf))) (select-window w))
  (puthash buf (my/popper-group) my/popper--home)
  (popper--update-popups))

(defun my/popper--announce (ring current)
  "Say which popups there are in RING, with CURRENT marked."
  (message "%s" (mapconcat (lambda (b)
                             (if (eq b current)
                                 (propertize (format "[%s]" (buffer-name b)) 'face 'bold)
                               (buffer-name b)))
                           ring "  ")))

(defun my/popper-cycle (&optional arg)
  "Switch to the next popup of this workspace; a negative ARG goes backwards.
With no popup showing, open the one shown most recently.  The popups cycle in a
fixed order and wrap around; a lone popup stays put instead of vanishing."
  (interactive "p")
  (my/popper--note-homes)
  (let* ((step (if (and arg (< arg 0)) -1 1))
         (group (my/popper-group))
         (candidates (my/popper--candidates))
         (ring (my/popper--ring-for group candidates))
         (visible (cl-remove-if-not #'get-buffer-window candidates)))
    (cond
     ((null ring) (message "No popups in this workspace"))
     ((null visible)
      (my/popper--show (car candidates) nil)
      (my/popper--announce ring (car candidates)))
     (t
      (let* ((current (car visible))
             (n (length ring))
             (i (cl-position current ring))
             (j (mod (+ i step) n))
             (tries 0))
        ;; Pass over popups that are already on screen.
        (while (and (< tries n) (not (eq (nth j ring) current)) (get-buffer-window (nth j ring)))
          (setq j (mod (+ j step) n) tries (1+ tries)))
        (let ((next (nth j ring)))
          (if (eq next current)
              (message "Only popup: %s" (buffer-name current))
            (my/popper--show next (get-buffer-window current))
            (my/popper--announce ring next))))))))

;; `popper-toggle' only closes the *latest* popup and decides between "hide" and
;; "show" from a bookkeeping list that can go stale (a popup closed with `q' or
;; replaced by another buffer), so it sometimes did nothing.  This version looks
;; at the windows actually on screen: if any popup is visible, hide all of them;
;; otherwise bring back the ones just hidden in this workspace (or the most
;; recently shown popup of it).
(defun my/popper-toggle ()
  "Hide every visible popup, or restore the popups hidden last time."
  (interactive)
  (popper--update-popups)
  (my/popper--note-homes)
  (let ((group (my/popper-group))
        (visible (popper--find-popups
                  (mapcar #'window-buffer (window-list nil 'no-mini)))))
    (if visible
        (let ((hidden (mapcar #'cdr visible)))
          (setf (alist-get group my/popper--hidden nil nil #'equal) hidden)
          (popper--bury-all)
          ;; Anything popper's bookkeeping missed: close the window directly.
          (dolist (win (window-list nil 'no-mini))
            (when (and (window-live-p win)
                       (not (one-window-p t))
                       (memq (window-buffer win) hidden))
              (delete-window win))))
      (let ((bufs (seq-filter #'buffer-live-p
                              (reverse (alist-get group my/popper--hidden nil nil #'equal)))))
        (cond (bufs (dolist (buf bufs) (display-buffer buf)))
              ((car (my/popper--candidates)) (my/popper--show (car (my/popper--candidates)) nil))
              (t (message "No popups in this workspace")))))))

;; Terminals forward most keys to the shell: let the popup toggle and the
;; M-SPC leader reach Emacs from a Ghostel popup too.
(with-eval-after-load 'ghostel
  (setopt ghostel-keymap-exceptions
          (seq-union ghostel-keymap-exceptions '("C-'" "M-SPC"))))

(global-set-key (kbd "C-'") #'my/popper-toggle)   ; works in any state, terminals included

(my/leader
  "'" '(my/popper-toggle :wk "popup: toggle (C-')")
  "\"" '(my/popper-cycle :wk "popup: cycle (C-u -1: back)")
  "bP" '(popper-toggle-type :wk "popup <-> normal"))

(provide 'my-workspace-popups)
