;;; my-workspace-popups.el --- Transient buffers as popups (popper)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Buffers that are looked at briefly (help, diagnostics, compilation output,
;; search results, terminals, ...) open as a popup at the bottom instead of
;; rearranging your windows.  Popups are grouped per workspace: each tabspaces
;; workspace only cycles through / toggles its own popups.
;;
;;   SPC '    show/hide the latest popup      SPC "    cycle through popups
;;   SPC b P  turn a popup into a normal buffer (and back)

(declare-function my/leader "my-keys-leader")
(declare-function tabspaces--current-tab-name "tabspaces")

(defun my/popper-group ()
  "Group popups by tabspaces workspace, falling back to the project."
  (or (and (fboundp 'tabspaces--current-tab-name) (tabspaces--current-tab-name))
      (and (fboundp 'popper-group-by-project) (popper-group-by-project))))

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

(my/leader
  "'" '(popper-toggle :wk "popup: toggle")
  "\"" '(popper-cycle :wk "popup: cycle")
  "bP" '(popper-toggle-type :wk "popup <-> normal"))

(provide 'my-workspace-popups)
