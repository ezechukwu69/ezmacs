;;; my-ui-font.el --- Fonts  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(defcustom my/font-candidates '("JetBrains Mono" "JetBrainsMono Nerd Font" "Fira Code" "Menlo")
  "Monospace fonts to try, in order of preference."
  :type '(repeat string) :group 'faces)

(defcustom my/font-size 140
  "Default face height (1/10 pt)."
  :type 'integer :group 'faces)

(defun my/apply-font ()
  "Apply the first installed font from `my/font-candidates'."
  (when (display-graphic-p)
    (when-let* ((font (seq-find (lambda (f) (find-font (font-spec :name f)))
                                my/font-candidates)))
      (set-face-attribute 'default nil :family font :height my/font-size)
      (set-face-attribute 'fixed-pitch nil :family font))))

(my/apply-font)
(add-hook 'server-after-make-frame-hook #'my/apply-font)

(provide 'my-ui-font)
