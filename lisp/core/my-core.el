;;; my-core.el --- Core category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-core-packages
        my-core-defaults
        my-core-files
        my-core-performance
        my-core-modern
        my-core-userlisp
        my-core-environment))
(provide 'my-core)
