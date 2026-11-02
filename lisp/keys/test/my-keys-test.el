;;; my-keys-test.el --- Tests for the Evil toggle, jumps and Emacs-mode keys -*- lexical-binding: t; -*-

;; Run from the config root (load-prefer-newer so a stale .elc cannot shadow a
;; source; the elpa directories provide Evil):
;;   emacs -Q --batch --eval '(setq load-prefer-newer t)' \
;;     --eval '(let ((default-directory "<elpa>/")) (normal-top-level-add-subdirs-to-load-path))' \
;;     -l lisp/keys/test/my-keys-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(setq evil-want-keybinding nil)
(require 'evil)

(defconst my-keys-test--root
  (expand-file-name "../../.." (file-name-directory (or load-file-name buffer-file-name))))

(defun my-keys-test--load (file)
  (load (expand-file-name (concat "lisp/" file) my-keys-test--root) nil t))

;; The prefs module and the three key modules.  `use-package' forms in
;; my-keys-evil.el would load the whole Evil ecosystem, so stub the macro while
;; that one file loads: only its plain functions and options are under test.
(my-keys-test--load "ui/my-ui-prefs.el")
(let ((orig (and (fboundp 'use-package) (symbol-function 'use-package))))
  (unwind-protect
      (progn (defmacro use-package (&rest _) nil)
             (my-keys-test--load "keys/my-keys-evil.el"))
    (if orig (fset 'use-package orig) (fmakunbound 'use-package))))
(my-keys-test--load "keys/my-keys-dsl.el")
(my-keys-test--load "keys/my-keys-jumps.el")
(my-keys-test--load "keys/my-keys-table.el")

(defmacro my-keys-test--with-prefs (&rest body)
  "Run BODY with an empty, private saved-settings file."
  (declare (indent 0))
  `(let ((my/ui-prefs-file (make-temp-file "ezprefs" nil ".eld")))
     (delete-file my/ui-prefs-file)
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file my/ui-prefs-file)))))

;;;; Evil toggle persistence

(ert-deftest my-keys-evil-startup-follows-the-option-until-you-have-toggled ()
  (my-keys-test--with-prefs
    (let ((my/evil-enabled t))   (should (my/evil--startup-enabled-p)))
    (let ((my/evil-enabled nil)) (should-not (my/evil--startup-enabled-p)))))

