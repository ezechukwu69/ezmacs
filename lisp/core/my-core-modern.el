;;; my-core-modern.el --- Emacs 31 built-ins used in place of packages  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Trust our own config for Flymake's elisp byte-compiler / macro expansion
;; (Emacs 30+ otherwise says "untrusted content" and disables the checks).
(add-to-list 'trusted-content (file-name-as-directory my/emacs-dir))

;; Built-in EditorConfig (replaces the `editorconfig' package)
(editorconfig-mode 1)

;; C-w / M-w with no region act on the word/line at point
(setopt kill-region-dwim 'emacs-word)

;; Soft-wrapped prose gets proper indentation of continuation lines
(add-hook 'text-mode-hook #'visual-wrap-prefix-mode)
(add-hook 'org-mode-hook #'visual-wrap-prefix-mode)

;; Code folding without extra packages: za/zo/zc come from evil, hs does the work
(add-hook 'prog-mode-hook #'hs-minor-mode)

;; Search
(setopt isearch-lazy-count t
        lazy-count-prefix-format "(%s/%s) "
        isearch-allow-scroll 'unlimited)

;; Version control / project hints in the mode line
(setopt vc-use-incoming-outgoing-prefixes t
        project-mode-line t)

;; Tab bar: equal-width tabs
(setopt tab-bar-auto-width t)

;; Flymake's elisp byte-compiler runs `emacs -Q` and by default only sees "./".
;; Give it the real `load-path' (packages + lisp/) so `require's and use-package
;; resolve and it stops reporting unknown functions/macros.
(add-hook 'after-init-hook
          (lambda () (setq elisp-flymake-byte-compile-load-path
                           (cons "./" (copy-sequence load-path)))))

(provide 'my-core-modern)
