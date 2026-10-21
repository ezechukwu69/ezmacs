;;; my-ui-font.el --- Fonts  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'my-ui-prefs)

(defcustom my/font-candidates '("Aporetic Serif" "Iosevka" "Iosevka Nerd Font Mono" "Iosevka Fixed" "Menlo")
  "Monospace fonts to try, in order of preference."
  :type '(repeat string) :group 'faces)

(defcustom my/font-size 150
  "Default face height (1/10 pt)."
  :type 'integer :group 'faces)

(defun my/apply-font ()
  "Apply the saved font, else the first installed one from `my/font-candidates'."
  (when (display-graphic-p)
    (when-let* ((font (seq-find (lambda (f) (and f (find-font (font-spec :name f))))
                                (cons (my/ui-pref :font) my/font-candidates)))
                (size (or (my/ui-pref :font-size) my/font-size)))
      (set-face-attribute 'default nil :family font :height size)
      (set-face-attribute 'fixed-pitch nil :family font))))

(defun my/select-font (family &optional size)
  "Choose a font FAMILY, apply it and remember it.
With a prefix argument also ask for the SIZE (1/10 pt, e.g. 140)."
  (interactive
   (list (completing-read "Font: "
                          (seq-uniq (sort (seq-remove #'string-empty-p (font-family-list)) #'string<))
                          nil t nil nil (face-attribute 'default :family))
         (when current-prefix-arg
           (read-number "Size (1/10 pt): " (face-attribute 'default :height)))))
  (my/ui-pref-save :font family)
  (when size (my/ui-pref-save :font-size size))
  (my/apply-font)
  (my/ui-refresh)
  (message "Font: %s (saved)" family))

(my/apply-font)
(add-hook 'server-after-make-frame-hook #'my/apply-font)

(provide 'my-ui-font)
