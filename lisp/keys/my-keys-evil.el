;;; my-keys-evil.el --- Evil  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(defcustom my/evil-enabled t
  "Whether Evil is enabled at startup.
Toggle at runtime with `my/evil-toggle' (SPC t e, or C-c t e)."
  :type 'boolean :group 'evil)

;; Emacs 31+ globalized modes no longer define `evil-mode-buffers', which
;; Evil 1.15 reads in `evil-initializing-p' (void-variable errors otherwise).
(defvar evil-mode-buffers nil)

(use-package evil
  :demand t
  :init
  (setq evil-want-integration t
        evil-want-keybinding nil      ; evil-collection handles it
        evil-want-C-u-scroll t
        evil-want-C-i-jump nil
        evil-undo-system 'undo-redo
        evil-respect-visual-line-mode t
        evil-split-window-below t
        evil-vsplit-window-right t
        evil-want-Y-yank-to-eol t
        evil-search-module 'isearch)
  :config
  (when my/evil-enabled (evil-mode 1))
  ;; Modes that are better in emacs state
  (dolist (m '(agent-shell-mode))
    (evil-set-initial-state m 'emacs)))

(use-package evil-collection
  :after evil
  :demand t
  :config
  (evil-collection-init))

(use-package evil-surround
  :after evil
  :config (global-evil-surround-mode 1))

(use-package evil-commentary
  :after evil
  :config (evil-commentary-mode 1))

(use-package evil-matchit
  :after evil
  :config (global-evil-matchit-mode 1))

(use-package evil-numbers
  :after evil
  :bind (:map evil-normal-state-map
              ("C-c +" . evil-numbers/inc-at-pt)
              ("C-c -" . evil-numbers/dec-at-pt)))

(use-package evil-args
  :after evil
  :config
  (define-key evil-inner-text-objects-map "a" 'evil-inner-arg)
  (define-key evil-outer-text-objects-map "a" 'evil-outer-arg))

(defun my/evil-toggle ()
  "Toggle Evil keybindings globally."
  (interactive)
  (evil-mode 'toggle)
  (message "Evil %s" (if evil-mode "enabled" "disabled")))

;; Works with or without Evil (plain global binding).
(global-set-key (kbd "C-c t e") #'my/evil-toggle)

(provide 'my-keys-evil)
