;;; my-ui-modeline.el --- Modeline  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package doom-modeline
  :demand t
  :config
  (setq doom-modeline-height 28
        doom-modeline-buffer-file-name-style 'relative-from-project
        doom-modeline-project-name t
        doom-modeline-workspace-name nil ; tab-bar shows workspaces
        doom-modeline-minor-modes nil)
  (doom-modeline-mode 1))

(provide 'my-ui-modeline)
