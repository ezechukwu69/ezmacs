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

;;; Symbols ------------------------------------------------------------------

(declare-function consult-imenu "consult-imenu")
(declare-function consult-imenu-multi "consult-imenu")
(declare-function consult-eglot-symbols "consult-eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-server-capable "eglot")
(defvar imenu-auto-rescan)
(defvar imenu-auto-rescan-maxout)
(defvar imenu--index-alist)

(defun my/symbols-buffer ()
  "Browse the symbols of this buffer with Consult, with live preview.
Under Eglot these are the language server's document symbols, otherwise the
mode's imenu.  The index is rebuilt first: imenu stops rescanning buffers
bigger than `imenu-auto-rescan-maxout' (60KB), which made symbols go missing."
  (interactive)
  (require 'imenu)
  (let ((imenu-auto-rescan t)
        (imenu-auto-rescan-maxout (max imenu-auto-rescan-maxout (* 2 (buffer-size)))))
    (setq imenu--index-alist nil)
    (consult-imenu)))

(defun my/symbols-workspace ()
  "Browse the symbols of the whole workspace with Consult.
With an Eglot server that supports it this searches every file of the project
as you type; otherwise it lists the imenu of every open buffer of the project."
  (interactive)
  (if (and (bound-and-true-p eglot--managed-mode)
           (eglot-current-server)
           (eglot-server-capable :workspaceSymbolProvider))
      (consult-eglot-symbols)
    (consult-imenu-multi)))

(my/leader
  "ca" '(eglot-code-actions :wk "code action")
  "cr" '(eglot-rename :wk "rename")
  "cf" '(eglot-format :wk "format region/buffer")
  "cd" '(xref-find-definitions :wk "definition")
  "cD" '(xref-find-references :wk "references")
  "ci" '(eglot-find-implementation :wk "implementation")
  "ct" '(eglot-find-typeDefinition :wk "type definition")
  "cs" '(my/symbols-workspace :wk "workspace symbols")
  "cS" '(my/symbols-buffer :wk "buffer symbols")
  "cR" '(eglot-reconnect :wk "reconnect")
  "cx" '(eglot-shutdown :wk "shutdown server")
  "ch" '(eldoc :wk "doc (echo area)")
  "ck" '(my/eldoc-show :wk "doc window"))

;; Evil key and Emacs-mode twin in one place (`:g' = Evil g.., Emacs C-c g ..).
;; gd gD gr* g0 gO K and their Emacs-mode keys: lisp/keys/my-keys-table.el

(use-package consult-eglot
  :after (consult eglot))

(provide 'my-lang-eglot)
