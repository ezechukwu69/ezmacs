;;; my-lang.el --- Language / IDE category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-lang-eglot
        my-lang-treesit
        my-lang-flymake
        my-lang-diagnostics
        my-lang-format
        my-lang-vite-plus
        my-lang-dape
        my-lang-envrc
        my-lang-modes
        my-lang-dart
        my-lang-flutter))
(provide 'my-lang)
