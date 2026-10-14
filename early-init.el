;;; early-init.el --- Runs before package.el and the first frame  -*- lexical-binding: t; -*-

;; Defer GC during startup; core module restores sane values afterwards.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Keep ~/.emacs.d for config only: everything generated lives elsewhere.
;;   data  (packages, history, org-roam db, custom.el): ~/.local/share/emacs-ez/
;;   cache (native-comp .eln files):                    ~/.cache/emacs-ez/
(defconst my/data-dir (expand-file-name "emacs-ez/" (or (getenv "XDG_DATA_HOME") "~/.local/share/")))
(defconst my/cache-dir (expand-file-name "emacs-ez/" (or (getenv "XDG_CACHE_HOME") "~/.cache/")))
(make-directory my/data-dir t)
(make-directory my/cache-dir t)

(setq package-user-dir (expand-file-name "elpa/" my/data-dir)
      no-littering-etc-directory (expand-file-name "etc/" my/data-dir)
      no-littering-var-directory (expand-file-name "var/" my/data-dir))

;; Async native-compilation runs child Emacsen that know nothing about the paths
;; above; without this they re-create elpa/, undo-fu-session/ ... in ~/.emacs.d.
(setq native-comp-async-env-modifier-form
      `(setq user-emacs-directory ,(expand-file-name "native-comp-home/" my/data-dir)
             package-user-dir ,package-user-dir
             no-littering-etc-directory ,no-littering-etc-directory
             no-littering-var-directory ,no-littering-var-directory
             ;; preloaded in the dump with the default path, so set explicitly
             project-list-file ,(expand-file-name "project-list.el" no-littering-var-directory)))

(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (expand-file-name "eln-cache/" my/cache-dir)))

;; Emacs 31 "user lisp": lisp/ holds ALL of this config's code (category modules and
;; custom-plugins/).  Emacs puts it and every subdirectory on `load-path' at
;; startup; my-core-userlisp.el then byte-compiles and scrapes autoloads.
;; Must be set here, before init.el runs.
(when (boundp 'user-lisp-directory)
  (setq user-lisp-directory (expand-file-name "lisp/" user-emacs-directory)
        ;; Only put it on `load-path' now; compiling happens after init (see
        ;; my-core-userlisp.el) when macros and packages are available.
        user-lisp-auto-scrape nil))

;; We initialise packages ourselves in lisp/core/my-core-packages.el.
(setq package-enable-at-startup nil)

;; Skip file-name handlers (tramp, jka-compr, ...) while loading init; restored after.
(defvar my/--file-name-handler-alist file-name-handler-alist)
(setq file-name-handler-alist nil)
(add-hook 'emacs-startup-hook
          (lambda () (setq file-name-handler-alist
                           (delete-dups (append file-name-handler-alist
                                                my/--file-name-handler-alist)))))

;; Avoid frame flicker / resizing at startup.
(setq frame-inhibit-implied-resize t
      inhibit-startup-screen t
      load-prefer-newer t)

(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)

;; Silence native-comp noise.
(setq native-comp-async-report-warnings-errors 'silent)
;;; early-init.el ends here
