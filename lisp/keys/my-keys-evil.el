;;; my-keys-evil.el --- Evil  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'my-ui-prefs)

(defcustom my/evil-enabled t
  "Whether Evil is enabled at startup, until you toggle it.
Toggle at runtime with `my/evil-toggle' (SPC t e, or C-c t e); that choice is
remembered across sessions and then wins over this setting."
  :type 'boolean :group 'evil)

(defun my/evil--startup-enabled-p ()
  "Whether Evil should start on: your last toggle if any, else `my/evil-enabled'."
  (pcase (my/ui-pref :evil)
    ('on t)
    ('off nil)
    (_ my/evil-enabled)))

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
  (when (my/evil--startup-enabled-p) (evil-mode 1))
  ;; Modes that are better in emacs state
  (dolist (m '(agent-shell-mode))
    (evil-set-initial-state m 'emacs)))

(use-package evil-collection
  :after evil
  :demand t
  :init
  ;; evil-collection binds `gz' in many modes to "go to the REPL" (ielm in Emacs
  ;; Lisp, the shell in Python, ...), which beats the global `gz' multiple-cursor
  ;; prefix (editing/multiple-cursors).  Keep the REPL jump, one key over.
  (setq evil-collection-binding-overrides '((goto-repl :key "gZ")))
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

;; The keys (C-c + / C-c -, in Evil and with Evil off) are declared in
;; my-keys-table.el with the rest of the shared bindings.
(use-package evil-numbers
  :after evil
  :commands (evil-numbers/inc-at-pt evil-numbers/dec-at-pt))

(use-package evil-args
  :after evil
  :config
  (define-key evil-inner-text-objects-map "a" 'evil-inner-arg)
  (define-key evil-outer-text-objects-map "a" 'evil-outer-arg))

(defun my/evil-toggle ()
  "Toggle Evil keybindings globally, and remember the choice for next time."
  (interactive)
  (evil-mode 'toggle)
  (my/ui-pref-save :evil (if evil-mode 'on 'off))
  (message "Evil %s (remembered)" (if evil-mode "enabled" "disabled")))

;; Works with or without Evil (plain global binding).
(global-set-key (kbd "C-c t e") #'my/evil-toggle)

(provide 'my-keys-evil)
