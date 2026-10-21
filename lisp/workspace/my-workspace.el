;;; my-workspace.el --- Workspace category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;; One workspace (tab) per project; each workspace only sees its own buffers.
(mapc #'require
      '(my-workspace-project
        my-workspace-tabspaces
        my-workspace-start
        my-workspace-consult
        my-workspace-ibuffer
        my-workspace-popups))
(provide 'my-workspace)
