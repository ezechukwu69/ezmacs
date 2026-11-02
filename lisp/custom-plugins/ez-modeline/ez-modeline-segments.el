;;; ez-modeline-segments.el --- Built-in segments for ez-modeline -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; Left:   state      the Evil state as a small coloured tag (selected window only)
;;         buffer     file icon, project-relative path, name, unsaved / read-only
;;         vc         the branch, in the warning colour when the file is edited
;;         selection  how much is selected
;;         macro      a recording marker
;; Right:  process    `mode-line-process' (compilation, shells, magit ...)
;;         misc       `mode-line-misc-info' and `global-mode-string' (org-clock,
;;                    display-time, battery, which-function ...) minus the
;;                    entries in `ez-modeline-misc-exclude'
;;         checks     flymake error / warning / note counts
;;         lsp        an eglot server is managing this buffer
;;         env        direnv (envrc) state
;;         mode       the major mode
;;         position   line:column and how far down the buffer
;;
;; Writing your own is one form (it then needs adding to `ez-modeline-left' or
;; `ez-modeline-right'):
;;   (ez-modeline-define-segment agents "Number of agents."
;;     (when (> (my/agent-count) 0) (format "%d agents" (my/agent-count))))

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'ez-modeline)

(declare-function nerd-icons-mdicon "nerd-icons")
(declare-function nerd-icons-icon-for-buffer "nerd-icons")
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-show-buffer-diagnostics "flymake")
(declare-function eglot-current-server "eglot")
(declare-function eglot-events-buffer "eglot")
(defvar vc-mode)
(defvar evil-state)
(defvar evil-local-mode)
(defvar flymake-mode)
(defvar envrc-mode)
(defvar envrc--status)

;;;; Helpers

(defun ez-modeline-icon (name fallback &optional face)
  "The nerd-icons mdicon NAME, or the plain string FALLBACK; both use FACE."
  (if (and ez-modeline-icons (require 'nerd-icons nil t) (fboundp 'nerd-icons-mdicon))
      (or (ignore-errors (nerd-icons-mdicon name :face face))
          (propertize fallback 'face face))
    (propertize fallback 'face face)))

(defun ez-modeline--click-map (command)
  "A keymap running COMMAND on a mouse click in either the mode or header line."
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] command)
    (define-key m [header-line mouse-1] command)
    m))

(defun ez-modeline-clickable (string command help)
  "STRING that runs COMMAND when clicked and shows HELP on hover."
  (propertize string 'mouse-face 'mode-line-highlight 'help-echo help
              'local-map (ez-modeline--click-map command)))

;;;; State

(defconst ez-modeline--state-labels
  '((normal . "N") (insert . "I") (visual . "V") (replace . "R")
    (emacs . "E") (motion . "M") (operator . "O"))
  "One-letter tags for Evil states.")

(ez-modeline-define-segment state
    "The Evil state, as a coloured tag; only in the selected window."
  (when (and ez-modeline--active (bound-and-true-p evil-local-mode)
             (bound-and-true-p evil-state))
    (let* ((label (or (alist-get evil-state ez-modeline--state-labels)
                      (upcase (substring (symbol-name evil-state) 0 1))))
           (face (intern-soft (format "ez-modeline-state-%s" evil-state))))
      (propertize (format " %s " label)
                  'face (if (and face (facep face)) face 'ez-modeline-state-normal)
                  'help-echo (format "Evil %s state" evil-state)))))

;;;; Buffer

(defvar-local ez-modeline--id nil
  "Cache (KEY . (DIR . NAME)) for the buffer segment.
See `ez-modeline--buffer-parts'.")

