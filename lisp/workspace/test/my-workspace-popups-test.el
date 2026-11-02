;;; my-workspace-popups-test.el --- Tests for the popup commands -*- lexical-binding: t; -*-

;; Run from the config root.  `load-prefer-newer' keeps a stale .elc from
;; shadowing the source; the elpa directories provide popper:
;;   emacs -Q --batch --eval '(setq load-prefer-newer t)' \
;;     --eval '(let ((default-directory "<elpa>/")) (normal-top-level-add-subdirs-to-load-path))' \
;;     -l lisp/workspace/test/my-workspace-popups-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tab-bar)
(require 'use-package)

(defconst my-popups-test--root
  (expand-file-name "../../.." (file-name-directory (or load-file-name buffer-file-name))))

(unless (fboundp 'my/leader) (defun my/leader (&rest _)))
(load (expand-file-name "lisp/workspace/my-workspace-popups.el" my-popups-test--root) nil t)
(tab-bar-mode 1)

(defconst my-popups-test--names '("*Warnings*" "*Compile-Log*" "*grep*"))

(defun my-popups-test--clean-windows ()
  "Back to one ordinary window with no popups showing.
Popper's own bury leaves cloned side windows up in batch, so close them directly."
  (when-let* ((w (cl-find-if-not (lambda (w) (window-parameter w 'window-side)) (window-list))))
    (select-window w))
  (dolist (w (window-list nil 'no-mini))
    (when (and (window-live-p w) (not (one-window-p t))
               (or (window-parameter w 'window-side) (popper-popup-p (window-buffer w))))
      (delete-window w)))
  (ignore-errors (delete-other-windows)))

(defun my-popups-test--clean ()
  "A blank slate: one window, one tab, fresh popups, no remembered state."
  (my-popups-test--clean-windows)
  (setq my/popper--ring nil my/popper--hidden nil)
  (clrhash my/popper--home)
  (while (cdr (funcall tab-bar-tabs-function)) (tab-bar-close-tab))
  ;; popper caches its classification of each buffer: forget it
  (dolist (b (buffer-list)) (with-current-buffer b (setq popper-popup-status nil)))
  (dolist (n my-popups-test--names) (get-buffer-create n)))

(defun my-popups-test--new-tab ()
  "Open a new workspace the way tabspaces does: a fresh tab on *scratch*.
(A bare `tab-bar-new-tab' with a popup selected leaves the new tab showing it.)"
  (select-window (window-main-window))
  (tab-bar-new-tab)
  (switch-to-buffer "*scratch*")
  (my-popups-test--clean-windows))

(defun my-popups-test--show (name)
  "Show popup NAME and record where, as the redisplay hook does in a real session."
  (display-buffer name)
  (my/popper--note-homes))

