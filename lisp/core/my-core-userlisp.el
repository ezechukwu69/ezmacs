;;; my-core-userlisp.el --- Compile and index lisp/ (Emacs 31 user lisp)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; At startup Emacs only puts `user-lisp-directory' on `load-path'
;; (`user-lisp-auto-scrape' is nil in early-init.el).  Once Emacs is idle after
;; startup we call `prepare-user-lisp', which, for files whose timestamps
;; changed:
;;   - byte-compiles them (and native-compiles them in the background),
;;   - scrapes ;;;###autoload cookies into lisp/.user-lisp-autoloads.el.
;; Doing it here, not before init, matters: our modules use macros (`my/leader',
;; `use-package') and packages that only exist after init has run.
;; `load-prefer-newer' (early-init.el) makes Emacs ignore stale .elc files.

(defun my/prepare-lisp (&optional force)
  "Compile and index `user-lisp-directory'.  With FORCE, rebuild everything."
  (interactive "P")
  (when (and (boundp 'user-lisp-directory) (file-directory-p user-lisp-directory))
    (let ((inhibit-message (not (called-interactively-p 'any))))
      (prepare-user-lisp nil nil force))))

(add-hook 'emacs-startup-hook
          (lambda () (run-with-idle-timer 3 nil #'my/prepare-lisp)))

(provide 'my-core-userlisp)
