;;; my-completion-consult.el --- Consult  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(use-package consult
  :demand t
  :init
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref
        register-preview-delay 0.5
        register-preview-function #'consult-register-format)
  :config
  (setq consult-narrow-key "<"
        consult-preview-key '(:debounce 0.3 any))
  (consult-customize consult-ripgrep consult-git-grep consult-grep
                     consult-recent-file consult-buffer
                     :preview-key '(:debounce 0.4 any))
  (global-set-key [remap switch-to-buffer] #'consult-buffer)
  (global-set-key [remap switch-to-buffer-other-window] #'consult-buffer-other-window)
  (global-set-key [remap yank-pop] #'consult-yank-pop)
  (global-set-key [remap goto-line] #'consult-goto-line)
  (global-set-key [remap bookmark-jump] #'consult-bookmark)
  ;; Search within the current project (works with project.el)
  (autoload 'consult-fd "consult" nil t))

(my/leader
  "bB" '(consult-buffer :wk "all buffers")
  "sm" '(consult-mark :wk "mark")
  "sk" '(consult-yank-pop :wk "kill ring")
  "sd" '(consult-flymake :wk "diagnostics")
  "sg" '(consult-git-grep :wk "git grep")
  "sb" '(consult-bookmark :wk "bookmark"))

(provide 'my-completion-consult)