(defun my-popups-test--hide-all ()
  "Close every popup window (popper's own bury leaves some up in batch)."
  (dolist (w (window-list nil 'no-mini))
    (when (and (popper-popup-p (window-buffer w)) (not (one-window-p t)))
      (delete-window w))))

(defmacro my-popups-test--with-popups (&rest body)
  "Run BODY on a blank slate.  Nothing is logged, so `*Messages*' stays gone."
  (declare (indent 0))
  `(let ((message-log-max nil))
     (my-popups-test--clean)
     (when (get-buffer "*Messages*") (kill-buffer "*Messages*"))
     (unwind-protect (progn ,@body) (my-popups-test--clean))))

(defun my-popups-test--shown ()
  "Names of the popups visible in this workspace, sorted."
  (sort (delq nil (mapcar (lambda (w) (let ((b (window-buffer w)))
                                        (and (popper-popup-p b) (buffer-name b))))
                          (window-list nil 'no-mini)))
        #'string<))

(defun my-popups-test--press (&optional arg)
  (let ((inhibit-message t)) (my/popper-cycle arg))
  (popper--update-popups)
  (my-popups-test--shown))

(defun my-popups-test--only (names)
  "Kill every popup buffer except NAMES."
  (dolist (n '("*Warnings*" "*Compile-Log*" "*grep*" "*Messages*"))
    (unless (member n names) (when (get-buffer n) (kill-buffer n)))))

;;;; Cycling

(ert-deftest my-popups-cycle-visits-every-popup-and-wraps-around ()
  "Popups popper has never seen on screen used to be skipped."
  (my-popups-test--with-popups
    (my-popups-test--show "*Warnings*")
    (let* ((first (my-popups-test--shown))
           (seen (list first)))
      (dotimes (_ 3) (push (my-popups-test--press) seen))
      ;; one popup at a time, and at least three different ones
      (should (cl-every (lambda (s) (= 1 (length s))) seen))
      (should (>= (length (delete-dups (copy-sequence seen))) 3))
      ;; after one full lap the cycle is back where it began
      (let ((n (length (alist-get (my/popper-group) my/popper--ring nil nil #'equal))))
        (dotimes (_ (- n 3)) (my-popups-test--press))
        (should (equal (my-popups-test--shown) first))))))

(ert-deftest my-popups-cycle-order-is-stable-and-backwards-reverses-it ()
  (my-popups-test--with-popups
    (my-popups-test--show "*Warnings*")
    (let ((forward (list (my-popups-test--shown))))
      (dotimes (_ 3) (push (my-popups-test--press) forward))
      (setq forward (nreverse forward))
      ;; walking back retraces the same popups in reverse
      (should (equal (my-popups-test--press -1) (nth 2 forward)))
      (should (equal (my-popups-test--press -1) (nth 1 forward)))
      (should (equal (my-popups-test--press -1) (nth 0 forward)))
      ;; and forward again repeats the original order
      (should (equal (my-popups-test--press) (nth 1 forward))))))

(ert-deftest my-popups-a-lone-popup-stays-open-instead-of-vanishing ()
  (my-popups-test--with-popups
    (my-popups-test--only '("*Warnings*"))
    (my-popups-test--show "*Warnings*")
    (should (equal (my-popups-test--shown) '("*Warnings*")))
    (should (equal (my-popups-test--press) '("*Warnings*")))
    (should (equal (my-popups-test--press) '("*Warnings*")))
    (should (equal (my-popups-test--press -1) '("*Warnings*")))))

(ert-deftest my-popups-cycle-with-nothing-open-shows-the-most-recent-popup ()
  (my-popups-test--with-popups
    (my-popups-test--show "*Compile-Log*")
    (my-popups-test--show "*grep*")
    (my-popups-test--hide-all)
    (should (null (my-popups-test--shown)))
    (should (equal (my-popups-test--press) '("*grep*")))))

(ert-deftest my-popups-cycle-reports-when-there-are-no-popups ()
  (my-popups-test--with-popups
    (my-popups-test--only nil)
    (let (msg)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest a) (setq msg (apply #'format fmt a)))))
        (my/popper-cycle))
      (should (equal msg "No popups in this workspace"))
      (should (null (my-popups-test--shown))))))

;;;; Workspaces

(ert-deftest my-popups-workspaces-keep-their-own-popups ()
  "Opening a popup in one workspace must not move it into another."
  (my-popups-test--with-popups
    (my-popups-test--show "*Warnings*")
    (let ((group-a (my/popper-group)))
      (my-popups-test--new-tab)
      (my-popups-test--show "*grep*")
      (should-not (equal group-a (my/popper-group)))
      ;; in B the cycle never offers what A showed
      (dotimes (_ 5)
        (should-not (member "*Warnings*" (my-popups-test--press))))
      (tab-bar-select-tab 1)
      (my/popper--note-homes)
      ;; and in A it never offers what B showed
      (dotimes (_ 5)
        (should-not (member "*grep*" (my-popups-test--press)))))))

(ert-deftest my-popups-a-popup-nobody-has-shown-is-offered-in-every-workspace ()
  (my-popups-test--with-popups
    (my-popups-test--only '("*Warnings*" "*grep*"))
    (my-popups-test--show "*Warnings*")
    (my-popups-test--new-tab)
    ;; *grep* has never been on screen, so workspace B may use it ...
    (should (equal (my-popups-test--press) '("*grep*")))
    ;; ... and once shown in B it is B's alone
    (tab-bar-select-tab 1) (my/popper--note-homes)
    (dotimes (_ 3) (should-not (member "*grep*" (my-popups-test--press))))))

(ert-deftest my-popups-toggle-hides-and-restores-per-workspace ()
  (my-popups-test--with-popups
    (my-popups-test--show "*Warnings*")
    (let ((inhibit-message t)) (my/popper-toggle))
    (should (null (my-popups-test--shown)))
    (my-popups-test--new-tab)
    (my-popups-test--show "*grep*")
    (let ((inhibit-message t)) (my/popper-toggle))
    (should (null (my-popups-test--shown)))
    ;; back in A the toggle restores A's popup, not B's
    (tab-bar-select-tab 1)
    (let ((inhibit-message t)) (my/popper-toggle))
    (should (equal (my-popups-test--shown) '("*Warnings*")))))

;;;; Ownership as tabspaces reports it

(defvar tabspaces-mode nil)

(defmacro my-popups-test--with-tabspaces (owned &rest body)
  "Run BODY as if tabspaces is on and this workspace owns the buffers named OWNED."
  (declare (indent 1))
  `(let ((tabspaces-mode t))
     (cl-letf (((symbol-function 'tabspaces--local-buffer-p)
                (lambda (b) (member (buffer-name b) ,owned))))
       ,@body)))

(ert-deftest my-popups-with-tabspaces-only-this-workspaces-buffers-are-cycled ()
  "Another project's terminal or log, never shown here, must not appear."
  (my-popups-test--with-popups
    (my-popups-test--only '("*Warnings*" "*Compile-Log*" "*grep*"))
    (my-popups-test--with-tabspaces '("*Warnings*" "*grep*")
      (my-popups-test--show "*Warnings*")
      (let ((seen (list (my-popups-test--shown))))
        (dotimes (_ 4) (push (my-popups-test--press) seen))
        (should (member '("*grep*") seen))
        (should (member '("*Warnings*") seen))
        (should-not (member '("*Compile-Log*") seen))))))

(ert-deftest my-popups-with-tabspaces-shared-buffers-belong-to-every-workspace ()
  (my-popups-test--with-popups
    (my-popups-test--only '("*Warnings*" "*Compile-Log*" "*grep*"))
    ;; *Compile-Log* is listed as shared (like *Messages* in this config)
    (my-popups-test--with-tabspaces '("*Compile-Log*")
      (should (equal (mapcar #'buffer-name (my/popper--candidates)) '("*Compile-Log*")))
      (should (equal (my-popups-test--press) '("*Compile-Log*"))))))

(ert-deftest my-popups-internal-buffers-are-never-cycled ()
  "Space-prefixed buffers (Eglot output, eldoc, ...) match popper's patterns."
  (my-popups-test--with-popups
    (my-popups-test--only '("*Warnings*"))
    (let ((hidden (get-buffer-create " *eldoc*")))
      (unwind-protect
          (progn
            (with-current-buffer hidden (setq popper-popup-status nil))
            (should (popper-popup-p hidden))                      ; popper would count it
            (should-not (memq hidden (my/popper--candidates)))    ; we do not
            (my-popups-test--with-tabspaces '(" *eldoc*" "*Warnings*")
              (should-not (memq hidden (my/popper--candidates)))))
        (kill-buffer hidden)))))

(provide 'my-workspace-popups-test)
;;; my-workspace-popups-test.el ends here
