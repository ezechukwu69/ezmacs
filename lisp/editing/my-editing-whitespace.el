;;; my-editing-whitespace.el --- Whitespace hygiene  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package ws-butler
  :hook ((prog-mode text-mode) . ws-butler-mode)) ; trim only lines you touched

;; EditorConfig is built into Emacs 31 (see core/my-core-modern.el).

(provide 'my-editing-whitespace)
