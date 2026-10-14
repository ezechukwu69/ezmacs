;;; my-org.el --- Org category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-org-core
        my-org-agenda
        my-org-agenda-ui
        my-org-capture
        my-org-babel
        my-org-appearance
        my-org-evil
        my-org-roam))
(provide 'my-org)
