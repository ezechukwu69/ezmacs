;;; my-ui-theme.el --- Theme  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'my-ui-prefs)

(defcustom my/default-theme 'doom-tokyo-night
  "Theme used until one is chosen with `my/select-theme'."
  :type 'symbol :group 'faces)


(use-package au-themes
  :vc (:url "https://github.com/szymonwilczek/au-themes" :rev :newest)
  :ensure nil)

(use-package doom-themes
  :demand t
  :config
  (setq doom-themes-enable-bold t
        doom-themes-enable-italic t)
  (load-theme (let ((saved (my/ui-pref :theme)))
                (if (and saved (memq saved (custom-available-themes))) saved my/default-theme))
              t)
  (doom-themes-org-config))


(defun my/select-theme (theme)
  "Choose THEME from the installed themes, apply it and remember it."
  (interactive
   (list (intern (completing-read "Theme: " (mapcar #'symbol-name (custom-available-themes))
                                  nil t nil nil
                                  (and custom-enabled-themes
                                       (symbol-name (car custom-enabled-themes)))))))
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (my/ui-pref-save :theme theme)
  (my/ui-refresh)
  (message "Theme: %s (saved)" theme))

(provide 'my-ui-theme)
