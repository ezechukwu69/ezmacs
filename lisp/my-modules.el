;;; my-modules.el --- Doom-style module declaration: (my! :category module ...)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; The config is a set of modules, one file each: lisp/<category>/my-<category>-<module>.el.
;; Which ones are loaded, and in what order, is declared in one place,
;; modules.el at the root of the config, exactly like Doom's `doom!' block:
;;
;;   (my! :ui     theme font modeline
;;        :lang   eglot (format +onsave) dart
;;        :tools  media)
;;
;; - A keyword starts a category; the symbols after it are its modules, loaded
;;   in the order written.  Categories load in the order written too.
;; - `theme' in `:ui' is the feature `my-ui-theme'.  Comment a module out (or
;;   delete it) to disable it; its file is then never loaded.
;; - `(format +onsave)' passes flags to a module.  A module reads them with
;;   `my-module-flag-p'; `my-module-p' tells whether a module is enabled at all,
;;   so one module can adapt to another without requiring it.
;; - Every module is registered before any is loaded, so `my-module-p' is
;;   accurate from inside a module regardless of order.
;; - A module that errors, or is not found (typo), is reported with a warning
;;   and the rest still load.  With `--debug-init' errors propagate instead.
;;
;; `M-x my-modules-report' lists what is enabled, its flags and load times.
;; Personal overrides that are not a module go in config.el (loaded last).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar my-modules--table (make-hash-table :test #'equal)
  "(CATEGORY . NAME) -> plist (:flags :feature :status :time :error).")

(defvar my-modules--order nil
  "Declared modules, as (CATEGORY . NAME), in load order.")

(defun my-modules--feature (category name)
  "The feature provided by module NAME of CATEGORY: :lang dart -> `my-lang-dart'."
  (intern (format "my-%s-%s" (substring (symbol-name category) 1) name)))

(defun my-modules--parse (specs)
  "SPECS (the body of `my!') as a list of (CATEGORY NAME FLAGS)."
  (let (category out)
    (dolist (spec specs)
      (cond
       ((keywordp spec) (setq category spec))
       ((null category) (error "Module %S comes before any :category in my!" spec))
       (t (let ((name (if (consp spec) (car spec) spec))
                (flags (and (consp spec) (cdr spec))))
            (unless (and name (symbolp name) (not (keywordp name)))
              (error "Bad module %S under %s in my! (want NAME or (NAME +flag ...))" spec category))
            (push (list category name flags) out)))))
    (nreverse out)))

(defun my-modules--require (category name)
  "Load the file of module NAME of CATEGORY and record how it went."
  (let* ((key (cons category name))
         (feature (my-modules--feature category name))
         (entry (gethash key my-modules--table))
         (start (float-time)))
    (cond
     ((not (locate-library (symbol-name feature)))
      (puthash key (plist-put entry :status 'missing) my-modules--table)
      (display-warning 'my-modules
                       (format "Module %s %s is enabled in modules.el but %s.el does not exist"
                               category name feature)
                       :warning))
     (init-file-debug
      (require feature)
      (puthash key (plist-put entry :status 'loaded) my-modules--table))
     (t
      (condition-case err
          (progn (require feature)
                 (puthash key (plist-put entry :status 'loaded) my-modules--table))
        (error
         (puthash key (plist-put (plist-put entry :status 'error) :error (error-message-string err))
                  my-modules--table)
         (display-warning 'my-modules
                          (format "Module %s %s failed to load: %s" category name
                                  (error-message-string err))
                          :error)))))
    (puthash key (plist-put (gethash key my-modules--table) :time (- (float-time) start))
             my-modules--table)))

(defun my-modules-load (specs)
  "Register every module in SPECS, then load them in order.  See `my!'."
  (let ((modules (my-modules--parse specs)))
    ;; Register all first so `my-module-p' is right from inside any module.
    (dolist (m modules)
      (let ((key (cons (nth 0 m) (nth 1 m))))
        (if (gethash key my-modules--table)
            (display-warning 'my-modules (format "Module %s %s is listed twice; ignoring the repeat"
                                                 (nth 0 m) (nth 1 m)))
          (puthash key (list :flags (nth 2 m) :feature (my-modules--feature (nth 0 m) (nth 1 m)))
                   my-modules--table)
          (setq my-modules--order (append my-modules--order (list key))))))
    (dolist (key my-modules--order)
      (when (null (plist-get (gethash key my-modules--table) :status))
        (my-modules--require (car key) (cdr key))))))

(defmacro my! (&rest specs)
  "Declare the modules to load; SPECS are not evaluated.
Write `:category' keywords followed by module names; a module is either NAME
or (NAME +flag ...).  See the commentary of my-modules.el."
  `(my-modules-load ',specs))

;;;; Queries (for use inside modules and config.el)

(defun my-module-p (category name)
  "Non-nil if module NAME of CATEGORY is enabled in modules.el.
Example: (my-module-p :lang \\='dart)."
  (and (gethash (cons category name) my-modules--table) t))

(defun my-module-flags (category name)
  "The +flags given to module NAME of CATEGORY, or nil."
  (plist-get (gethash (cons category name) my-modules--table) :flags))

(defun my-module-flag-p (category name flag)
  "Non-nil if module NAME of CATEGORY was given FLAG, a symbol like +onsave."
  (and (memq flag (my-module-flags category name)) t))

;;;; Report

;;;###autoload
(defun my-modules-report ()
  "Show every enabled module, its flags, state and load time."
  (interactive)
  (with-current-buffer (get-buffer-create "*my-modules*")
    (let ((inhibit-read-only t) (last nil) (total 0.0))
      (erase-buffer)
      (dolist (key my-modules--order)
        (let* ((e (gethash key my-modules--table))
               (time (or (plist-get e :time) 0.0)))
          (unless (eq (car key) last)
            (insert (format "\n%s\n" (car key)))
            (setq last (car key)))
          (setq total (+ total time))
          (insert (format "  %-14s %-8s %6.1f ms  %s%s\n" (cdr key)
                          (or (plist-get e :status) 'pending) (* 1000 time)
                          (mapconcat #'symbol-name (plist-get e :flags) " ")
                          (if (plist-get e :error) (format "   !! %s" (plist-get e :error)) "")))))
      (goto-char (point-min))
      (insert (format "%d modules, %.0f ms total\n" (length my-modules--order) (* 1000 total)))
      (special-mode))
    (pop-to-buffer (current-buffer))))

(provide 'my-modules)
;;; my-modules.el ends here
