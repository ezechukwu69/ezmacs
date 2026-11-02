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

;; Less redisplay and idle work
(setq-default cursor-in-non-selected-windows nil)
(setq highlight-nonselected-windows nil
      auto-window-vscroll nil           ; makes line motion expensive with tall lines/images
      use-dialog-box nil
      use-file-dialog nil
      ffap-machine-p-known 'reject)     ; no DNS lookups when point is on a hostname

;; Typing and editing
(blink-cursor-mode -1)                  ; a blinking cursor is a redisplay every half second
(setq long-line-threshold 1000          ; minified/generated lines: stop scanning whole lines
      syntax-wholeline-max 1000
      display-line-numbers-grow-only t  ; width never recomputed while scrolling
      show-paren-delay 0.05
      ;; Wait for a pause in typing before the background checkers run.
      flymake-no-changes-timeout 1.0
      eglot-send-changes-idle-time 0.5
      eldoc-idle-delay 0.4
      ;; Fewer subprocess launches and redraws while typing a consult query.
      consult-async-input-throttle 0.3
      consult-async-input-debounce 0.2
      consult-async-refresh-delay 0.2)

;; Rely on file notifications instead of polling timers for auto-revert.
(setq auto-revert-use-notify t
      auto-revert-avoid-polling t
      auto-revert-interval 5)

;; Saving places stats every remembered file otherwise.
(setq save-place-forget-unreadable-files nil)

;; Collect garbage when Emacs loses focus, so it is less likely to pause you mid-edit.
(add-function :after after-focus-change-function
              (lambda () (unless (frame-focus-state) (garbage-collect))))

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
