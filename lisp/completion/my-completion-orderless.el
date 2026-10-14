;;; my-completion-orderless.el --- Matching style  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package orderless
  :demand t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion basic))
                                   (eglot (styles orderless))
                                   (eglot-capf (styles orderless)))))

(provide 'my-completion-orderless)
