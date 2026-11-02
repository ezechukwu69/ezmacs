;;; my-keys-jumps.el --- Evil jump list in Emacs mode (C-c o / C-c i), shared with Evil  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Evil's jump list ("go back to where I was before that jump", C-o, and forward
;; again with C-i) made available when Evil is off, and fed by the usual Emacs
;; ways of moving far: M-. M-, M-? (xref, LSP), C-s and the other searches,
;; beginning/end of buffer, goto-line, imenu / consult / avy jumps, next-error,
;; opening another file or buffer.  It is Evil's own list, so the history is the
;; same in both modes and survives toggling Evil (SPC t e).
;;
;;   C-c o     back to the previous place
;;   C-c i     forward again
;;
;; How it works.  Evil marks "jump" commands with a `:jump' property and records
;; the position before them from `pre-command-hook'.  `my/jump-commands' tags
;; the Emacs commands above the same way; where Evil's hook is not running
;; (Evil off, or a buffer Evil leaves alone) `my/jump--record' does the job.
;; Like Vim, only buffers that visit a file (plus *scratch*) are recorded.
;;
;;
;; C-o and C-i are not bound: they are `open-line' and TAB.

(require 'cl-lib)
(require 'evil)

(declare-function evil-jump-backward "evil-commands")
(declare-function evil-jump-forward "evil-commands")
(declare-function evil-set-jump "evil-jumps")

(defun my/jump--tag (commands)
  "Mark COMMANDS as jump commands for Evil's jump list."
  (dolist (c commands) (evil-add-command-properties c :jump t)))

(defcustom my/jump-commands
  '(;; M-. M-, M-? and the LSP lookups
    xref-find-definitions xref-find-definitions-other-window xref-find-definitions-other-frame
    xref-find-references xref-find-apropos xref-go-back xref-go-forward
    eglot-find-declaration eglot-find-implementation eglot-find-typeDefinition
    ;; searching (C-s and friends)
    isearch-forward isearch-backward isearch-forward-regexp isearch-backward-regexp
    isearch-forward-word isearch-forward-symbol isearch-forward-symbol-at-point
    ;; far moves
    beginning-of-buffer end-of-buffer goto-line move-to-window-line-top-bottom
    ;; menus that take you somewhere
    imenu consult-imenu consult-imenu-multi consult-outline consult-line consult-line-multi
    consult-goto-line consult-mark consult-global-mark consult-ripgrep consult-git-grep
    consult-grep consult-xref consult-flymake my/symbols-buffer my/symbols-workspace
    avy-goto-char avy-goto-char-2 avy-goto-char-timer avy-goto-line avy-goto-word-1
    ;; errors, diagnostics, hunks
    next-error previous-error compile-goto-error
    flymake-goto-next-error flymake-goto-prev-error diff-hl-next-hunk diff-hl-previous-hunk
    ;; other files and buffers
    find-file find-file-other-window switch-to-buffer consult-buffer project-find-file
    project-switch-to-buffer dired-jump pop-global-mark)
  "Commands that count as a jump: where they start is added to the jump list.
The list is walked with `evil-jump-backward' and `evil-jump-forward'.  Adding a
command here takes effect when set through Customize or `setopt'."
  :type '(repeat symbol)
  :set (lambda (sym val) (set-default sym val) (my/jump--tag val))
  :initialize (lambda (sym val) (custom-initialize-default sym val) (my/jump--tag (symbol-value sym)))
  :group 'evil)

(defun my/jump--record ()
  "Remember where a jump command starts, where Evil's own hook is not running.
In a buffer with `evil-local-mode' on, Evil's `evil--jump-hook' already does it."
  (when (and (symbolp this-command)
             (not (bound-and-true-p evil-local-mode))
             (not (minibufferp))
             (evil-get-command-property this-command :jump))
    (ignore-errors (evil-set-jump))))

(add-hook 'pre-command-hook #'my/jump--record)

;; The keys (C-c o / C-c i) are declared in my-keys-table.el.  C-o (`open-line') and
;; C-i (TAB) are built in, so they are left alone; M-, and C-M-, (xref) also exist.

(provide 'my-keys-jumps)
