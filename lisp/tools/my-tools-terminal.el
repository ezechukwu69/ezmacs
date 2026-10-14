;;; my-tools-terminal.el --- Terminal: Ghostel (libghostty)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Ghostel is a terminal emulator for Emacs built on libghostty-vt, the VT
;; engine of the Ghostty terminal: true colour, Kitty keyboard/graphics
;; protocols, hyperlinks, shell integration (directory tracking, prompt jumping)
;; for bash/zsh/fish/nushell.  The first time it runs it offers to download a
;; prebuilt native module, so no toolchain is needed.
;;
;; One terminal per project: `ghostel-project' names buffers after the project,
;; and tabspaces keeps each one inside its workspace.

(declare-function my/leader "my-keys-leader")
(defvar my/data-dir)

(use-package ghostel
  :commands (ghostel ghostel-project ghostel-project-list-buffers)
  :init
  (with-eval-after-load 'project
    (add-to-list 'project-switch-commands '(ghostel-project "Terminal") t))
  :custom
  ;; Keep the native module outside elpa/ so package upgrades never delete the
  ;; file while Emacs has it loaded; fetch the prebuilt binary without asking.
  (ghostel-module-directory (expand-file-name "ghostel/" my/data-dir))
  (ghostel-module-auto-install 'download)
  :config
  ;; Let `C-x p m' (project-prefix-map) open the project terminal too.
  (with-eval-after-load 'project
    (keymap-set project-prefix-map "m" #'ghostel-project)))

;; Evil: normal/insert states work in the terminal buffer.
(use-package evil-ghostel
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))

;; consult-buffer integration + terminal picker with live preview.
(use-package consult-ghostel
  :after (ghostel consult)
  :hook (after-init . consult-ghostel-mode)
  :commands (consult-ghostel consult-ghostel-project))

;; `compile' output rendered by the same VT engine (colours, progress bars).
(use-package ghostel-compile
  :ensure nil
  :after ghostel
  :hook (after-init . ghostel-compile-global-mode))

(defun my/terminal-here ()
  "Open (or switch to) the terminal of the current project, else a plain one."
  (interactive)
  (if (project-current) (ghostel-project) (ghostel)))

(my/leader "ot" '(my/terminal-here :wk "terminal (project)")
           "oT" '(ghostel :wk "terminal (new, cwd)")
           "ob" '(consult-ghostel :wk "pick terminal"))

(provide 'my-tools-terminal)
