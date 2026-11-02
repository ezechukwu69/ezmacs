;;; my-ui-modeline.el --- Modeline (ez-modeline)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; A simple modeline with one thin bar between it and the buffer, from
;; lisp/custom-plugins/ez-modeline/.  It replaces doom-modeline.
;;
;;   SPC t m   move it between the bottom and the top of the windows (remembered)
;;
;; Or set `ez-modeline-position' to `top' / `bottom' in config.el with `setopt'
;; (a plain `setq' does not move a modeline that is already showing).  More
;; options: M-x customize-group RET ez-modeline.

(require 'my-ui-prefs)
(require 'ez-modeline)

(declare-function my/leader "my-keys-leader")

;; The position chosen with `SPC t m' last time.
(when-let* ((saved (my/ui-pref :modeline-position))
            ((memq saved '(top bottom))))
  (setq ez-modeline-position saved))

(add-hook 'ez-modeline-position-changed-hook
          (lambda () (my/ui-pref-save :modeline-position ez-modeline-position)))

(ez-modeline-mode 1)

;; `my/leader' does not exist yet (keys load after ui): bind once init is done.
(defun my-ui-modeline--bind-keys ()
  (when (fboundp 'my/leader)
    (my/leader "tm" '(ez-modeline-toggle-position :wk "modeline top/bottom"))))

(if after-init-time
    (my-ui-modeline--bind-keys)         ; reloaded after startup
  (add-hook 'after-init-hook #'my-ui-modeline--bind-keys))

(provide 'my-ui-modeline)
