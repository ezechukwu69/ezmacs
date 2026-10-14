;;; my-org-capture.el --- Capture templates  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")

(defvar my/org-dir)                          ; defined in my-org-core.el

(use-package org-capture
  :ensure nil
  :after org
  :custom
  (org-capture-templates
   `(("t" "Todo" entry (file+headline ,(expand-file-name "todo.org" my/org-dir) "Inbox")
      "* TODO %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n%i\n" :empty-lines 1)
     ("c" "Todo with code link" entry (file+headline ,(expand-file-name "todo.org" my/org-dir) "Inbox")
      "* TODO %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n\n%a\n" :empty-lines 1)
     ("n" "Note" entry (file+headline ,(expand-file-name "notes.org" my/org-dir) "Inbox")
      "* %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n%i\n" :empty-lines 1)
     ("j" "Journal" entry (file+olp+datetree ,(expand-file-name "journal.org" my/org-dir))
      "* %<%H:%M> %?\n" :tree-type week))))

(my/leader
  "X"  '(org-capture :wk "capture")
  "oc" '(org-capture :wk "capture"))

(provide 'my-org-capture)
