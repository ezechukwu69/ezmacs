;;; init.el --- Entry point  -*- lexical-binding: t; -*-

;;; Commentary:
;; All code lives in lisp/, Emacs 31's `user-lisp-directory' (see early-init.el).
;; Emacs puts lisp/ and every subdirectory on `load-path' by itself, so no
;; load-path bookkeeping happens here.
;;
;; The config is split into *categories*, one directory each under lisp/.
;; Every category has a main file `my-<category>.el' that `require's the
;; individual feature files in that directory (`my-<category>-<feature>.el').
;;
;; To add a plugin:
;;   1. create lisp/<category>/my-<category>-<feature>.el
;;      (ending with (provide 'my-<category>-<feature>))
;;   2. add my-<category>-<feature> to the `mapc #'require' list in lisp/<category>/my-<category>.el
;;
;; To add a new category: create lisp/<name>/my-<name>.el and add
;; my-<name> to the list below.  Order matters: later categories
;; may rely on earlier ones (e.g. `keys' provides the leader definer).
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

;; Categories, in load order.
(mapc #'require
      '(my-core                         ; packages, sane defaults, file hygiene
        my-ui                           ; theme, fonts, modeline, icons
        my-keys                         ; evil + SPC leader
        my-editing                      ; undo, pairs, navigation, whitespace
        my-completion                   ; vertico, marginalia, consult, embark, corfu, cape
        my-workspace                    ; per-project workspaces with isolated buffers
        my-lang                         ; eglot, tree-sitter, formatting, language modes
        my-vc                           ; magit, diff-hl
        my-org                          ; org, agenda, capture, roam
        my-ai                           ; agent-shell
        my-tools))                      ; which-key, helpful, terminal, dired, ...

(when (file-exists-p custom-file)
  (load custom-file 'noerror 'nomessage))

;;; init.el ends here
