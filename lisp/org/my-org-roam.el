;;; my-org-roam.el --- Zettelkasten notes  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(defvar my/org-dir)                          ; defined in my-org-core.el

(defconst my/org-roam-dir (expand-file-name "roam/" my/org-dir))
(make-directory my/org-roam-dir t)

(use-package org-roam
  :defer t                              ; loading + the db sync on enable take ~1s: on demand only
  :custom
  (org-roam-directory my/org-roam-dir)
  (org-roam-completion-everywhere t)
  (org-roam-db-location (expand-file-name "org-roam.db" no-littering-var-directory))
  (org-roam-capture-templates
   '(("d" "default" plain "%?"
      :target (file+head "%<%Y%m%d%H%M%S>-${slug}.org" "#+title: ${title}\n")
      :unnarrowed t)))
  (org-roam-dailies-directory "daily/")
  (org-roam-dailies-capture-templates
   '(("d" "default" entry "* %<%H:%M> %?"
      :target (file+head "%<%Y-%m-%d>.org" "#+title: %<%Y-%m-%d>\n"))))
  :config
  (org-roam-db-autosync-mode 1))

;; Opening a note inside the roam directory loads org-roam (and so its autosync),
;; so edits there still reach the database; the leader keys below autoload it too.
(defun my/org-roam-maybe-load ()
  (when (and buffer-file-name
             (string-prefix-p (expand-file-name my/org-roam-dir)
                              (expand-file-name buffer-file-name)))
    (require 'org-roam)))
(add-hook 'find-file-hook #'my/org-roam-maybe-load)

(my/leader
  "nf" '(org-roam-node-find :wk "find note")
  "ni" '(org-roam-node-insert :wk "insert link")
  "nc" '(org-roam-capture :wk "capture")
  "nl" '(org-roam-buffer-toggle :wk "backlinks")
  "nt" '(org-roam-tag-add :wk "add tag")
  "na" '(org-roam-alias-add :wk "add alias")
  "nj" '(org-roam-dailies-capture-today :wk "journal today")
  "nd" '(org-roam-dailies-goto-today :wk "goto today")
  "nD" '(org-roam-dailies-goto-date :wk "goto date")
  "ns" '(org-roam-db-sync :wk "sync db"))

(provide 'my-org-roam)
