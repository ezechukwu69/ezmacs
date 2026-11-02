;;; my-completion-embark.el --- Context actions  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package embark
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim))
  :init
  (setq prefix-help-command #'embark-prefix-help-command)
  (my/leader "ha" '(embark-act :wk "act") "hb" '(embark-bindings :wk "bindings")))

(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; Editing exported search results.  `C-. E' on a ripgrep/grep search opens the
;; matches in a `grep-mode' buffer; Emacs 31+ can edit them in place
;; (`grep-change-to-grep-edit-mode', no wgrep needed) and applies each change
;; to the source buffer as you type.  Its own key for entering that mode is `e',
;; but Evil's `e' (word end) shadows it and `i' is a no-op in the read-only
;; buffer, so there was no way in.  Like wgrep in Doom: `i' enters edit mode,
;; edit normally (cw, ci", i, a, ...), `ZZ' (or C-c C-c) leaves it.  The source
;; buffers are changed but not saved: `SPC f s' in each, or `C-x s'.
(with-eval-after-load 'grep
  (with-eval-after-load 'evil
    (evil-define-key 'normal grep-mode-map "i" #'grep-change-to-grep-edit-mode)
    (evil-define-key 'normal grep-edit-mode-map "ZZ" #'grep-edit-save-changes)))

(provide 'my-completion-embark)
