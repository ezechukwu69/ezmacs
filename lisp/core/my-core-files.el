;;; my-core-files.el --- Backups, autosave, lockfiles  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Backups (foo.el~, foo.el.~1~) and auto-saves (#foo.el#) go to
;; `no-littering-var-directory' instead of sitting next to the edited file.
;; no-littering only does this when asked, because backups may hold secrets.
(no-littering-theme-backups)
(setq make-backup-files t
      backup-by-copying t
      version-control t
      delete-old-versions t
      kept-new-versions 6
      kept-old-versions 2
      create-lockfiles nil
      auto-save-default t
      auto-save-visited-interval 30)

(auto-save-visited-mode 1)       ; real saves, not just #files#

(provide 'my-core-files)
