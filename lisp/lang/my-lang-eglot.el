;;; my-lang-eglot.el --- LSP via Eglot  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function general-define-key "general")

(declare-function eglot--guess-contact "eglot")

(use-package eglot
  :ensure nil
  :hook ((prog-mode . my/eglot-maybe-ensure))
  :custom
  (eglot-autoshutdown t)                 ; kill server with last buffer
  (eglot-sync-connect nil)               ; don't block on slow servers
  (eglot-extend-to-xref t)
  (eglot-events-buffer-config '(:size 0 :format full)) ; no event logging
  (eglot-code-action-indications '(eldoc-hint))
  :config
  (setq eldoc-echo-area-use-multiline-p 3)
  (fset #'jsonrpc--log-event #'ignore)

  ;; Add extra servers here, or in a separate lang file:
  ;; (add-to-list 'eglot-server-programs '(foo-mode . ("foo-lsp" "--stdio")))

  (defun my/eglot-maybe-ensure ()
    "Start Eglot shortly after the buffer is shown, so opening a file never blocks.
Skipped for elisp, large buffers and modes without a known server."
    (unless (or (derived-mode-p 'emacs-lisp-mode 'lisp-data-mode)
                (my/large-buffer-p))
      (let ((buf (current-buffer)))
        (run-with-idle-timer
         0.4 nil
         (lambda ()
           (when (and (buffer-live-p buf)
                      (not (with-current-buffer buf (bound-and-true-p eglot--managed-mode)))
                      (with-current-buffer buf (ignore-errors (eglot--guess-contact))))
             (with-current-buffer buf (eglot-ensure)))))))))

(defun my/eldoc-show ()
  "Show signature/docs plus line diagnostics in a normal, focused window.
No popup: the *eldoc* buffer opens at the bottom and is selected, so you can
scroll it with the usual keys and close it with `q'."
  (interactive)
  (let ((origin (current-buffer)))
    (cl-labels ((show (&rest _)
                  (remove-hook 'eldoc-display-functions #'show t)
                  (when (buffer-live-p eldoc--doc-buffer)
                    (when-let* ((win (display-buffer
                                      (eldoc-doc-buffer)
                                      '((display-buffer-reuse-window display-buffer-at-bottom)
                                        (window-height . fit-window-to-buffer)))))
                      (select-window win)))))
      (with-current-buffer origin
        (add-hook 'eldoc-display-functions #'show 90 t)
        (eldoc-print-current-symbol-info t)))))

(my/leader
  "ca" '(eglot-code-actions :wk "code action")
  "cr" '(eglot-rename :wk "rename")
  "cf" '(eglot-format :wk "format region/buffer")
  "cd" '(xref-find-definitions :wk "definition")
  "cD" '(xref-find-references :wk "references")
  "ci" '(eglot-find-implementation :wk "implementation")
  "ct" '(eglot-find-typeDefinition :wk "type definition")
  "cs" '(consult-eglot-symbols :wk "workspace symbols")
  "cR" '(eglot-reconnect :wk "reconnect")
  "cx" '(eglot-shutdown :wk "shutdown server")
  "ch" '(eldoc :wk "doc (echo area)")
  "ck" '(my/eldoc-show :wk "doc window"))

(general-define-key :states 'normal
                    "K" 'my/eldoc-show              ; signature/docs + line diagnostics
                    "gd" 'xref-find-definitions
                    "gD" 'eglot-find-declaration)

;; Neovim-style LSP actions (nvim 0.11 defaults): gr prefix
(general-define-key :states '(normal visual)
                    "gra" 'eglot-code-actions
                    "grn" 'eglot-rename
                    "grr" 'xref-find-references
                    "gri" 'eglot-find-implementation
                    "grt" 'eglot-find-typeDefinition
                    "gO"  'consult-imenu)

(use-package consult-eglot
  :after (consult eglot))

(provide 'my-lang-eglot)
