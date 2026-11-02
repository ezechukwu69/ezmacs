;;; ez-modeline-test.el --- Tests for ez-modeline -*- lexical-binding: t; -*-

;; Run from the config root.  `load-prefer-newer' matters: build output (.elc)
;; from older code may sit next to the sources, and a bare `emacs -Q' would load
;; it instead of the source you just edited.
;;   emacs -Q --batch --eval '(setq load-prefer-newer t)' -L lisp/custom-plugins/ez-modeline \
;;     -l lisp/custom-plugins/ez-modeline/test/ez-modeline-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ez-modeline)

(defvar evil-state nil)
(defvar evil-local-mode nil)
(defvar flymake-mode nil)
(defvar envrc-mode nil)
(defvar envrc--status nil)
(defvar vc-mode nil)
(defvar ez-modeline-test--info "")   ; stands in for a package's modeline variable

(defmacro ez-modeline-test--render (width selected &rest body)
  "Run BODY (default: render) as a WIDTH-column window, SELECTED or not."
  (declare (indent 2))
  `(let ((ez-modeline--use-align nil))
     (cl-letf (((symbol-function 'window-width) (lambda (&rest _) ,width))
               ((symbol-function 'mode-line-window-selected-p) (lambda () ,selected)))
       ,@(or body '((ez-modeline--render))))))

(defun ez-modeline-test--text (s) (substring-no-properties s))

(defun ez-modeline-test--display-p ()
  "Non-nil when `format-mode-line' works: it needs a live display, so not in batch."
  (not (string-empty-p (format-mode-line "x"))))

