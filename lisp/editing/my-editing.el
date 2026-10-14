;;; my-editing.el --- Editing category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-editing-undo
        my-editing-pairs
        my-editing-navigation
        my-editing-whitespace
        my-editing-snippets))
(provide 'my-editing)