(ert-deftest my-keys-evil-your-last-toggle-beats-the-option ()
  (my-keys-test--with-prefs
    (my/ui-pref-save :evil 'off)
    (let ((my/evil-enabled t))   (should-not (my/evil--startup-enabled-p)))
    (my/ui-pref-save :evil 'on)
    (let ((my/evil-enabled nil)) (should (my/evil--startup-enabled-p)))))

(ert-deftest my-keys-evil-toggle-saves-the-new-state-and-leaves-other-settings ()
  (my-keys-test--with-prefs
    (my/ui-pref-save :font "Some Font")
    (let ((was evil-mode) (inhibit-message t))
      (unwind-protect
          (progn
            (evil-mode -1)
            (my/evil-toggle)                                  ; off -> on
            (should evil-mode)
            (should (eq (my/ui-pref :evil) 'on))
            (my/evil-toggle)                                  ; on -> off
            (should-not evil-mode)
            (should (eq (my/ui-pref :evil) 'off))
            ;; and the next start would follow it
            (let ((my/evil-enabled t)) (should-not (my/evil--startup-enabled-p)))
            (should (equal (my/ui-pref :font) "Some Font")))
        (evil-mode (if was 1 -1))))))

;;;; Jumps with Evil off

(defmacro my-keys-test--in-file (&rest body)
  "Run BODY in a 60-line file buffer with Evil off, with a fresh jump list."
  (declare (indent 0))
  `(let ((file (make-temp-file "jmp" nil ".txt"
                               (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 1 60) "")))
         (was evil-mode))
     (unwind-protect
         (progn
           (evil-mode -1)
           (find-file file)
           (clrhash evil--jumps-window-jumps)
           (goto-char (point-min))
           ,@body)
       (when (get-file-buffer file)
         (with-current-buffer (get-file-buffer file) (set-buffer-modified-p nil) (kill-buffer)))
       (delete-file file)
       (evil-mode (if was 1 -1)))))

(defun my-keys-test--line () (line-number-at-pos))

(defun my-keys-test--run (command line)
  "Pretend COMMAND is about to run at LINE, then move 20 lines on."
  (goto-char (point-min)) (forward-line (1- line))
  (let ((this-command command)) (my/jump--record))
  (forward-line 20))

(ert-deftest my-keys-jumps-c-o-and-c-i-walk-back-and-forward-with-evil-off ()
  (my-keys-test--in-file
    (my-keys-test--run 'xref-find-definitions 5)      ; M-. at line 5, lands on 25
    (my-keys-test--run 'isearch-forward 25)           ; C-s at line 25, lands on 45
    (should (= (my-keys-test--line) 45))
    (call-interactively (key-binding (kbd "C-c o")))
    (should (= (my-keys-test--line) 25))
    (call-interactively (key-binding (kbd "C-c o")))
    (should (= (my-keys-test--line) 5))
    (call-interactively (key-binding (kbd "C-c i")))   ; forward, the terminal-safe alias
    (should (= (my-keys-test--line) 25))
    (call-interactively (key-binding (kbd "C-c i")))
    (should (= (my-keys-test--line) 45))))

(ert-deftest my-keys-jumps-ordinary-motion-is-not-a-jump ()
  (my-keys-test--in-file
    (my-keys-test--run 'xref-find-definitions 3)      ; one real jump, starts on 3, lands on 23
    (my-keys-test--run 'next-line 23)                 ; plain motion: not recorded
    (my-keys-test--run 'forward-char 43)              ; plain motion: not recorded
    ;; the only stop in the list is where the one real jump started
    (let ((inhibit-message t))
      (call-interactively #'evil-jump-backward)
      (should (= (my-keys-test--line) 3))
      (call-interactively #'evil-jump-backward)       ; nothing earlier: stays put
      (should (= (my-keys-test--line) 3)))))

(ert-deftest my-keys-jumps-every-listed-command-is-tagged ()
  (dolist (cmd my/jump-commands)
    (should (evil-get-command-property cmd :jump)))
  (dolist (cmd '(xref-find-definitions xref-go-back isearch-forward isearch-backward
                 isearch-forward-regexp beginning-of-buffer end-of-buffer goto-line
                 consult-line avy-goto-char-timer next-error find-file))
    (should (memq cmd my/jump-commands))))

(ert-deftest my-keys-jumps-the-hook-leaves-buffers-to-evils-own-hook ()
  "Where Evil's `evil--jump-hook' runs, ours must not record a second time."
  (my-keys-test--in-file
    (let ((calls 0))
      (cl-letf (((symbol-function 'evil-set-jump) (lambda (&rest _) (cl-incf calls))))
        (let ((this-command 'xref-find-definitions))
          (let ((evil-local-mode t)) (my/jump--record))
          (should (= calls 0))
          (let ((evil-local-mode nil)) (my/jump--record))
          (should (= calls 1)))
        (let ((this-command 'next-line) (evil-local-mode nil)) (my/jump--record))
        (should (= calls 1))))))

(ert-deftest my-keys-jumps-never-fire-in-the-minibuffer ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'evil-set-jump) (lambda (&rest _) (cl-incf calls)))
              ((symbol-function 'minibufferp) (lambda (&rest _) t)))
      (let ((this-command 'isearch-forward) (evil-local-mode nil)) (my/jump--record)))
    (should (= calls 0))))

;;;; Keys

(ert-deftest my-keys-jumps-bindings ()
  (should-not (eq (key-binding (kbd "C-o")) 'evil-jump-backward))   ; open-line stays
  (should (eq (key-binding (kbd "C-c o")) 'evil-jump-backward))
  (should (eq (key-binding (kbd "C-c i")) 'evil-jump-forward))
  ;; Tab itself is untouched
  (should-not (eq (key-binding (kbd "TAB")) 'evil-jump-forward))
  (should-not (eq (key-binding (kbd "<tab>")) 'evil-jump-forward)))

;;;; The my/bind DSL

(defmacro my-keys-test--dsl (&rest body)
  "Run BODY with a private registry, claims table, leader stub and keymaps."
  (declare (indent 0))
  `(let ((my/bind--table nil)
         (my/bind--claims (make-hash-table :test #'equal))
         (leader nil)
         (global-map (make-sparse-keymap)))
     (cl-letf (((symbol-function 'my/leader)
                (lambda (key spec) (push (cons key spec) leader)))
               ((symbol-function 'evil-global-set-key)
                (lambda (state key cmd) (push (list state key cmd) leader))))
       ,@body)))

(ert-deftest my-keys-dsl-g-expands-to-evil-g-and-emacs-c-c-g ()
  (my-keys-test--dsl
    (my/bind (xref-find-definitions :g "d"))
    (should (equal (my/bind-evil-keys 'xref-find-definitions) '("g d")))
    (should (equal (my/bind-emacs-keys 'xref-find-definitions) '("C-c g d")))
    (should (eq (lookup-key global-map (kbd "C-c g d")) 'xref-find-definitions))))

(ert-deftest my-keys-dsl-evil-emacs-and-both ()
  (my-keys-test--dsl
    (my/bind (a :evil "K" :emacs "C-c g k")
             (b :both "C-c +")
             (c :emacs ("C-o" "C-c o")))
    (should (equal (my/bind-evil-keys 'a) '("K")))
    (should (equal (my/bind-emacs-keys 'a) '("C-c g k")))
    (should (equal (my/bind-evil-keys 'b) '("C-c +")))
    (should (equal (my/bind-emacs-keys 'b) '("C-c +")))
    (should (equal (my/bind-emacs-keys 'c) '("C-o" "C-c o")))
    (should (eq (lookup-key global-map (kbd "C-c o")) 'c))))

(ert-deftest my-keys-dsl-key-with-function-key-form-is-accepted ()
  (my-keys-test--dsl
    (my/bind (a :emacs "C-<f5>"))
    (should (eq (lookup-key global-map [C-f5]) 'a))))

(ert-deftest my-keys-dsl-leader-and-defaults ()
  (my-keys-test--dsl
    (my/bind :states (normal visual)
      (a :leader "t F" :doc "font"))
    (should (equal (caar leader) "t F"))
    (should (equal (cdr (car leader)) '(a :wk "font")))))

(ert-deftest my-keys-dsl-evil-states-are-passed-on ()
  (my-keys-test--dsl
    (let (seen)
      (cl-letf (((symbol-function 'evil-define-key*)
                 (lambda (states _map key cmd) (push (list states key cmd) seen)))
                ((symbol-function 'evil-global-set-key)
                 (lambda (state key cmd) (push (list state key cmd) seen))))
        (my/bind :states (normal visual) (a :evil "gx"))
        (should (member '(visual "gx" a) seen))
        (should (member '(normal "gx" a) seen))))))

(ert-deftest my-keys-dsl-evil-map-waits-for-the-feature ()
  (my-keys-test--dsl
    (defvar my-keys-test--map (make-sparse-keymap))
    (let (seen)
      (cl-letf (((symbol-function 'evil-define-key*)
                 (lambda (&rest args) (push args seen))))
        (my/bind :after my-keys-test-feature
          (a :evil "] z" :evil-map my-keys-test--map :emacs "C-c g z"))
        (should-not seen)                                         ; map not ready yet
        (should (eq (lookup-key global-map (kbd "C-c g z")) 'a))  ; Emacs side is immediate
        (provide 'my-keys-test-feature)
        (should seen)))))

(ert-deftest my-keys-dsl-two-commands-on-one-key-warn ()
  (my-keys-test--dsl
    (let (warned)
      (cl-letf (((symbol-function 'display-warning) (lambda (&rest a) (push a warned))))
        (my/bind (a :emacs "C-c g q") (b :emacs "C-c g q"))
        (should (= (length warned) 1))
        (my/bind (b :emacs "C-c g q"))                         ; the current owner again: fine
        (should (= (length warned) 1))))))

(ert-deftest my-keys-dsl-bad-input-is-a-clear-error ()
  (my-keys-test--dsl
    (should-error (my/bind (a :nonsense "x")) :type 'error)
    (should-error (my/bind ("not-a-command" :g "x")) :type 'error)))

(ert-deftest my-keys-dsl-describe-lists-every-declaration ()
  (my-keys-test--dsl
    (my/bind (a :g "d" :doc "alpha") (b :leader "t b"))
    (let ((rows (my/bind--rows)))
      (should (= (length rows) 2))
      (should (member "a" (mapcar #'car rows))))))

(ert-deftest my-keys-real-bindings-from-the-converted-modules ()
  "The real my-keys-table.el declarations are bound (it loaded above)."
  (should (eq (key-binding (kbd "C-c g c")) 'comment-dwim))
  (should (eq (key-binding (kbd "C-c g m")) 'iedit-mode))
  (should (eq (key-binding (kbd "C-c +")) 'evil-numbers/inc-at-pt)))

(provide 'my-keys-test)
;;; my-keys-test.el ends here