(defun ez-modeline--compute-parts ()
  "(DIR . NAME) for the current buffer: the path below its project, and the name."
  (cond
   ((and buffer-file-name (not (file-remote-p buffer-file-name)))
    (let* ((root (ignore-errors (when-let* ((pr (project-current nil))) (project-root pr))))
           (rel (if (and root (file-in-directory-p buffer-file-name root))
                    (file-relative-name buffer-file-name root)
                  (abbreviate-file-name buffer-file-name))))
      (cons (file-name-directory rel) (file-name-nondirectory rel))))
   (buffer-file-name
    (cons (concat (or (file-remote-p buffer-file-name 'host) "remote") ":")
          (file-name-nondirectory buffer-file-name)))
   (t (cons nil (buffer-name)))))

(defun ez-modeline--buffer-parts ()
  "(DIR . NAME), recomputed only when the file, directory or name changes."
  (let ((key (list buffer-file-name default-directory (buffer-name))))
    (if (equal (car ez-modeline--id) key)
        (cdr ez-modeline--id)
      (let ((parts (ez-modeline--compute-parts)))
        (setq ez-modeline--id (cons key parts))
        parts))))

(defun ez-modeline--shorten-dir (dir max)
  "DIR (like \"src/ui/\") cut to at most MAX columns by dropping leading folders."
  (cond ((or (null dir) (<= (string-width dir) max)) dir)
        ((<= max 3) nil)
        (t (let ((parts (split-string dir "/" t)))
             (while (and (cdr parts)
                         (> (string-width (concat "…/" (string-join parts "/") "/")) max))
               (setq parts (cdr parts)))
             (truncate-string-to-width (concat "…/" (string-join parts "/") "/") max nil nil "…")))))

(ez-modeline-define-segment buffer
    "File icon, project folder, name, and unsaved / read-only / narrowed marks."
  (let* ((parts (ez-modeline--buffer-parts))
         (limit (min 44 (max 14 (- (window-width) 62))))
         (name (truncate-string-to-width (cdr parts) limit nil nil "…"))
         (dir (ez-modeline--shorten-dir (car parts) (max 0 (- limit (string-width name) 1))))
         (icon (when (and ez-modeline-icons (require 'nerd-icons nil t)
                          (fboundp 'nerd-icons-icon-for-buffer))
                 (ignore-errors (nerd-icons-icon-for-buffer)))))
    (concat (when (and (stringp icon) (not (string-empty-p icon))) (concat icon " "))
            (when dir (propertize dir 'face 'ez-modeline-dim))
            (propertize name 'face 'ez-modeline-buffer)
            (when (and buffer-file-name (buffer-modified-p))
              (propertize " ●" 'face 'ez-modeline-warn 'help-echo "Unsaved changes"))
            (when (and buffer-file-name buffer-read-only)
              (concat " " (ez-modeline-icon "nf-md-lock_outline" "RO" 'ez-modeline-dim)))
            (when (buffer-narrowed-p)
              (propertize " narrowed" 'face 'ez-modeline-dim)))))

;;;; Version control, selection, macro

(ez-modeline-define-segment vc
    "The VC branch of the file; warning colour when the file has edits."
  (when (and vc-mode buffer-file-name)
    (let* ((raw (substring-no-properties vc-mode)))
      (when (string-match "\\`[ ]*[^-:@!?]+\\([-:@!?]\\)\\(.*\\)\\'" raw)
        (let* ((state (match-string 1 raw))
               (branch (truncate-string-to-width (match-string 2 raw) 24 nil nil "…"))
               (edited (member state '(":" "@" "!"))))
          (concat (ez-modeline-icon "nf-md-source_branch" "⎇" (if edited 'ez-modeline-warn 'ez-modeline-dim))
                  " "
                  (propertize branch 'face (if edited 'ez-modeline-warn 'ez-modeline-accent)
                              'help-echo raw)))))))

(ez-modeline-define-segment selection
    "How much text is selected."
  (when (and ez-modeline--active (use-region-p))
    (let* ((beg (region-beginning)) (end (region-end))
           (lines (count-lines beg end)))
      (propertize (if (> lines 1)
                      (format "%d lines · %d chars" lines (- end beg))
                    (format "%d chars" (- end beg)))
                  'face 'ez-modeline-accent))))

(ez-modeline-define-segment macro
    "A marker while a keyboard macro is being recorded."
  (when defining-kbd-macro
    (propertize "● REC" 'face 'ez-modeline-bad 'help-echo "Recording a keyboard macro")))

;;;; Other packages: process and misc info

(ez-modeline-define-segment process
    "`mode-line-process': what compilation, shells, magit and friends report."
  (let ((s (string-trim (format-mode-line mode-line-process))))
    (unless (string-empty-p s) (propertize s 'face 'ez-modeline-accent))))

(ez-modeline-define-segment misc
    "`mode-line-misc-info' (it holds `global-mode-string'), minus excluded entries."
  (let* ((items (cl-remove-if (lambda (e) (and (consp e) (memq (car e) ez-modeline-misc-exclude)))
                              mode-line-misc-info))
         (s (string-trim (replace-regexp-in-string "[ \t]+" " " (format-mode-line items)))))
    (unless (string-empty-p s) s)))

;;;; Checks, LSP, environment

(defun ez-modeline--diagnostic-counts ()
  "(ERRORS WARNINGS NOTES) of flymake's diagnostics in the current buffer."
  (let ((e 0) (w 0) (n 0))
    (dolist (d (flymake-diagnostics))
      (let ((type (symbol-name (flymake-diagnostic-type d))))
        (cond ((string-match-p "error" type) (cl-incf e))
              ((string-match-p "warn" type) (cl-incf w))
              (t (cl-incf n)))))
    (list e w n)))

(ez-modeline-define-segment checks
    "Flymake error, warning and note counts; a tick when everything is clean."
  (when (and (bound-and-true-p flymake-mode) (featurep 'flymake))
    (pcase-let* ((`(,e ,w ,n) (ez-modeline--diagnostic-counts))
                 (parts (delq nil
                              (list (and (> e 0) (propertize (format "✗ %d" e) 'face 'ez-modeline-bad))
                                    (and (> w 0) (propertize (format "▲ %d" w) 'face 'ez-modeline-warn))
                                    (and (> n 0) (propertize (format "● %d" n) 'face 'ez-modeline-accent)))))
                 (text (if parts
                           (string-join parts " ")
                         (propertize "✓" 'face 'ez-modeline-ok)))
                 (busy (and (ignore-errors (flymake-running-backends))
                            (propertize " …" 'face 'ez-modeline-dim))))
      (ez-modeline-clickable (concat text busy) #'flymake-show-buffer-diagnostics
                             (format "%d errors, %d warnings, %d notes - click for the list" e w n)))))

(ez-modeline-define-segment lsp
    "An icon when an Eglot server manages this buffer."
  (when (and (featurep 'eglot) (ignore-errors (eglot-current-server)))
    (ez-modeline-clickable
     (concat (ez-modeline-icon "nf-md-server_network" "LSP" 'ez-modeline-accent))
     #'eglot-events-buffer "Eglot is managing this buffer")))

(ez-modeline-define-segment env
    "direnv state, when envrc is on in this buffer."
  (when (and (bound-and-true-p envrc-mode) (boundp 'envrc--status))
    (pcase envrc--status
      ('on (propertize "env" 'face 'ez-modeline-ok 'help-echo "direnv environment loaded"))
      ('error (propertize "env ✗" 'face 'ez-modeline-bad 'help-echo "direnv failed"))
      (_ nil))))

;;;; Mode and position

(ez-modeline-define-segment mode
    "The major mode."
  (let ((s (string-trim (format-mode-line mode-name))))
    (unless (string-empty-p s) (propertize s 'face 'ez-modeline-dim 'help-echo (format "%s" major-mode)))))

(ez-modeline-define-segment position
    "Line and column, then how far down the buffer the point is."
  (concat (format-mode-line "%l:%c")
          "  " (propertize (format-mode-line "%p") 'face 'ez-modeline-dim)))

(provide 'ez-modeline-segments)
;;; ez-modeline-segments.el ends here
