;;; my-tools-help.el --- Better help buffers  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(use-package helpful
  :bind (([remap describe-function] . helpful-callable)
         ([remap describe-variable] . helpful-variable)
         ([remap describe-key]      . helpful-key)
         ([remap describe-command]  . helpful-command)
         ([remap describe-symbol]   . helpful-symbol)))

(provide 'my-tools-help)
