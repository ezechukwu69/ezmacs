;;; my-lang-treesit.el --- Tree-sitter (built into Emacs 31+)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; Emacs 31 remaps classic modes to their -ts-mode and can install grammars on
;; demand itself, so the treesit-auto package is no longer needed.
;; (`treesit-enabled-modes' only probes the grammar of the file being opened.)

(require 'treesit)
(defvar my/data-dir)                         ; defined in early-init.el

(defconst my/treesit-dir (expand-file-name "tree-sitter/" my/data-dir)
  "Where compiled grammars are stored (outside ~/.emacs.d).")
(make-directory my/treesit-dir t)

;; setopt, not setq: `treesit-enabled-modes' has a setter that fills `major-mode-remap-alist'.
(setopt treesit-extra-load-path (list my/treesit-dir) ; first writable dir = install target
        treesit-font-lock-level 3                     ; 4 is noticeably slower on big files
        treesit-enabled-modes t                       ; use every available -ts-mode
        treesit-auto-install-grammar 'ask)            ; offer to install a missing grammar

;; The interactive "Install to (default: ...)" prompt takes its default from this
;; history; seed it with our directory.
(setq treesit--install-language-grammar-out-dir-history (list my/treesit-dir))

;; `M-x treesit-install-language-grammar' defaults to ~/.emacs.d/tree-sitter and
;; ignores `treesit-extra-load-path'; make it use our directory instead.
(advice-add 'treesit-install-language-grammar :filter-args
            (lambda (args)
              (let ((lang (car args)) (out-dir (cadr args)))
                (cl-list* lang (or out-dir my/treesit-dir) (cddr args)))))

(defun my/treesit-register-sources ()
  "Make every built-in -ts-mode register its grammar source.
Each -ts-mode adds its recipe (URL and matching revision) to
`treesit-language-source-alist' only when loaded, so until then
`treesit-install-language-grammar' offers just the languages already seen."
  (dolist (mode (seq-uniq (mapcar #'cdr treesit-major-mode-remap-alist)))
    (ignore-errors (autoload-do-load (symbol-function mode) mode))))

;; Do it once Emacs is idle, so the completion list is complete without
;; slowing startup.
(add-hook 'emacs-startup-hook
          (lambda () (run-with-idle-timer 1 nil #'my/treesit-register-sources)))

(defun my/treesit-install-all ()
  "Install every missing grammar that a built-in -ts-mode knows a source for."
  (interactive)
  (my/treesit-register-sources)
  (let ((treesit-auto-install-grammar 'always))
    (dolist (lang (mapcar #'car treesit-language-source-alist))
      (unless (treesit-language-available-p lang)
        (condition-case err
            (treesit-ensure-installed lang)
          (error (message "Grammar %s failed: %s" lang (error-message-string err))))))))

(my/leader "cG" '(my/treesit-install-all :wk "install grammars"))

(provide 'my-lang-treesit)
