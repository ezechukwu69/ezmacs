;;; config.el --- Personal overrides, loaded after every module  -*- lexical-binding: t; -*-

;;; Commentary:

;; Like Doom's config.el: runs after all modules in modules.el have loaded, so
;; anything set here wins over the modules' defaults.  Put tweaks here instead
;; of editing module files.  Use `with-eval-after-load' for packages that are
;; loaded lazily.  Machine-local `customize' output goes to custom.el, not here.

;;; Code:

;; Personal settings (active):
(setq ez-dashboard-name "Ezechukwu")     ; the greeting on the start-up dashboard
(setopt ez-modeline-padding 12)

;; Examples (uncomment to use):
;;
;; (setq-default fill-column 100)
;;
;; (with-eval-after-load 'vertico
;;   (setq vertico-count 15))
;;
;; Adapt to which modules are on:
;; (when (my-module-p :lang 'dart)
;;   (setq dart-format-on-save t))
;; (when (my-module-flag-p :lang 'format '+onsave)
;;   (message "format-on-save requested"))
;;
;; Keybindings go through the leader definer from the :keys module:
;; (my/leader "zz" '(my/some-command :wk "my command"))

;;; config.el ends here
