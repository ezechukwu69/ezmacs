;;; my-lang-vite-plus.el --- Vite+ (vp) integration  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'cl-lib)
(require 'project)
(declare-function my/leader "my-keys-leader")

;; Everything here is inert outside a Vite+ project.  A project counts as Vite+
;; when the nearest package.json (or vite.config.*) mentions `vite-plus'.
;; In such a project:
;;   - Apheleia formats JS/TS/CSS/JSON with `vp fmt' (Oxfmt) instead of prettier.
;;   - Flymake lints saved JS/TS files with `vp lint' (Oxlint).
;;   - SPC p v runs a vp command (dev, build, test, check, ...) from the root.

(defvar my/vp-executable "vp")

(defvar my/vp--root-cache (make-hash-table :test #'equal)
  "Directory -> Vite+ project root, or `none'.")

(defun my/vp--mentions-vite-plus-p (file)
  (and (file-readable-p file)
       (with-temp-buffer
         (insert-file-contents file nil 0 65536)
         (search-forward "vite-plus" nil t))))

(defun my/vp-root (&optional dir)
  "Return the nearest Vite+ project root above DIR (default `default-directory'), or nil."
  (let* ((dir (expand-file-name (or dir default-directory)))
         (hit (gethash dir my/vp--root-cache)))
    (unless hit
      (setq hit
            (or (let ((d dir) found)
                  (while (and d (not found))
                    (when (or (my/vp--mentions-vite-plus-p (expand-file-name "package.json" d))
                              (cl-some (lambda (f) (my/vp--mentions-vite-plus-p (expand-file-name f d)))
                                       '("vite.config.ts" "vite.config.mts" "vite.config.js" "vite.config.mjs")))
                      (setq found d))
                    (let ((parent (file-name-directory (directory-file-name d))))
                      (setq d (unless (equal parent d) parent))))
                  found)
                'none))
      (puthash dir hit my/vp--root-cache))
    (unless (eq hit 'none) hit)))

(defun my/vp-project-p ()
  (and (executable-find my/vp-executable) (my/vp-root) t))

;;;; Commands

(defconst my/vp-commands
  '("dev" "build" "test" "check" "lint" "fmt" "preview" "install" "pack"))

(defun my/vp-run (command)
  "Run `vp COMMAND' from the Vite+ project root, in a compilation buffer."
  (interactive (list (completing-read "vp " my/vp-commands nil nil)))
  (let ((default-directory (or (my/vp-root) (user-error "Not in a Vite+ project"))))
    (compilation-start (concat my/vp-executable " " command)
                       (and (member command '("dev" "preview")) t)
                       (lambda (_) (format "*vp %s*" command)))))

;;;; Formatting (Apheleia -> vp fmt)

(defconst my/vp-format-modes
  '(js-mode js-ts-mode typescript-mode typescript-ts-mode tsx-ts-mode
    css-mode css-ts-mode json-mode json-ts-mode jsonc-mode))

(defconst my/vp-lint-modes
  '(js-mode js-ts-mode typescript-mode typescript-ts-mode tsx-ts-mode))

(with-eval-after-load 'apheleia
  (setf (alist-get 'vp-fmt apheleia-formatters)
        `(,my/vp-executable "fmt" "--stdin-filepath" filepath)))

(defun my/vp-setup-format ()
  (when (and buffer-file-name
             (apply #'derived-mode-p my/vp-format-modes)
             (my/vp-project-p))
    (setq-local apheleia-formatter 'vp-fmt)))

;;;; Linting (Flymake -> vp lint)

(defconst my/vp-lint-regexp
  "^\\(.+?\\):\\([0-9]+\\):\\([0-9]+\\): \\(.*?\\)\\(?: \\[\\(Error\\|Warning\\|Info\\)[^]]*\\]\\)?$"
  "Oxlint `--format=unix' line: FILE:LINE:COL: MESSAGE [Severity/rule].")

(defvar-local my/vp--lint-proc nil)

(defun my/vp--diagnostic (src line col msg sev)
  (with-current-buffer src
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((bol (point)) (eol (line-end-position)))
        (flymake-make-diagnostic src (min eol (+ bol (max 0 (1- col)))) eol
                                 (if (equal sev "Error") :error :warning) msg)))))

(defun my/vp-flymake (report-fn &rest _)
  "Flymake backend: run `vp lint' on the saved file."
  (when (process-live-p my/vp--lint-proc) (kill-process my/vp--lint-proc))
  (let ((src (current-buffer))
        (file buffer-file-name)
        (root (my/vp-root)))
    (if (or (buffer-modified-p) (not file) (not root))
        (funcall report-fn nil)
      (let ((default-directory root))
        (setq my/vp--lint-proc
              (make-process
               :name "vp-lint" :noquery t :connection-type 'pipe
               :buffer (generate-new-buffer " *vp-lint*")
               :command (list my/vp-executable "lint" "--format=unix" file)
               :sentinel
               (lambda (proc _)
                 (when (memq (process-status proc) '(exit signal))
                   (unwind-protect
                       (when (and (buffer-live-p src)
                                  (eq proc (buffer-local-value 'my/vp--lint-proc src)))
                         (let (diags)
                           (with-current-buffer (process-buffer proc)
                             (goto-char (point-min))
                             (while (re-search-forward my/vp-lint-regexp nil t)
                               (when (string= (expand-file-name (match-string 1) root) file)
                                 (push (my/vp--diagnostic
                                        src
                                        (string-to-number (match-string 2))
                                        (string-to-number (match-string 3))
                                        (match-string 4) (match-string 5))
                                       diags))))
                           (funcall report-fn (nreverse diags))))
                     (kill-buffer (process-buffer proc)))))))))))

(defun my/vp-setup-lint ()
  (when (and buffer-file-name
             (apply #'derived-mode-p my/vp-lint-modes)
             (my/vp-project-p))
    (add-hook 'flymake-diagnostic-functions #'my/vp-flymake nil t)
    ;; Oxlint reads the file from disk, so only lint on save.
    (setq-local flymake-no-changes-timeout nil)
    (add-hook 'after-save-hook
              (lambda () (when (bound-and-true-p flymake-mode) (flymake-start)))
              nil t)))

(add-hook 'after-change-major-mode-hook #'my/vp-setup-format)
(add-hook 'after-change-major-mode-hook #'my/vp-setup-lint)

(my/leader "pv" '(my/vp-run :wk "vp run"))

(provide 'my-lang-vite-plus)
