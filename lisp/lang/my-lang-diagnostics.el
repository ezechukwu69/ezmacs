;;; my-lang-diagnostics.el --- Buffer and workspace diagnostics (Flymake/Eglot)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/leader "my-keys-leader")
;;
;; Eglot reports through Flymake.  Diagnostics the server pushes for files that
;; are not open are kept in `flymake-list-only-diagnostics', so the project list
;; covers the whole workspace as far as the server reports it.

;; Ask Pyright to analyse the whole workspace, not only open files.
;; Other servers (rust-analyzer, dart, gopls, ...) are workspace-wide by default.
(defcustom my/eglot-workspace-wide-diagnostics t
  "When non-nil, request project-wide analysis from servers that need opting in."
  :type 'boolean :group 'eglot)

(with-eval-after-load 'eglot
  (when my/eglot-workspace-wide-diagnostics
    (setq-default eglot-workspace-configuration
                  '(:python (:analysis (:diagnosticMode "workspace"))))))

(defun my/diagnostics-on-line ()
  "Diagnostics overlapping the current line, sorted by column."
  (sort (flymake-diagnostics (line-beginning-position) (line-end-position))
        (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b)))))

(defun my/format-diagnostic (d)
  "Format Flymake diagnostic D as \"[type] line:col text\"."
  (let* ((type (flymake-diagnostic-type d))
         (face (pcase type (:error 'error) (:warning 'warning) (_ 'success)))
         (label (pcase type (:error "error") (:warning "warning") (_ "note")))
         (beg (flymake-diagnostic-beg d)))
    (format "%s %s%s"
            (propertize (format "[%s]" label) 'face face)
            (propertize (format "%d:%d " (line-number-at-pos beg)
                                (save-excursion (goto-char beg) (1+ (current-column))))
                        'face 'shadow)
            (flymake-diagnostic-text d))))

(defun my/eldoc-drop-diagnostics ()
  "Keep diagnostics out of eldoc (echo area and `K'); `SPC e k' shows them."
  (setq-local eldoc-documentation-functions
              (remq #'flymake-eldoc-function eldoc-documentation-functions)))

(add-hook 'eglot-managed-mode-hook #'my/eldoc-drop-diagnostics 90)
(add-hook 'flymake-mode-hook #'my/eldoc-drop-diagnostics 90)

(defun my/show-line-diagnostics ()
  "Show every diagnostic on the current line in the minibuffer."
  (interactive)
  (if-let* ((diags (my/diagnostics-on-line)))
      (let ((max-mini-window-height 0.5)
            (message-log-max nil))
        (message "%s" (mapconcat #'my/format-diagnostic diags "\n")))
    (message "No diagnostics on this line")))

(defun my/diagnostics-buffer ()
  "List diagnostics of the current buffer."
  (interactive)
  (flymake-show-buffer-diagnostics))

(defun my/diagnostics-workspace ()
  "List diagnostics of the whole project/workspace."
  (interactive)
  (flymake-show-project-diagnostics))

(defun my/diagnostics-summary ()
  "Echo error/warning counts for the current buffer and the project."
  (interactive)
  (let ((count (lambda (diags type)
                 (cl-count-if (lambda (d) (eq (flymake-diagnostic-type d) type)) diags))))
    (let ((buf (flymake-diagnostics)))
      (message "Buffer: %d errors, %d warnings"
               (funcall count buf :error) (funcall count buf :warning)))))

(my/leader
  "eb" '(my/diagnostics-buffer :wk "buffer list")
  "ew" '(my/diagnostics-workspace :wk "workspace list")
  "ec" '(consult-flymake :wk "buffer (consult)")
  "eC" '((lambda () (interactive) (consult-flymake t)) :wk "workspace (consult)")
  "es" '(my/diagnostics-summary :wk "summary")
  "ek" '(my/show-line-diagnostics :wk "line diagnostics")
  "ea" '(eglot-code-actions :wk "fix at point")
  "ex" '(flymake-start :wk "recheck")
  "et" '(flymake-mode :wk "toggle"))

(provide 'my-lang-diagnostics)
