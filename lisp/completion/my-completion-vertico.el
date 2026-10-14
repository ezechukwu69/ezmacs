;;; my-completion-vertico.el --- Vertico  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function general-define-key "general")

(use-package vertico
  :demand t
  :custom
  (vertico-cycle t)
  (vertico-count 14)
  (vertico-resize nil)
  :config
  (vertico-mode 1)
  ;; Bind per Evil state too: Evil's own insert/normal maps (C-n, C-p, C-k, ...)
  ;; otherwise take precedence over `vertico-map' in the minibuffer.
  (general-define-key :keymaps 'vertico-map
                      :states '(insert normal emacs motion)
                      "C-n" 'vertico-next
                      "C-p" 'vertico-previous
                      "C-j" 'vertico-next
                      "C-k" 'vertico-previous
                      "C-l" 'vertico-insert
                      "M-j" 'vertico-next-group
                      "M-k" 'vertico-previous-group))

(use-package vertico-directory
  :ensure nil
  :after vertico
  :bind (:map vertico-map
              ("RET"   . vertico-directory-enter)
              ("DEL"   . vertico-directory-delete-char)
              ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package vertico-multiform
  :ensure nil
  :after vertico
  :config
  (setq vertico-multiform-categories
        '((consult-grep buffer)
          (imenu buffer)))
  (vertico-multiform-mode 1))

(provide 'my-completion-vertico)
