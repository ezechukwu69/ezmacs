;;; my-lang-format.el --- Formatting  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

;; Format on save.  Apheleia runs the external formatter that fits the mode
;; (prettier, black/ruff, gofmt, rustfmt, dart format, ...) without moving point
;; or blocking.  Formatter binaries must be on PATH; see `apheleia-mode-alist'.
;; Modes Apheleia has no formatter for fall back to the LSP server's formatting.
(use-package apheleia
  :demand t
  :config
  (apheleia-global-mode 1)
  (my/leader "cF" '(apheleia-format-buffer :wk "format (apheleia)")))

(defcustom my/format-on-save t
  "Master switch for LSP-formatting fallback on save (Apheleia has its own mode)."
  :type 'boolean :group 'apheleia)

(defun my/eglot-format-fallback ()
  "Before save: LSP-format when Apheleia has no formatter for this buffer."
  (when (and my/format-on-save
             (bound-and-true-p eglot--managed-mode)
             (null (apheleia--get-formatters))
             (eglot-server-capable :documentFormattingProvider))
    (eglot-format-buffer)))

(add-hook 'eglot-managed-mode-hook
          (lambda () (add-hook 'before-save-hook #'my/eglot-format-fallback nil t)))

(defun my/format-on-save-toggle ()
  "Toggle automatic formatting on save (Apheleia and LSP fallback)."
  (interactive)
  (setq my/format-on-save (not my/format-on-save))
  (apheleia-global-mode (if my/format-on-save 1 -1))
  (message "Format on save %s" (if my/format-on-save "on" "off")))

(my/leader "tF" '(my/format-on-save-toggle :wk "format on save"))

(provide 'my-lang-format)
