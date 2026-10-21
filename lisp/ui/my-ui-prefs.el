;;; my-ui-prefs.el --- Persisted UI choices (font, theme)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(defvar my/data-dir)

(defvar my/ui-prefs-file
  (expand-file-name "ui-prefs.eld" (if (boundp 'my/data-dir) my/data-dir user-emacs-directory))
  "File holding the saved UI choices, a plist.")

(defun my/ui-pref (key)
  "The saved value of KEY, or nil."
  (when (file-readable-p my/ui-prefs-file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents my/ui-prefs-file)
        (plist-get (read (current-buffer)) key)))))

(defun my/ui-pref-save (key value)
  "Persist VALUE under KEY, keeping the other saved choices."
  (let ((plist (or (ignore-errors
                     (when (file-readable-p my/ui-prefs-file)
                       (with-temp-buffer
                         (insert-file-contents my/ui-prefs-file)
                         (read (current-buffer)))))
                   nil)))
    (make-directory (file-name-directory my/ui-prefs-file) t)
    (with-temp-file my/ui-prefs-file
      (prin1 (plist-put plist key value) (current-buffer)))))

(defun my/ui-refresh ()
  "Make a font or theme change show everywhere now, without restarting."
  (clear-face-cache)
  (when (fboundp 'ez-agents-dashboard--render) (ignore-errors (ez-agents-dashboard--render)))
  (when (fboundp 'doom-modeline-refresh-font-width-cache) (ignore-errors (doom-modeline-refresh-font-width-cache)))
  (force-mode-line-update t)
  (redraw-display))

(provide 'my-ui-prefs)
