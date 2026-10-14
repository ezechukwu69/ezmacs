;;; my-vc.el --- Version control category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-vc-magit
        my-vc-diff-hl))
(provide 'my-vc)
