;;; init.el --- Entry point  -*- lexical-binding: t; -*-

;;; Commentary:
;; All code lives in lisp/, Emacs 31's `user-lisp-directory' (see early-init.el).
;; Emacs puts lisp/ and every subdirectory on `load-path' by itself, so no
;; load-path bookkeeping happens here.
;;
;; The config is a set of *modules*, one file each, grouped in *categories*
;; (a directory each under lisp/): lisp/<category>/my-<category>-<module>.el.
;; What loads, and in what order, is declared in modules.el, in the style of
;; Doom's `doom!' block.  Personal overrides go in config.el, which loads last.
;;
;; To add a plugin:
;;   1. create lisp/<category>/my-<category>-<module>.el
;;      (ending with (provide 'my-<category>-<module>))
;;   2. list <module> under :<category> in modules.el
;; To disable one: comment it out in modules.el.  `M-x my-modules-report' shows
;; what loaded.  A new category is a new keyword in modules.el plus a directory.
;; Standalone libraries (not part of the load order) go in lisp/custom-plugins/.

;;; Code:

(defvar my/data-dir)                    ; defined in early-init.el

(defconst my/emacs-dir (file-name-directory (or load-file-name buffer-file-name))
  "Root of this configuration.")

;; early-init.el normally runs first; load it ourselves if not (e.g. `emacs --batch -l init.el').
(unless (boundp 'my/data-dir)
  (load (expand-file-name "early-init.el" my/emacs-dir) nil t)
  (when (file-directory-p user-lisp-directory) (prepare-user-lisp t)))

;; Machine-specific settings live here and stay out of the modules.
(setq custom-file (expand-file-name "custom.el" my/data-dir))

;; The module system, then the module list (modules.el) and your overrides
;; (config.el, optional).
(require 'my-modules)
(load (expand-file-name "modules.el" my/emacs-dir) nil 'nomessage)
(load (expand-file-name "config.el" my/emacs-dir) 'noerror 'nomessage)

(when (file-exists-p custom-file)
  (load custom-file 'noerror 'nomessage))

;;; init.el ends here
