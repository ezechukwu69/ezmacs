;;; my-core-performance.el --- Keep file opening and editing fast  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Only Git; the default list probes CVS/SVN/Hg/... for every file.
(setq vc-handled-backends '(Git))

;; Rendering / scrolling
(setq-default bidi-display-reordering nil
              bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t
      fast-but-imprecise-scrolling t
      redisplay-skip-fontification-on-input t
      jit-lock-defer-time 0
      jit-lock-stealth-time 0.5
      jit-lock-stealth-verbose nil
      inhibit-compacting-font-caches t
      process-adaptive-read-buffering t)

;; recentf cleanup can stall on stale/remote entries.
(setq recentf-auto-cleanup 'never)

;; Compile packages natively at install time instead of on first use.
(setq package-native-compile t
      native-comp-jit-compilation t)

;; Don't ask about/process big files eagerly.
(setq large-file-warning-threshold (* 100 1024 1024)
      so-long-threshold 400)

;;; Large buffers: turn off expensive per-buffer features -------------------

(defcustom my/large-file-threshold (* 512 1024)
  "Buffers bigger than this many bytes get the lightweight treatment."
  :type 'integer :group 'files)

(defcustom my/large-file-disabled-modes
  '(rainbow-delimiters-mode hl-todo-mode diff-hl-mode flymake-mode
    ws-butler-mode apheleia-local-mode yas-minor-mode electric-pair-local-mode
    show-paren-local-mode font-lock-mode)
  "Minor modes switched off in large buffers."
  :type '(repeat symbol) :group 'files)

(defun my/large-buffer-p ()
  (> (buffer-size) my/large-file-threshold))

(defun my/large-file-setup ()
  "Disable heavy modes when the visited file is large."
  (when (my/large-buffer-p)
    (dolist (m my/large-file-disabled-modes)
      (when (and (fboundp m) (boundp m) (symbol-value m))
        (ignore-errors (funcall m -1))))
    (setq-local display-line-numbers nil
                jit-lock-defer-time 0.1)
    (message "Large file (%dK): lightweight mode"
             (/ (buffer-size) 1024))))

(add-hook 'find-file-hook #'my/large-file-setup 90)

(provide 'my-core-performance)
