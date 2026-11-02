;;; ez-review-compose.el --- Text composing buffer for ez-review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One small buffer used for every piece of text you write: a comment, a
;; review summary, a new PR or issue.  `C-c C-c' finishes and hands the text to
;; a callback, `C-c C-k' throws it away.  Forms with metadata (a PR title and
;; base branch) put `Key: value' lines first, then a blank line, then the body;
;; `ez-review-compose-parse' splits them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar-local ez-review-compose--callback nil)
(defvar-local ez-review-compose--config nil "Window configuration to restore.")
(defvar-local ez-review-compose--allow-empty nil)
(defvar corfu-mode)
(defvar corfu-auto)

(defvar-local ez-review-compose--alt nil
  "(LABEL . FUNCTION): a second way to finish, bound to `C-c C-p'.")
(defvar-local ez-review-compose--mentions nil
  "Function returning the usernames to offer after `@', or nil.")

(defcustom ez-review-mention-auto-complete t
  "Non-nil: typing `@' in a compose buffer opens completion right away."
  :type 'boolean
  :group 'ez-review)

(defvar-keymap ez-review-compose-mode-map
  :doc "Keymap for `ez-review-compose-mode'."
  "C-c C-c" #'ez-review-compose-finish
  "C-c C-p" #'ez-review-compose-finish-alt
  "C-c C-k" #'ez-review-compose-cancel)

(defun ez-review-compose-mention-capf ()
  "Complete a `@username' at point from `ez-review-compose--mentions'."
  (when ez-review-compose--mentions
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "A-Za-z0-9_.-")
        (let ((start (point)))
          ;; an @ that starts a word: not the middle of an e-mail address
          (when (and (eq (char-before start) ?@)
                     (or (= (1- start) (point-min))
                         (memq (char-syntax (char-before (1- start))) '(?\s ?\( ?\" ?'))
                         (eq (char-before (1- start)) ?\n)))
            (let ((names (funcall ez-review-compose--mentions)))
              (list start end
                    (lambda (string pred action)
                      (if (eq action 'metadata)
                          ;; keep the participants-first order given by the caller
                          '(metadata (display-sort-function . identity)
                                     (category . ez-review-mention))
                        (complete-with-action action names string pred)))
                    :exclusive 'no
                    ;; Corfu's auto mode pops up even with nothing typed after the @,
                    ;; and without first completing the text, as plain
                    ;; `completion-at-point' does
                    :company-prefix-length t
                    :exit-function
                    (lambda (_name status)
                      (when (and (memq status '(finished exact sole))
                                 (not (looking-at-p "[[:space:]]")))
                        (insert " ")))))))))))

(defun ez-review-compose--maybe-complete ()
  "After typing a word-initial `@', offer the names when nothing else will.
`completion-at-point' completes the text to the common prefix of the matches,
so with a single user it would fill that name in before you chose it.
Corfu's auto mode does not do that and handles `@' by itself (see
`:company-prefix-length' in `ez-review-compose-mention-capf'), so it is left
alone.  With any other UI the offer is made only when there is a real choice;
`completion-at-point' still completes a sole match when you ask for it."
  (when (and ez-review-mention-auto-complete
             ez-review-compose--mentions
             (eq last-command-event ?@)
             (or (= (point) (1+ (point-min)))
                 (memq (char-syntax (char-before (1- (point)))) '(?\s ?\( ?\" ?'))
                 (eq (char-before (1- (point))) ?\n))
             (not (and (bound-and-true-p corfu-mode) (bound-and-true-p corfu-auto)))
             (> (length (funcall ez-review-compose--mentions)) 1))
    (completion-at-point)))

(define-derived-mode ez-review-compose-mode text-mode "Compose"
  "Mode for writing comments and descriptions for ez-review.
Type `@' to complete a user name."
  (visual-line-mode 1)
  (setq-local fill-column 80)
  (add-hook 'completion-at-point-functions #'ez-review-compose-mention-capf nil t)
  (add-hook 'post-self-insert-hook #'ez-review-compose--maybe-complete nil t))

(cl-defun ez-review-compose (name initial callback &key (header "Write, then") allow-empty mentions alt)
  "Open a compose buffer called NAME holding INITIAL; call CALLBACK with the text.
HEADER starts the header line.  Empty text is refused unless ALLOW-EMPTY.
MENTIONS is a function returning the user names to offer after `@'.
ALT is (LABEL . FUNCTION): `C-c C-p' finishes by calling FUNCTION instead."
  (let ((buf (get-buffer-create (format "*ez-review compose: %s*" name)))
        (config (current-window-configuration)))
    (with-current-buffer buf
      (erase-buffer)
      (ez-review-compose-mode)
      (insert (or initial ""))
      (goto-char (point-min))
      (setq ez-review-compose--callback callback
            ez-review-compose--config config
            ez-review-compose--allow-empty allow-empty
            ez-review-compose--mentions mentions
            ez-review-compose--alt alt
            header-line-format
            (list (propertize (format " %s " name) 'face 'bold) "  "
                  header "  "
                  (propertize "C-c C-c" 'face 'help-key-binding) " done  "
                  (if alt (concat (propertize "C-c C-p" 'face 'help-key-binding) " " (car alt) "  ") "")
                  (propertize "C-c C-k" 'face 'help-key-binding) " cancel")))
    (pop-to-buffer buf)
    (when (and initial (string-match-p "\\`[A-Za-z]+: " initial))
      (end-of-line))
    buf))

(defun ez-review-compose-finish ()
  "Finish composing and pass the text to the callback."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (callback ez-review-compose--callback)
        (config ez-review-compose--config))
    (when (and (string-empty-p text) (not ez-review-compose--allow-empty))
      (user-error "Nothing written; use C-c C-k to cancel"))
    (kill-buffer (current-buffer))
    (when (window-configuration-p config) (set-window-configuration config))
    (funcall callback text)))

(defun ez-review-compose-finish-alt ()
  "Finish with the alternative action of this buffer (see `ez-review-compose')."
  (interactive)
  (unless ez-review-compose--alt (user-error "No second action here; use C-c C-c"))
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (action (cdr ez-review-compose--alt))
        (config ez-review-compose--config))
    (when (string-empty-p text) (user-error "Nothing written; use C-c C-k to cancel"))
    (kill-buffer (current-buffer))
    (when (window-configuration-p config) (set-window-configuration config))
    (funcall action text)))

(defun ez-review-compose-cancel ()
  "Throw the text away."
  (interactive)
  (let ((config ez-review-compose--config))
    (kill-buffer (current-buffer))
    (when (window-configuration-p config) (set-window-configuration config))
    (message "Cancelled")))

(defun ez-review-compose-parse (text)
  "Split TEXT into (HEADERS . BODY).
HEADERS is an alist of (\"Key\" . \"value\") from the leading `Key: value' lines."
  (let ((lines (split-string text "\n"))
        headers)
    (while (and lines (string-match "\\`\\([A-Za-z][A-Za-z ]*\\): ?\\(.*\\)\\'" (car lines)))
      (push (cons (match-string 1 (car lines)) (string-trim (match-string 2 (car lines)))) headers)
      (pop lines))
    (cons (nreverse headers) (string-trim (string-join lines "\n")))))

(provide 'ez-review-compose)
;;; ez-review-compose.el ends here
