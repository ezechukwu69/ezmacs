;;; my-workspace-ibuffer.el --- ibuffer scoped to the current workspace  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
(declare-function ibuffer-project-generate-filter-groups "ibuffer-project")

;; `define-ibuffer-filter' is a macro, so it needs ibuffer at compile time only;
;; at run time the libraries load when ibuffer is first used.
(eval-when-compile (require 'ibuffer) (require 'ibuf-ext))

(setq ibuffer-show-empty-filter-groups nil)

;; Filter: only buffers that belong to the current tabspace.
(with-eval-after-load 'ibuf-ext
  (define-ibuffer-filter workspace
      "Limit to buffers of the current workspace (tabspaces)."
    (:description "workspace" :reader nil)
    (tabspaces--local-buffer-p buf)))

(defun my/ibuffer--fresh ()
  "Drop the old *Ibuffer* so filters from the previous view do not linger."
  (when-let* ((buf (get-buffer "*Ibuffer*")))
    (kill-buffer buf)))

(defun my/ibuffer-workspace ()
  "Open ibuffer showing only the current workspace's buffers."
  (interactive)
  (require 'ibuf-ext)
  (my/ibuffer--fresh)
  (ibuffer nil "*Ibuffer*" '((workspace))))

(defun my/ibuffer-all ()
  "Open ibuffer with every buffer of every workspace, grouped by project."
  (interactive)
  (require 'ibuf-ext)
  (my/ibuffer--fresh)
  (ibuffer nil "*Ibuffer*"))

;; Group buffers by project (useful in the "all buffers" view).
(use-package ibuffer-project
  :hook (ibuffer . my/ibuffer-project-groups)
  :config
  (defun my/ibuffer-project-groups ()
    (setq ibuffer-filter-groups (ibuffer-project-generate-filter-groups))
    (unless (eq ibuffer-sorting-mode 'project-file-relative)
      (ibuffer-do-sort-by-project-file-relative))))

;; C-x C-b, `ibuffer' and SPC b i all open the workspace-scoped list.
(global-set-key [remap list-buffers] #'my/ibuffer-workspace)
(global-set-key [remap ibuffer] #'my/ibuffer-workspace)

(my/leader
  "bi" '(my/ibuffer-workspace :wk "ibuffer (workspace)")
  "bI" '(my/ibuffer-all :wk "ibuffer (all)"))

(provide 'my-workspace-ibuffer)
