;;; my-workspace-consult.el --- Show only the current workspace's buffers in consult-buffer  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(with-eval-after-load 'consult
  ;; Hide the global buffer source, add a workspace-local one.
  (consult-customize consult-source-buffer :hidden t :default nil :narrow ?b)

  (defvar my/consult--source-workspace
    (list :name     "Workspace Buffers"
          :narrow   ?w
          :history  'buffer-name-history
          :category 'buffer
          :state    #'consult--buffer-state
          :default  t
          :items    (lambda ()
                      (consult--buffer-query
                       :predicate #'tabspaces--local-buffer-p
                       :sort 'visibility
                       :as #'buffer-name)))
    "Consult source listing buffers of the current tabspace.")

  (add-to-list 'consult-buffer-sources 'my/consult--source-workspace)
  ;; Narrow with "b " in consult-buffer to see every buffer in every workspace.
  )

(provide 'my-workspace-consult)
