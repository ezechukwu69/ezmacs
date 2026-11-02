;;; my-lang-modes.el --- Major modes without built-in support  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;; Built-in tree-sitter modes (js, ts, python, go, rust, json, yaml, css,
;; dockerfile, ...) are enabled by `treesit-enabled-modes' (my-lang-treesit.el).  Add language-specific packages below or in their own file.

;; Markdown lives in my-lang-markdown.el.

(use-package web-mode    :mode ("\\.html?\\'" "\\.vue\\'" "\\.svelte\\'"))

(provide 'my-lang-modes)
