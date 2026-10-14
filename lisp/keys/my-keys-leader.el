;;; my-keys-leader.el --- SPC leader (general.el)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Other modules bind keys with:
;;   (my/leader "gg" '(magit-status :wk "status"))
;; and local (mode specific) keys with:
;;   (my/local-leader :keymaps 'org-mode-map "t" 'org-todo)

(use-package general
  :demand t
  :config (general-evil-setup))

;; Plain functions (not general's definer macros) so that files using them also
;; byte-compile correctly on their own, e.g. under Flymake.
(declare-function general-define-key "general")

(defun my/leader (&rest args)
  "Bind ARGS (key def ...) under the SPC leader (M-SPC everywhere)."
  (apply #'general-define-key
         :states '(normal visual motion emacs insert)
         :keymaps 'override
         :prefix "SPC"
         :global-prefix "M-SPC"
         args))

(defun my/local-leader (&rest args)
  "Bind ARGS under the mode specific SPC m prefix; pass `:keymaps' MAP."
  (apply #'general-define-key
         :states '(normal visual motion emacs insert)
         :prefix "SPC m"
         :global-prefix "M-SPC m"
         args))

  ;; Top-level prefixes (labels for which-key). Feature files fill them in.
  (my/leader
    "SPC" '(execute-extended-command :wk "M-x")
    "."   '(find-file :wk "find file")
    ","   '(switch-to-buffer :wk "switch buffer")
    "/"   '(consult-ripgrep :wk "search project")
    ":"   '(eval-expression :wk "eval")
    "u"   '(universal-argument :wk "universal arg")

    "a"   '(:ignore t :wk "ai/agent")
    "b"   '(:ignore t :wk "buffer")
    "c"   '(:ignore t :wk "code")
    "e"   '(:ignore t :wk "error")
    "f"   '(:ignore t :wk "file")
    "g"   '(:ignore t :wk "git")
    "h"   '(:ignore t :wk "help")
    "m"   '(:ignore t :wk "mode")
    "n"   '(:ignore t :wk "notes")
    "o"   '(:ignore t :wk "org")
    "p"   '(:ignore t :wk "project")
    "q"   '(:ignore t :wk "quit")
    "s"   '(:ignore t :wk "search")
    "t"   '(:ignore t :wk "toggle")
    "w"   '(:ignore t :wk "window")
    "TAB" '(:ignore t :wk "workspace")

    ;; buffers
    "bb" '(switch-to-buffer :wk "switch")
    "bd" '(kill-current-buffer :wk "kill")
    "bn" '(next-buffer :wk "next")
    "bp" '(previous-buffer :wk "previous")
    "br" '(revert-buffer-quick :wk "revert")
    "bs" '(scratch-buffer :wk "scratch")

    ;; files
    "ff" '(find-file :wk "find")
    "fr" '(consult-recent-file :wk "recent")
    "fs" '(save-buffer :wk "save")
    "fS" '(write-file :wk "save as")
    "fD" '(my/delete-this-file :wk "delete")
    "fR" '(my/rename-this-file :wk "rename")
    "fi" '((lambda () (interactive) (find-file user-init-file)) :wk "init.el")
    "fc" '((lambda () (interactive) (dired (expand-file-name "lisp/" user-emacs-directory)))
           :wk "config (lisp/)")

    ;; windows
    "wh" '(evil-window-left :wk "left")
    "wj" '(evil-window-down :wk "down")
    "wk" '(evil-window-up :wk "up")
    "wl" '(evil-window-right :wk "right")
    "ws" '(evil-window-split :wk "split below")
    "wv" '(evil-window-vsplit :wk "split right")
    "wd" '(evil-window-delete :wk "delete")
    "wo" '(delete-other-windows :wk "only")
    "w=" '(balance-windows :wk "balance")
    "wu" '(winner-undo :wk "undo layout")
    "wU" '(winner-redo :wk "redo layout")

    ;; help
    "hk" '(describe-key :wk "key")
    "hf" '(describe-function :wk "function")
    "hv" '(describe-variable :wk "variable")
    "hm" '(describe-mode :wk "mode")
    "hi" '(info :wk "info")

    ;; quit
    "qq" '(save-buffers-kill-terminal :wk "quit emacs")
    "qr" '(restart-emacs :wk "restart")

    ;; toggles
    "tl" '(display-line-numbers-mode :wk "line numbers")
    "tw" '(visual-line-mode :wk "wrap")
    "tt" '(consult-theme :wk "theme")
    "te" '(my/evil-toggle :wk "evil")
    "tf" '(toggle-frame-fullscreen :wk "fullscreen")

    ;; search
    "ss" '(consult-line :wk "line")
    "si" '(consult-imenu :wk "imenu")
    "so" '(consult-outline :wk "outline")
    "sr" '(consult-ripgrep :wk "ripgrep")
    "sf" '(consult-fd :wk "fd"))

(winner-mode 1)

(defun my/delete-this-file ()
  "Delete the file visited by the current buffer, and kill the buffer."
  (interactive)
  (when-let* ((file (buffer-file-name)))
    (when (y-or-n-p (format "Delete %s? " file))
      (delete-file file t)
      (kill-buffer))))

(defun my/rename-this-file (new)
  "Rename the visited file to NEW."
  (interactive (list (read-file-name "Rename to: " nil nil nil
                                     (file-name-nondirectory (or buffer-file-name "")))))
  (when buffer-file-name
    (rename-file buffer-file-name new 1)
    (set-visited-file-name new t t)))

;; ESC aborts the minibuffer, like in vim.
(dolist (map (list minibuffer-local-map minibuffer-local-ns-map
                   minibuffer-local-completion-map minibuffer-local-must-match-map
                   minibuffer-local-isearch-map))
  (define-key map (kbd "<escape>") #'abort-minibuffers))

(provide 'my-keys-leader)
