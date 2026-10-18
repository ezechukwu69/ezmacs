;;; my-workspace-popups.el --- Transient buffers as popups (popper)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Buffers that are looked at briefly (help, diagnostics, compilation output,
;; search results, terminals, ...) open as a popup at the bottom instead of
;; rearranging your windows.  Popups are grouped per workspace: each tabspaces
;; workspace only cycles through / toggles its own popups.
;;
;;   SPC ' or C-'   hide all popups / bring them back    SPC "   cycle through popups
;;   SPC b P  turn a popup into a normal buffer (and back)

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

;; `popper-toggle' only closes the *latest* popup and decides between "hide" and
;; "show" from a bookkeeping list that can go stale (a popup closed with `q' or
;; replaced by another buffer), so it sometimes did nothing.  This version looks
;; at the windows actually on screen: if any popup is visible, hide all of them;
;; otherwise bring back the ones just hidden (or the latest buried popup).
(defvar my/popper--hidden nil
  "Popup buffers hidden by the last `my/popper-toggle'.")

(defun my/popper-toggle ()
  "Hide every visible popup, or restore the popups hidden last time."
  (interactive)
  (popper--update-popups)
  (let ((visible (popper--find-popups
                  (mapcar #'window-buffer (window-list nil 'no-mini)))))
    (if visible
        (progn
          (setq my/popper--hidden (mapcar #'cdr visible))
          (popper--bury-all)
          ;; Anything popper's bookkeeping missed: close the window directly.
          (dolist (win (window-list nil 'no-mini))
            (when (and (window-live-p win)
                       (not (one-window-p t))
                       (memq (window-buffer win) my/popper--hidden))
              (delete-window win))))
      (let ((bufs (seq-filter #'buffer-live-p (reverse my/popper--hidden))))
        (if bufs
            (dolist (buf bufs) (display-buffer buf))
          (popper-open-latest (funcall popper-group-function)))))))

;; Terminals forward most keys to the shell: let the popup toggle and the
;; M-SPC leader reach Emacs from a Ghostel popup too.
(with-eval-after-load 'ghostel
  (setopt ghostel-keymap-exceptions
          (seq-union ghostel-keymap-exceptions '("C-'" "M-SPC"))))

(global-set-key (kbd "C-'") #'my/popper-toggle)   ; works in any state, terminals included

(my/leader
  "'" '(my/popper-toggle :wk "popup: toggle (C-')")
  "\"" '(popper-cycle :wk "popup: cycle")
  "bP" '(popper-toggle-type :wk "popup <-> normal"))

(provide 'my-workspace-popups)
