;;; my-tools-server.el --- Emacs server (for emacsclient / org-protocol)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'server)
(unless (server-running-p) (server-start))

(provide 'my-tools-server)
