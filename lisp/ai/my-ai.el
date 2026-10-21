;;; my-ai.el --- AI category  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
(mapc #'require
      '(my-ai-agent-shell my-ai-agents))
(provide 'my-ai)
