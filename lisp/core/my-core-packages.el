;;; my-core-packages.el --- package.el + use-package bootstrap  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(require 'package)
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))

(package-initialize)


(unless package-archive-contents
  (package-refresh-contents))

(require 'use-package)
(setq use-package-always-ensure t     ; install anything declared via use-package
      use-package-always-defer nil
      use-package-expand-minimally t)

;; Keep ~/.emacs.d clean: must be loaded before other packages write files.
(use-package no-littering
  :demand t)

;; Restore GC settings once startup is done.
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.2)))

(setq read-process-output-max (* 4 1024 1024)) ; LSP servers push big payloads

(provide 'my-core-packages)