(defmacro ez-modeline-test--in-window (&rest body)
  "Run BODY in a temp buffer that the selected window shows.
`format-mode-line' evaluates in the window's buffer, as it is during redisplay."
  (declare (indent 0))
  `(with-temp-buffer
     (save-window-excursion
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

;;;; Rendering

(ert-deftest ez-modeline-render-fills-exactly-the-window-width ()
  (with-temp-buffer
    (dolist (w '(60 80 120 200))
      (should (= w (string-width (ez-modeline-test--text (ez-modeline-test--render w t))))))))

(ert-deftest ez-modeline-render-with-align-uses-a-display-space-not-padding ()
  (with-temp-buffer
    (let* ((ez-modeline--use-align t)
           (s (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100))
                       ((symbol-function 'mode-line-window-selected-p) (lambda () t)))
                (ez-modeline--render))))
      (should (cl-some (lambda (i) (let ((d (get-text-property i 'display s)))
                                     (and (consp d) (eq (car d) 'space) (plist-get (cdr d) :align-to))))
                       (number-sequence 0 (1- (length s))))))))

(ert-deftest ez-modeline-inactive-windows-are-greyed-and-lose-the-state-tag ()
  (with-temp-buffer
    (let ((evil-local-mode t) (evil-state 'normal))
      (let ((on (ez-modeline-test--render 100 t))
            (off (ez-modeline-test--render 100 nil)))
        (should (string-match-p " N " (ez-modeline-test--text on)))
        (should-not (string-match-p " N " (ez-modeline-test--text off)))
        (should (memq 'ez-modeline-inactive (ensure-list (get-text-property 5 'face off))))))))

(ert-deftest ez-modeline-a-failing-segment-does-not-break-the-rest ()
  (ez-modeline-define-segment test-boom "Always fails." (error "Boom"))
  (ez-modeline-define-segment test-fine "Fine." "fine-text")
  (with-temp-buffer
    (let ((ez-modeline-left '(test-boom test-fine)) (ez-modeline-right nil))
      (let ((s (ez-modeline-test--render 80 t)))
        (should (string-match-p "⚠test-boom" (ez-modeline-test--text s)))
        (should (string-match-p "fine-text" (ez-modeline-test--text s)))
        (should (string-match-p "Boom" (get-text-property (string-match "⚠" s) 'help-echo s)))))))

(ert-deftest ez-modeline-unknown-and-empty-segments-are-skipped ()
  (ez-modeline-define-segment test-empty "Nothing." nil)
  (with-temp-buffer
    (let ((ez-modeline-left '(no-such-segment test-empty)) (ez-modeline-right nil))
      (should (equal (string-trim (ez-modeline-test--text (ez-modeline-test--render 40 t))) "")))))

(ert-deftest ez-modeline-the-least-important-right-segments-go-first ()
  (ez-modeline-define-segment test-a "A." "AAAAAAAAAA")
  (ez-modeline-define-segment test-b "B." "BBBBBBBBBB")
  (ez-modeline-define-segment test-c "C." "CCCCCCCCCC")
  (with-temp-buffer
    (let ((ez-modeline-left nil) (ez-modeline-right '(test-a test-b test-c))
          (ez-modeline-priority '((test-a . 10) (test-b . 90) (test-c . 50))))
      ;; room for two of three (10 + 2 + 10 = 22 columns, plus the margins)
      (let ((s (ez-modeline-test--text (ez-modeline-test--render 28 t))))
        (should-not (string-match-p "A" s))
        (should (string-match-p "B" s))
        (should (string-match-p "C" s))
        (should (< (string-match "B" s) (string-match "C" s))))   ; order kept
      ;; room for one: only the most important
      (let ((s (ez-modeline-test--text (ez-modeline-test--render 20 t))))
        (should (string-match-p "B" s))
        (should-not (string-match-p "[AC]" s))))))

;;;; Segments

(ert-deftest ez-modeline-evil-state-tag ()
  (with-temp-buffer
    (let ((ez-modeline--active t) (evil-local-mode t))
      (dolist (case '((normal . " N ") (insert . " I ") (visual . " V ") (emacs . " E ")))
        (let* ((evil-state (car case)) (s (ez-modeline-segment--state)))
          (should (equal (ez-modeline-test--text s) (cdr case)))
          (should (eq (get-text-property 1 'face s)
                      (intern (format "ez-modeline-state-%s" (car case)))))))
      (let ((evil-local-mode nil)) (should-not (ez-modeline-segment--state))))))

(ert-deftest ez-modeline-buffer-shows-project-relative-path-and-marks ()
  (let* ((root (file-name-as-directory (make-temp-file "ezm-proj" t)))
         (file (expand-file-name "src/ui/main.el" root))
         (project-find-functions (list (lambda (_d) (cons 'transient root)))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "x"))
          (with-current-buffer (find-file-noselect file)
            (let ((ez-modeline-icons nil))
              (let ((s (ez-modeline-test--render 140 t (ez-modeline-segment--buffer))))
                (should (string-match-p "src/ui/main\\.el" (ez-modeline-test--text s)))
                (should-not (string-match-p "ezm-proj" (ez-modeline-test--text s)))
                (should-not (string-match-p "●" (ez-modeline-test--text s))))
              (insert "more")
              (should (string-match-p "●" (ez-modeline-test--text (ez-modeline-test--render 140 t (ez-modeline-segment--buffer)))))
              (set-buffer-modified-p nil)
              (setq buffer-read-only t)
              (should (string-match-p "RO" (ez-modeline-test--text (ez-modeline-test--render 140 t (ez-modeline-segment--buffer)))))
              (setq buffer-read-only nil)
              (widen) (narrow-to-region 1 1)
              (should (string-match-p "narrowed" (ez-modeline-test--text (ez-modeline-test--render 140 t (ez-modeline-segment--buffer)))))
              (widen)
              (set-visited-file-name (expand-file-name "src/other.el" root))
              (should (string-match-p "src/other\\.el" (ez-modeline-test--text (ez-modeline-test--render 140 t (ez-modeline-segment--buffer))))))
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-directory root t))))

(ert-deftest ez-modeline-buffer-without-a-file-is-just-the-name ()
  (with-temp-buffer
    (rename-buffer "*my-special*" t)
    (let ((ez-modeline-icons nil))
      (should (string-match-p "\\`\\*my-special\\*" (ez-modeline-test--text (ez-modeline-segment--buffer)))))))

(ert-deftest ez-modeline-long-folders-are-shortened-from-the-left ()
  (should (equal (ez-modeline--shorten-dir "a/b/" 10) "a/b/"))
  (let ((s (ez-modeline--shorten-dir "very/long/path/to/some/folder/" 18)))
    (should (string-prefix-p "…/" s))
    (should (string-suffix-p "folder/" s))
    (should (<= (string-width s) 18)))
  (should (null (ez-modeline--shorten-dir "very/long/" 2)))
  (should (null (ez-modeline--shorten-dir nil 10))))

(ert-deftest ez-modeline-vc-branch-and-edited-colour ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/ezm-fake.el")
    (unwind-protect
        (let ((ez-modeline-icons nil))
          (let* ((vc-mode " Git-main") (s (ez-modeline-segment--vc))
                 (pos (string-match "main" s)))
            (should (string-match-p "main" s))
            (should (eq (get-text-property pos 'face s) 'ez-modeline-accent)))
          (let* ((vc-mode " Git:feature/x") (s (ez-modeline-segment--vc))
                 (pos (string-match "feature/x" s)))
            (should (eq (get-text-property pos 'face s) 'ez-modeline-warn)))
          (let ((vc-mode nil)) (should-not (ez-modeline-segment--vc))))
      (setq buffer-file-name nil))))

(ert-deftest ez-modeline-selection-and-macro ()
  (with-temp-buffer
    (insert "hello\nworld\n")
    (let ((ez-modeline--active t))
      (should-not (ez-modeline-segment--selection))
      (set-mark 1) (goto-char 5) (activate-mark)
      (should (equal (ez-modeline-test--text (ez-modeline-segment--selection)) "4 chars"))
      (goto-char 10)
      (should (string-match-p "2 lines" (ez-modeline-segment--selection)))
      (let ((ez-modeline--active nil)) (should-not (ez-modeline-segment--selection))))
    (should-not (ez-modeline-segment--macro))
    (let ((defining-kbd-macro t)) (should (string-match-p "REC" (ez-modeline-segment--macro))))))

(ert-deftest ez-modeline-shows-what-other-packages-put-in-the-modeline ()
  (skip-unless (ez-modeline-test--display-p))
  (ez-modeline-test--in-window
    (let ((mode-line-process '(":run"))
          (global-mode-string '("clock 10:00 "))
          ;; the construct reads this variable dynamically, like a real package's
          (mode-line-misc-info '(("" ez-modeline-test--info) (global-mode-string ("" global-mode-string))))
          (ez-modeline-test--info "long-lines"))
      (should (equal (ez-modeline-test--text (ez-modeline-segment--process)) ":run"))
      (let ((misc (ez-modeline-test--text (ez-modeline-segment--misc))))
        (should (string-match-p "clock 10:00" misc))
        (should (string-match-p "long-lines" misc)))
      (let ((mode-line-process nil)) (should-not (ez-modeline-segment--process))))))

(ert-deftest ez-modeline-misc-leaves-out-flymake-and-eglot-entries ()
  (skip-unless (ez-modeline-test--display-p))
  (ez-modeline-test--in-window
    (let ((flymake-mode t) (fm-fmt "FLYMAKE-STOCK") (eg-fmt "EGLOT-STOCK") (eglot--managed-mode t)
          (global-mode-string '("clock "))
          (mode-line-misc-info '((flymake-mode fm-fmt) (eglot--managed-mode eg-fmt)
                                 (global-mode-string ("" global-mode-string)))))
      (let ((misc (ez-modeline-test--text (ez-modeline-segment--misc))))
        (should (string-match-p "clock" misc))
        (should-not (string-match-p "STOCK" misc))))))

(ert-deftest ez-modeline-checks-count-flymake-diagnostics ()
  (require 'flymake)
  (with-temp-buffer
    (let ((flymake-mode t))
      (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) '(:error :error :warning :note eglot-note)))
                ((symbol-function 'flymake-diagnostic-type) #'identity)
                ((symbol-function 'flymake-running-backends) (lambda () nil)))
        (let ((s (ez-modeline-test--text (ez-modeline-segment--checks))))
          (should (string-match-p "✗ 2" s))
          (should (string-match-p "▲ 1" s))
          (should (string-match-p "● 2" s))))
      (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) nil))
                ((symbol-function 'flymake-diagnostic-type) #'identity)
                ((symbol-function 'flymake-running-backends) (lambda () '(b))))
        (should (equal (string-trim (ez-modeline-test--text (ez-modeline-segment--checks))) "✓ …")))
      (let ((flymake-mode nil)) (should-not (ez-modeline-segment--checks))))))

(ert-deftest ez-modeline-lsp-and-env ()
  (require 'eglot)                       ; the segment only looks once eglot is loaded
  (with-temp-buffer
    (let ((ez-modeline-icons nil))
      (progn
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'srv))
                  ((symbol-function 'eglot-events-buffer) #'ignore))
          (should (string-match-p "LSP" (ez-modeline-test--text (ez-modeline-segment--lsp)))))
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () nil)))
          (should-not (ez-modeline-segment--lsp))))
      (let ((envrc-mode t))
        (let ((envrc--status 'on)) (should (equal (ez-modeline-test--text (ez-modeline-segment--env)) "env")))
        (let ((envrc--status 'error)) (should (string-match-p "✗" (ez-modeline-segment--env))))
        (let ((envrc--status 'none)) (should-not (ez-modeline-segment--env)))))))

(ert-deftest ez-modeline-mode-and-position ()
  (skip-unless (ez-modeline-test--display-p))
  (ez-modeline-test--in-window
    (emacs-lisp-mode)
    (insert "one\ntwo\n") (goto-char 6)
    (should (string-match-p "Emacs-Lisp\\|ELisp" (ez-modeline-test--text (ez-modeline-segment--mode))))
    (should (string-match-p "\\`2:1" (ez-modeline-test--text (ez-modeline-segment--position))))))

;;;; Install, positions, faces

(defmacro ez-modeline-test--sandbox (&rest body)
  "Run BODY leaving the global formats, faces and mode exactly as they were."
  (declare (indent 0))
  `(let ((old-ml (default-value 'mode-line-format))
         (old-hl (default-value 'header-line-format))
         (old-mode ez-modeline-mode)
         (old-pos ez-modeline-position)
         (old-attrs (mapcar (lambda (f) (cons f (face-all-attributes f nil)))
                            '(mode-line mode-line-active mode-line-inactive header-line
                              header-line-active header-line-inactive))))
     (unwind-protect
         (progn ,@body)
       (ez-modeline-mode -1)
       (setq ez-modeline--saved-formats nil ez-modeline--saved-faces nil)
       (setq-default mode-line-format old-ml header-line-format old-hl)
       (setq ez-modeline-position old-pos)
       (dolist (e old-attrs)
         (dolist (a (cdr e)) (set-face-attribute (car e) nil (car a) (cdr a))))
       (when old-mode (ez-modeline-mode 1)))))

(defmacro ez-modeline-test--with-colours (&rest body)
  "Run BODY as if the theme had real colours (batch Emacs has none)."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'ez-modeline--color)
              (lambda (face attr)
                (pcase (list face attr)
                  (`(default :background) "#202020")
                  (`(default :foreground) "#d0d0d0")
                  (`(font-lock-keyword-face :foreground) "#ff8800")))))
     ,@body))

(ert-deftest ez-modeline-blend ()
  (should (equal (ez-modeline--blend "#000000" "#ffffff" 0.0) "#000000"))
  (should (equal (ez-modeline--blend "#000000" "#ffffff" 1.0) "#ffffff"))
  (should (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" (ez-modeline--blend "#102030" "#a0b0c0" 0.3))))

(ert-deftest ez-modeline-blend-is-exact-whatever-the-display-can-show ()
  "A terminal or batch Emacs rounds colours to its palette; hex colours must not be."
  (should (equal (ez-modeline--blend "#190a0f" "#e8d8dc" 0.2) "#423338"))
  (should (string-match-p "\\`#\\(7f7f7f\\|808080\\)\\'" (ez-modeline--blend "#000000" "#ffffff" 0.5)))
  (should (equal (ez-modeline--rgb "#ff0000") '(1.0 0.0 0.0)))
  (should (equal (ez-modeline--blend "#00000000ffff" "#ffffffffffff" 0.0) "#0000ff")))

(ert-deftest ez-modeline-bottom-install-and-uninstall ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq-default mode-line-format '("original-ml") header-line-format '("original-hl"))
      (setq ez-modeline-position 'bottom)
      (ez-modeline-mode 1)
      (should (equal (default-value 'mode-line-format) ez-modeline--format))
      (should (equal (default-value 'header-line-format) '("original-hl")))
      (ez-modeline-mode -1)
      (should (equal (default-value 'mode-line-format) '("original-ml")))
      (should (equal (default-value 'header-line-format) '("original-hl"))))))

(ert-deftest ez-modeline-top-puts-the-modeline-in-the-header-line ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq-default mode-line-format '("original-ml") header-line-format nil)
      (setq ez-modeline-position 'top)
      (ez-modeline-mode 1)
      (should (equal (default-value 'header-line-format) ez-modeline--format))
      (should (null (default-value 'mode-line-format)))
      ;; a buffer with its own header line keeps it
      (with-temp-buffer
        (setq-local header-line-format "my own header")
        (should (equal header-line-format "my own header")))
      (ez-modeline-mode -1)
      (should (equal (default-value 'mode-line-format) '("original-ml")))
      (should (null (default-value 'header-line-format))))))

(ert-deftest ez-modeline-position-can-change-while-on ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq-default mode-line-format '("original-ml") header-line-format nil)
      (setq ez-modeline-position 'bottom)
      (ez-modeline-mode 1)
      (setopt ez-modeline-position 'top)
      (should (equal (default-value 'header-line-format) ez-modeline--format))
      (should (null (default-value 'mode-line-format)))
      (let ((ran nil))
        (add-hook 'ez-modeline-position-changed-hook (lambda () (setq ran t)))
        (ez-modeline-toggle-position)
        (should ran)
        (should (eq ez-modeline-position 'bottom))
        (should (equal (default-value 'mode-line-format) ez-modeline--format))
        (should (null (default-value 'header-line-format)))
        (setq ez-modeline-position-changed-hook nil)))))

(ert-deftest ez-modeline-the-bar-is-an-overline-at-the-bottom-and-an-underline-at-the-top ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq ez-modeline-position 'bottom)
      (ez-modeline-mode 1)
      (should (equal (face-attribute 'mode-line :overline nil) "#ff8800"))      ; accent when selected
      (should (stringp (face-attribute 'mode-line-inactive :overline nil)))
      (should (not (equal (face-attribute 'mode-line-inactive :overline nil) "#ff8800"))) ; dim otherwise
      (should (eq (face-attribute 'mode-line :underline nil) nil))
      (setopt ez-modeline-position 'top)
      (let ((u (face-attribute 'header-line-active :underline nil)))
        (should (equal (plist-get u :color) "#ff8800"))
        (should (eq (plist-get u :position) t)))
      ;; the bar can be turned off
      (setopt ez-modeline-bar nil)
      (should (null (face-attribute 'header-line-active :underline nil)))
      (setopt ez-modeline-bar t))))

(ert-deftest ez-modeline-background-is-the-buffers-own-so-only-the-bar-separates ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (dolist (pos '(bottom top))
        (setopt ez-modeline-position pos)
        (ez-modeline-mode 1)
        (dolist (face (if (eq pos 'top)
                          '(header-line header-line-active header-line-inactive)
                        '(mode-line mode-line-active mode-line-inactive)))
          (should (equal (face-attribute face :background nil) "#202020"))
          ;; the padding is drawn in that same colour, so it is invisible
          (should (equal (plist-get (face-attribute face :box nil) :color) "#202020")))
        (ez-modeline-mode -1)))))

(ert-deftest ez-modeline-padding-is-the-same-above-and-below-and-follows-the-option ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      ;; roomy by default
      (should (= 8 (default-value 'ez-modeline-padding)))
      (dolist (pos '(bottom top))
        (setopt ez-modeline-position pos)
        (ez-modeline-mode 1)
        (let ((faces (if (eq pos 'top)
                         '(header-line header-line-active header-line-inactive)
                       '(mode-line mode-line-active mode-line-inactive))))
          (dolist (n '(8 14 3))
            (setopt ez-modeline-padding n)
            (dolist (face faces)
              ;; (VERTICAL-LINES . HORIZONTAL-LINES): 1px sides, N above and N below
              (should (equal (plist-get (face-attribute face :box nil) :line-width) (cons 1 n)))))
          ;; no padding at all
          (setopt ez-modeline-padding 0)
          (dolist (face faces)
            (should (null (face-attribute face :box nil)))))
        (ez-modeline-mode -1)
        (setopt ez-modeline-padding 8)))))

(ert-deftest ez-modeline-beats-a-theme-that-styles-mode-line-active-itself ()
  "modus / ef themes set `mode-line-active' directly (own colour, variable pitch)."
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (set-face-attribute 'mode-line-active nil :background "#771a4f" :foreground "#ffffff"
                          :inherit 'variable-pitch)
      (ez-modeline-mode 1)
      (should (equal (face-attribute 'mode-line-active :background nil) "#202020"))
      (should (null (face-attribute 'mode-line-active :inherit nil)))        ; fixed pitch again
      (should (equal (face-attribute 'mode-line-active :overline nil) "#ff8800"))
      (ez-modeline-mode -1)
      ;; the theme's own styling comes back untouched
      (should (equal (face-attribute 'mode-line-active :background nil) "#771a4f"))
      (should (eq (face-attribute 'mode-line-active :inherit nil) 'variable-pitch)))))

(ert-deftest ez-modeline-faces-are-restored-when-the-mode-turns-off ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (set-face-attribute 'mode-line nil :background "#123456" :overline nil :box nil)
      (ez-modeline-mode 1)
      (should (not (equal (face-attribute 'mode-line :background nil) "#123456")))
      (ez-modeline-mode -1)
      (should (equal (face-attribute 'mode-line :background nil) "#123456"))
      (should (null (face-attribute 'mode-line :overline nil))))))

(ert-deftest ez-modeline-without-theme-colours-it-leaves-the-faces-alone ()
  (ez-modeline-test--sandbox
    (cl-letf (((symbol-function 'ez-modeline--color) (lambda (&rest _) nil)))
      (set-face-attribute 'mode-line nil :background "#123456")
      (ez-modeline-mode 1)
      (should (equal (face-attribute 'mode-line :background nil) "#123456"))
      (should (equal (default-value 'mode-line-format) ez-modeline--format)))))

(ert-deftest ez-modeline-manage-faces-nil-leaves-the-theme-alone ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (set-face-attribute 'mode-line nil :background "#123456")
      (let ((ez-modeline-manage-faces nil))
        (ez-modeline-mode 1)
        (should (equal (face-attribute 'mode-line :background nil) "#123456"))))))

(ert-deftest ez-modeline-evil-cannot-strand-buffers-with-a-copy-of-the-format ()
  "Evil `setq's `mode-line-format' per buffer; that copy would ignore a later move."
  (skip-unless (require 'evil nil t))
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq-default mode-line-format '("original-ml") header-line-format nil)
      (setq ez-modeline-position 'bottom)
      (ez-modeline-mode 1)
      (with-temp-buffer
        (evil-refresh-mode-line 'normal)
        (should-not (local-variable-p 'mode-line-format)))     ; advised away while on
      (ez-modeline-mode -1)
      (with-temp-buffer
        (evil-refresh-mode-line 'normal)
        (should (local-variable-p 'mode-line-format))))))      ; evil works again once off

(ert-deftest ez-modeline-stale-copies-of-our-format-are-dropped-but-blank-ones-are-kept ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (setq-default mode-line-format '("original-ml") header-line-format nil)
      (setq ez-modeline-position 'bottom)
      (ez-modeline-mode 1)
      (let ((stale (generate-new-buffer " ezm-stale")) (blank (generate-new-buffer " ezm-blank")))
        (unwind-protect
            (progn
              (with-current-buffer stale (setq-local mode-line-format ez-modeline--format))
              (with-current-buffer blank (setq-local mode-line-format nil)) ; e.g. the dashboard
              (setopt ez-modeline-position 'top)
              (with-current-buffer stale (should-not (local-variable-p 'mode-line-format)))
              (with-current-buffer blank
                (should (local-variable-p 'mode-line-format))
                (should (null mode-line-format))))
          (kill-buffer stale) (kill-buffer blank))))))

(ert-deftest ez-modeline-reapplies-faces-when-a-theme-is-enabled ()
  (ez-modeline-test--sandbox
    (ez-modeline-test--with-colours
      (ez-modeline-mode 1)
      (should (memq #'ez-modeline--on-theme enable-theme-functions))
      (let ((count 0))
        (cl-letf (((symbol-function 'ez-modeline--apply-faces) (lambda () (cl-incf count))))
          (ez-modeline--on-theme 'some-theme))
        (should (= count 1)))
      (ez-modeline-mode -1)
      (should-not (memq #'ez-modeline--on-theme enable-theme-functions))
      ;; harmless when the mode is off
      (ez-modeline--on-theme 'some-theme))))

(provide 'ez-modeline-test)
;;; ez-modeline-test.el ends here
