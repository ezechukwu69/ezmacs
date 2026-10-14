;;; my-core-defaults.el --- Sane defaults  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)

(setq-default indent-tabs-mode nil
              tab-width 4
              fill-column 80
              sentence-end-double-space nil)

(setq use-short-answers t
      ring-bell-function #'ignore
      confirm-kill-emacs #'y-or-n-p
      require-final-newline t
      scroll-conservatively 101
      scroll-margin 3
      mouse-wheel-progressive-speed nil
      vc-follow-symlinks t
      initial-scratch-message nil
      initial-major-mode 'fundamental-mode
      enable-recursive-minibuffers t
      read-extended-command-predicate #'command-completion-default-include-p
      completion-cycle-threshold 3
      tab-always-indent 'complete
      help-window-select t
      window-combination-resize t
      switch-to-buffer-obey-display-actions t)

(when (fboundp 'pixel-scroll-precision-mode)
  (pixel-scroll-precision-mode 1))

(global-auto-revert-mode 1)
(setq global-auto-revert-non-file-buffers t
      auto-revert-verbose nil)

(delete-selection-mode 1)
(electric-indent-mode 1)
(save-place-mode 1)
(savehist-mode 1)
(recentf-mode 1)
(setq recentf-max-saved-items 200)
(minibuffer-depth-indicate-mode 1)
(global-so-long-mode 1)
(repeat-mode 1)

(setq display-line-numbers-type 'relative)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'conf-mode-hook #'display-line-numbers-mode)
(column-number-mode 1)
(global-hl-line-mode 1)

;; macOS
(when (eq system-type 'darwin)
  (setq mac-command-modifier 'super
        mac-option-modifier 'meta
        mac-right-option-modifier 'none
        ns-use-proxy-icon nil))

(provide 'my-core-defaults)
