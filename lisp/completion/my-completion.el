;;; my-completion.el --- Completion category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;; Minibuffer: vertico + orderless + marginalia + consult + embark
;; In-buffer:  corfu + cape
(mapc #'require
      '(my-completion-vertico
        my-completion-orderless
        my-completion-marginalia
        my-completion-consult
        my-completion-embark
        my-completion-corfu
        my-completion-cape))
(provide 'my-completion)
