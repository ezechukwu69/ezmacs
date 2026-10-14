;;; my-lang-dart.el --- Dart: community tree-sitter mode  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Emacs has no built-in Dart tree-sitter mode.  `dart-ts-mode' (community,
;; GitHub only) is installed straight from its repo with the built-in
;; `package-vc' (use-package's :vc keyword, Emacs 30+).  Eglot already knows
;; `dart-ts-mode' and starts `dart language-server'.

(use-package dart-ts-mode
  :vc (:url "https://github.com/50ways2sayhard/dart-ts-mode" :rev :newest)
  :mode "\\.dart\\'"
  :init
  ;; Where `treesit-ensure-installed' / `my/treesit-install-all' fetch the grammar.
  (with-eval-after-load 'treesit
    (add-to-list 'treesit-language-source-alist
                 '(dart "https://github.com/UserNobody14/tree-sitter-dart")))
  ;; Fall back to classic `dart-mode' (below) when the grammar is not installed.
  (add-to-list 'treesit-major-mode-remap-alist '(dart-mode . dart-ts-mode))
  :config
  (setopt dart-ts-mode-indent-offset 2))

;; Fallback major mode when no grammar is available; also used by older tooling.
(use-package dart-mode
  :defer t)

;; Re-run the setter so the remap above is picked up by `treesit-enabled-modes'.
(setopt treesit-enabled-modes treesit-enabled-modes)

(provide 'my-lang-dart)
