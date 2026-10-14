;;; my-completion-cape.el --- Extra completion-at-point backends  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package cape
  :demand t
  :init
  ;; Global fallbacks; mode-local capfs (eglot, elisp, ...) take precedence.
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  :config
  ;; Eglot's capf can be slow/erratic; cache it and make it non-exclusive.
  (advice-add 'eglot-completion-at-point :around #'cape-wrap-buster)
  (advice-add 'eglot-completion-at-point :around #'cape-wrap-nonexclusive)
  (global-set-key (kbd "C-c p") cape-prefix-map))

(provide 'my-completion-cape)
