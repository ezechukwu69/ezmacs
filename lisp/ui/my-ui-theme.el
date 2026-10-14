;;; my-ui-theme.el --- Theme  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package doom-themes
  :demand t
  :config
  (setq doom-themes-enable-bold t
        doom-themes-enable-italic t)
  (load-theme 'doom-tokyo-night t)
  (doom-themes-org-config))

(provide 'my-ui-theme)
