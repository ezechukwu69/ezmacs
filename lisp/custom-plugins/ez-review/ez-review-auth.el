;;; ez-review-auth.el --- Authenticate gh and glab from Emacs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Credentials are owned by the CLIs (they keep tokens in the OS keyring), so
;; this file only drives `gh auth' and `glab auth'.  Login is interactive, so
;; it runs in a terminal buffer where the CLI can prompt (browser flow, token
;; paste, host choice).  ez-review never reads or stores a token itself.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)

(declare-function make-term "term")
(declare-function term-mode "term")
(declare-function term-char-mode "term")

(defun ez-review-auth--program (kind)
  "CLI program for platform KIND."
  (if (eq kind 'gitlab) ez-review-glab-program ez-review-gh-program))

(defun ez-review-auth--default-host (kind)
  "Host to offer for KIND: the current repo's if it matches, else the public one."
  (or (ignore-errors
        (let ((forge (ez-review-forge-current)))
          (and (eq (ez-review-forge-kind forge) kind) (ez-review-forge-host forge))))
      (if (eq kind 'gitlab) "gitlab.com" "github.com")))

(defun ez-review-auth--read-kind ()
  "Ask for a platform."
  (intern (completing-read "Platform: " '("github" "gitlab") nil t)))

;;;###autoload
(defun ez-review-auth-status ()
  "Show who `gh' and `glab' are logged in as, on every host."
  (interactive)
  (let ((buf (get-buffer-create "*ez-review auth*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (kind '(github gitlab))
          (insert (propertize (format "%s (%s)\n" (capitalize (symbol-name kind))
                                      (ez-review-auth--program kind))
                              'face 'bold))
          (condition-case err
              (pcase-let ((`(,code ,out ,errout)
                           (ez-review-process-sync (ez-review-auth--program kind) '("auth" "status"))))
                ;; gh prints status on stderr, glab on stdout; show whichever has text.
                (insert (let ((text (string-trim (concat out errout))))
                          (if (string-empty-p text) (format "(exit %s, no output)" code) text))
                        "\n\n"))
            (ez-review-error (insert (cadr err) "\n\n"))))
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buf)))

(defun ez-review-auth--terminal (name program args)
  "Run PROGRAM with ARGS in an interactive terminal buffer called NAME."
  (require 'term)
  (let ((path (ez-review-process--program-path program)))
    (with-current-buffer (apply #'make-term name path nil args)
      (term-mode)
      (term-char-mode)
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun ez-review-auth-login (kind host)
  "Log in to HOST on platform KIND (`github' or `gitlab') with its CLI."
  (interactive (let ((kind (ez-review-auth--read-kind)))
                 (list kind (read-string "Host: " (ez-review-auth--default-host kind)))))
  (ez-review-auth--terminal
   (format "ez-review login %s" host) (ez-review-auth--program kind)
   (list "auth" "login" "--hostname" host)))

;;;###autoload
(defun ez-review-auth-logout (kind host)
  "Log out of HOST on platform KIND."
  (interactive (let ((kind (ez-review-auth--read-kind)))
                 (list kind (read-string "Host: " (ez-review-auth--default-host kind)))))
  (when (yes-or-no-p (format "Log out of %s on %s? " host kind))
    (ez-review-auth--terminal
     (format "ez-review logout %s" host) (ez-review-auth--program kind)
     (list "auth" "logout" "--hostname" host))))

(provide 'ez-review-auth)
;;; ez-review-auth.el ends here
