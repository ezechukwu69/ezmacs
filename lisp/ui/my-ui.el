;;; my-ui.el --- UI category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-ui-prefs
        my-ui-theme
        my-ui-font
        my-ui-icons
        my-ui-modeline
        my-ui-highlights))
(provide 'my-ui)
