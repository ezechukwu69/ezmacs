;;; my-lang-flutter.el --- Flutter via lisp/custom-plugins/ez-flutter.el  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

(declare-function my/local-leader "my-keys-leader")
;;
;; ez-flutter.el lives in ~/.emacs.d/lisp/custom-plugins/, inside Emacs 31's
;; `user-lisp-directory' (set in early-init.el): it is already on `load-path'
;; and byte-compiled, so we only need to require it.  It drives `flutter
;; debug_adapter' through dape and offers hot reload/restart, DevTools and
;; reload-on-save (after Apheleia formats).  Loaded the first time a Dart
;; buffer is visited or one of its commands is run.

(dolist (cmd '(ez/flutter-start ez/flutter-stop ez/flutter-reload ez/flutter-restart
               ez/flutter-devices ez/open-devtools ez/flutter-switch-session))
  (autoload cmd "ez-flutter" nil t))

(dolist (hook '(dart-ts-mode-hook dart-mode-hook))
  (add-hook hook (lambda () (require 'ez-flutter))))

;; SPC m … in Dart buffers (SPC d F works anywhere)
(my/leader "dF" '(ez/flutter-switch-session :wk "switch flutter session"))

(dolist (map '(dart-ts-mode-map dart-mode-map))
  (my/local-leader :keymaps map
    ""  '(:ignore t :wk "flutter")
    "s" '(ez/flutter-start :wk "run/debug (C-u: pick device)")
    "S" '(ez/flutter-switch-session :wk "switch session")
    "q" '(ez/flutter-stop :wk "stop")
    "r" '(ez/flutter-reload :wk "hot reload")
    "R" '(ez/flutter-restart :wk "hot restart")
    "d" '(ez/open-devtools :wk "devtools")
    "e" '(ez/flutter-devices :wk "launch emulator")
    "b" '(dape-breakpoint-toggle :wk "breakpoint")))

(provide 'my-lang-flutter)
