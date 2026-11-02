;;; ez-modeline.el --- A simple modeline with one separating bar -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A quiet modeline: no boxes, no dividers between segments, one thin bar along
;; the edge where it meets the buffer.  Segments are separated by plain
;; spacing; the selected window shows colour, the others fade to grey.
;;
;; Position: `ez-modeline-position' is `bottom' (the usual mode line, bar on its
;; top edge) or `top' (the header line, bar on its bottom edge).  Set it with
;; `setopt' (a plain `setq' does not move a modeline that is already showing),
;; or flip it with `ez-modeline-toggle-position'.
;;
;; Segments: `ez-modeline-left' and `ez-modeline-right' list segment names; the
;; segment NAME is the function `ez-modeline-segment--NAME', usually defined
;; with `ez-modeline-define-segment' (see ez-modeline-segments.el).  A segment
;; returns a string or nil, and a segment that signals an error is shown as a
;; warning mark instead of breaking the whole modeline.  When the window is too
;; narrow the right-hand segments with the lowest `ez-modeline-priority' go
;; first.
;;
;; Other packages: whatever they put in `mode-line-process', `global-mode-string'
;; and `mode-line-misc-info' (org-clock, display-time, battery, which-function,
;; so-long, ...) appears in the `process' and `misc' segments; flymake and eglot
;; have segments of their own, so their stock entries are filtered out of `misc'
;; (`ez-modeline-misc-exclude').  Buffers that set their own `mode-line-format'
;; or `header-line-format' locally keep it.
;;
;; Faces: with `ez-modeline-manage-faces' the mode and header line faces are
;; recomputed from the current theme (a subtle background, an accent bar) and
;; set directly - not through an overlay theme, so `custom-enabled-themes' stays
;; yours - and the originals come back when the mode is turned off.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)

(defgroup ez-modeline nil
  "A simple modeline with one separating bar."
  :group 'mode-line
  :prefix "ez-modeline-")

(defvar ez-modeline-mode)

(defun ez-modeline--set-reinstall (symbol value)
  "Set SYMBOL to VALUE and redraw the modeline if the mode is on."
  (set-default symbol value)
  (when (bound-and-true-p ez-modeline-mode)
    (ez-modeline--install)))

(defcustom ez-modeline-position 'bottom
  "Where the modeline is drawn: `bottom' (mode line) or `top' (header line).
Use `setopt' or `customize' to change it while the mode is on."
  :type '(choice (const :tag "Bottom, the usual mode line" bottom)
                 (const :tag "Top, the header line" top))
  :set #'ez-modeline--set-reinstall
  :group 'ez-modeline)

(defcustom ez-modeline-left '(state buffer vc selection macro)
  "Segments on the left, in order.  See `ez-modeline-define-segment'."
  :type '(repeat symbol) :set #'ez-modeline--set-reinstall :group 'ez-modeline)

(defcustom ez-modeline-right '(process misc checks lsp env mode position)
  "Segments on the right, in order."
  :type '(repeat symbol) :set #'ez-modeline--set-reinstall :group 'ez-modeline)

(defcustom ez-modeline-priority
  '((position . 100) (checks . 90) (process . 85) (mode . 70)
    (lsp . 60) (env . 40) (misc . 30))
  "How much each right-hand segment matters.
The lowest go first when space runs out; segments not listed count as 50."
  :type '(alist :key-type symbol :value-type integer) :group 'ez-modeline)

(defcustom ez-modeline-bar t
  "Draw the thin bar between the modeline and the buffer."
  :type 'boolean :set #'ez-modeline--set-reinstall :group 'ez-modeline)

(defcustom ez-modeline-padding 8
  "Pixels of empty space above and below the text, each side.
The modeline is taller by twice this.  0 removes the padding; 4 is compact,
8 roomy, 12 airy.  Set it with `setopt' so a modeline already showing updates."
  :type 'integer :set #'ez-modeline--set-reinstall :group 'ez-modeline)

(defcustom ez-modeline-manage-faces t
  "Derive the mode and header line faces from the theme (see the Commentary).
Turn off to use whatever your theme defines."
  :type 'boolean :set #'ez-modeline--set-reinstall :group 'ez-modeline)

(defcustom ez-modeline-icons t
  "Use nerd-icons glyphs where available (plain characters otherwise)."
  :type 'boolean :group 'ez-modeline)

(defcustom ez-modeline-misc-exclude '(flymake-mode eglot--managed-mode)
  "Entries of `mode-line-misc-info' the `misc' segment leaves out.
The default hides what the `checks' and `lsp' segments already show."
  :type '(repeat symbol) :group 'ez-modeline)

;;;; Faces

(defface ez-modeline-buffer '((t :weight bold)) "The file or buffer name." :group 'ez-modeline)
(defface ez-modeline-dim '((t :inherit shadow)) "Secondary text." :group 'ez-modeline)
(defface ez-modeline-accent '((t :inherit font-lock-keyword-face)) "Highlights." :group 'ez-modeline)
(defface ez-modeline-ok '((t :inherit success)) "Good news." :group 'ez-modeline)
(defface ez-modeline-warn '((t :inherit warning)) "Unsaved changes and warnings." :group 'ez-modeline)
(defface ez-modeline-bad '((t :inherit error)) "Errors." :group 'ez-modeline)
(defface ez-modeline-inactive '((t :inherit shadow :weight normal))
  "Everything in a window that is not selected." :group 'ez-modeline)

(defface ez-modeline-state-normal
  '((t :inherit font-lock-keyword-face :inverse-video t :weight bold))
  "Evil normal state." :group 'ez-modeline)
(defface ez-modeline-state-insert
  '((t :inherit success :inverse-video t :weight bold)) "Evil insert state." :group 'ez-modeline)
(defface ez-modeline-state-visual
  '((t :inherit warning :inverse-video t :weight bold)) "Evil visual state." :group 'ez-modeline)
(defface ez-modeline-state-replace
  '((t :inherit error :inverse-video t :weight bold)) "Evil replace state." :group 'ez-modeline)
(defface ez-modeline-state-emacs
  '((t :inherit font-lock-builtin-face :inverse-video t :weight bold))
  "Evil Emacs state." :group 'ez-modeline)
(defface ez-modeline-state-motion
  '((t :inherit font-lock-type-face :inverse-video t :weight bold))
  "Evil motion state." :group 'ez-modeline)

;;;; Segments

(defvar ez-modeline--active t
  "Non-nil while drawing the modeline of the selected window.")

(defvar ez-modeline--use-align t
  "Non-nil: right-align with an `:align-to' space; tests use real spaces instead.")

(defmacro ez-modeline-define-segment (name doc &rest body)
  "Define the segment NAME.  BODY returns a string, or nil to show nothing.
DOC documents it.  Add NAME to `ez-modeline-left' or `ez-modeline-right'."
  (declare (indent 2) (doc-string 2))
  `(defun ,(intern (format "ez-modeline-segment--%s" name)) () ,doc ,@body))

(defun ez-modeline--segment (name)
  "The string of segment NAME, nil when it has nothing to show or does not exist."
  (let ((fn (intern-soft (format "ez-modeline-segment--%s" name))))
    (when (and fn (fboundp fn))
      (condition-case err
          (let ((s (funcall fn))) (and (stringp s) (not (string-empty-p s)) s))
        (error (propertize (format "⚠%s" name) 'face 'ez-modeline-bad
                           'help-echo (format "ez-modeline segment %s: %s" name
                                              (error-message-string err))))))))

(defun ez-modeline--collect (names)
  "Alist (NAME . STRING) for the segments in NAMES that have something to show."
  (cl-loop for n in names
           for s = (ez-modeline--segment n)
           when s collect (cons n s)))

(defconst ez-modeline--gap "  " "Plain spacing between segments.")

(defun ez-modeline--width (items)
  "Columns ITEMS (alist NAME . STRING) take once joined."
  (if items
      (+ (apply #'+ (mapcar (lambda (i) (string-width (cdr i))) items))
         (* (string-width ez-modeline--gap) (1- (length items))))
    0))

(defun ez-modeline--join (items)
  "The strings of ITEMS (alist NAME . STRING) joined with the segment gap."
  (mapconcat #'cdr items ez-modeline--gap))

(defun ez-modeline--priority (name)
  "How much segment NAME matters when space is short."
  (or (alist-get name ez-modeline-priority) 50))

(defun ez-modeline--fit (items budget)
  "ITEMS without the least important ones, so they fit in BUDGET columns."
  (let ((keep (copy-sequence items)))
    (while (and keep (> (ez-modeline--width keep) budget))
      (let ((victim (cl-reduce (lambda (a b) (if (< (ez-modeline--priority (car a))
                                                    (ez-modeline--priority (car b)))
                                                 a b))
                               keep)))
        (setq keep (delq victim keep))))
    keep))

(defun ez-modeline--render ()
  "The modeline text for the window being drawn."
  (let* ((ez-modeline--active (mode-line-window-selected-p))
         (width (window-width))
         (left-items (ez-modeline--collect ez-modeline-left))
         (left (ez-modeline--join left-items))
         (budget (- width 4 (string-width left)))
         (right-items (ez-modeline--fit (ez-modeline--collect ez-modeline-right) budget))
         (right (ez-modeline--join right-items))
         (rw (string-width right))
         (gap (if ez-modeline--use-align
                  (propertize " " 'display `(space :align-to (- right ,(1+ rw))))
                (make-string (max 1 (- width 2 (string-width left) rw)) ?\s)))
         (line (concat " " left gap right " ")))
    (unless ez-modeline--active
      (add-face-text-property 0 (length line) 'ez-modeline-inactive nil line))
    line))

(defconst ez-modeline--format '("%e" (:eval (ez-modeline--render)))
  "The `mode-line-format' / `header-line-format' this mode installs.")

;;;; Colours and faces

(defun ez-modeline--color (face attr)
  "A usable colour for ATTR of FACE, or nil (unspecified, or not a real colour)."
  (let ((c (face-attribute face attr nil 'default)))
    (and (stringp c) (not (string-prefix-p "unspecified" c)) (color-defined-p c) c)))

(defun ez-modeline--rgb (color)
  "COLOR as a list of three floats 0..1.
\"#rrggbb\" and \"#rrrrggggbbbb\" are parsed exactly: `color-name-to-rgb' rounds
them to the display's palette on terminals and in batch Emacs."
  (cond
   ((string-match "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'" color)
    (mapcar (lambda (i) (/ (string-to-number (match-string i color) 16) 255.0)) '(1 2 3)))
   ((string-match "\\`#\\([[:xdigit:]]\\{4\\}\\)\\([[:xdigit:]]\\{4\\}\\)\\([[:xdigit:]]\\{4\\}\\)\\'" color)
    (mapcar (lambda (i) (/ (string-to-number (match-string i color) 16) 65535.0)) '(1 2 3)))
   (t (color-name-to-rgb color))))

(defun ez-modeline--blend (from to ratio)
  "The colour RATIO (0..1) of the way from FROM to TO."
  (let ((a (ez-modeline--rgb from)) (b (ez-modeline--rgb to)))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (x y) (+ x (* ratio (- y x)))) a b) '(2)))))

(defconst ez-modeline--face-attrs '(:foreground :background :box :overline :underline :weight :inherit))

(defvar ez-modeline--saved-faces nil
  "Alist FACE -> original attributes, taken before the first override.")

(defun ez-modeline--managed-faces ()
  "The mode and header line faces that exist in this Emacs."
  ;; `mode-line-active' matters: modus/ef style themes set it directly, so it
  ;; beats whatever is set on `mode-line' for the selected window.
  (cl-remove-if-not #'facep '(mode-line mode-line-active mode-line-inactive header-line
                              header-line-active header-line-inactive)))

(defun ez-modeline--save-faces ()
  "Remember the faces' own attributes, once, so they can come back."
  (unless ez-modeline--saved-faces
    (setq ez-modeline--saved-faces
          (mapcar (lambda (f)
                    (cons f (mapcar (lambda (a) (cons a (face-attribute f a nil)))
                                    ez-modeline--face-attrs)))
                  (ez-modeline--managed-faces)))))

(defun ez-modeline--restore-faces ()
  "Put back the attributes saved by `ez-modeline--save-faces'."
  (dolist (entry ez-modeline--saved-faces)
    (dolist (attr (cdr entry))
      (set-face-attribute (car entry) nil (car attr) (cdr attr))))
  (setq ez-modeline--saved-faces nil))

(defun ez-modeline--face-plan ()
  "Plist (:on ATTRS :off ATTRS) for the current theme, or nil without real colours."
  (let ((bg (ez-modeline--color 'default :background))
        (fg (ez-modeline--color 'default :foreground)))
    (when (and bg fg)
      (let* ((accent (or (ez-modeline--color 'font-lock-keyword-face :foreground) fg))
             ;; Same background as the buffer: the bar is the only separator.
             (bg-on bg)
             (bg-off bg)
             (fg-off (ez-modeline--blend fg bg 0.45))
             (bar-on accent)
             (bar-off (ez-modeline--blend bg fg 0.2))
             (top (eq ez-modeline-position 'top))
             ;; (VERTICAL-LINES . HORIZONTAL-LINES): the side lines must be at
             ;; least 1px (0 is invalid), drawn in the background colour so
             ;; they vanish; the horizontal ones are the padding above and below.
             (box (lambda (c) (when (> ez-modeline-padding 0)
                                (list :line-width (cons 1 ez-modeline-padding) :color c))))
             (edge (lambda (c) (if (not ez-modeline-bar)
                                   (list :overline nil :underline nil)
                                 (if top
                                     (list :overline nil :underline (list :color c :position t))
                                   (list :overline c :underline nil))))))
        (list :on (append (list :foreground fg :background bg-on :weight 'normal :inherit nil
                                :box (funcall box bg-on))
                          (funcall edge bar-on))
              :off (append (list :foreground fg-off :background bg-off :weight 'normal :inherit nil
                                 :box (funcall box bg-off))
                           (funcall edge bar-off)))))))

(defun ez-modeline--apply-faces ()
  "Set the mode and header line faces from the theme (or restore them)."
  (ez-modeline--restore-faces)
  (when ez-modeline-manage-faces
    (when-let* ((plan (ez-modeline--face-plan)))
      (ez-modeline--save-faces)
      (let ((on (plist-get plan :on)) (off (plist-get plan :off))
            (top (eq ez-modeline-position 'top)))
        (dolist (f (if top '(header-line header-line-active) '(mode-line mode-line-active)))
          (when (facep f) (apply #'set-face-attribute f nil on)))
        (dolist (f (if top '(header-line-inactive) '(mode-line-inactive)))
          (when (facep f) (apply #'set-face-attribute f nil off)))))))

(defun ez-modeline--on-theme (&optional _theme)
  "Recompute the faces after a theme was enabled."
  (when (bound-and-true-p ez-modeline-mode)
    (ez-modeline--apply-faces)
    (force-mode-line-update t)))

;;;; Install

(defvar ez-modeline--saved-formats nil
  "The default `mode-line-format' and `header-line-format' from before.")

(defun ez-modeline--evil-refresh (orig &rest args)
  "Around advice for Evil's `evil-refresh-mode-line' while this mode is on.
Evil places its state tag by `setq'-ing `mode-line-format' in each buffer, which
makes the variable buffer-local with a copy of the global value; those copies
then ignore a later move of the modeline.  The `state' segment shows the tag,
so only ask for a redraw here.  ORIG and ARGS are the original call."
  (if ez-modeline-mode
      (force-mode-line-update)
    (apply orig args)))

(defun ez-modeline--drop-stale-copies ()
  "Forget buffer-local copies of our own format so the global one applies again."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (and (local-variable-p 'mode-line-format) (eq mode-line-format ez-modeline--format))
        (kill-local-variable 'mode-line-format))
      (when (and (local-variable-p 'header-line-format) (eq header-line-format ez-modeline--format))
        (kill-local-variable 'header-line-format)))))

(defun ez-modeline--install ()
  "Put the modeline where `ez-modeline-position' says, and (re)apply the faces."
  (ez-modeline--drop-stale-copies)
  (unless ez-modeline--saved-formats
    (setq ez-modeline--saved-formats
          (list (default-value 'mode-line-format) (default-value 'header-line-format))))
  (if (eq ez-modeline-position 'top)
      (setq-default mode-line-format nil
                    header-line-format ez-modeline--format)
    (setq-default mode-line-format ez-modeline--format
                  header-line-format (nth 1 ez-modeline--saved-formats)))
  (ez-modeline--apply-faces)
  (force-mode-line-update t))

(defun ez-modeline--uninstall ()
  "Restore the formats and faces from before the mode was turned on."
  (ez-modeline--drop-stale-copies)
  (when ez-modeline--saved-formats
    (setq-default mode-line-format (nth 0 ez-modeline--saved-formats)
                  header-line-format (nth 1 ez-modeline--saved-formats))
    (setq ez-modeline--saved-formats nil))
  (ez-modeline--restore-faces)
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode ez-modeline-mode
  "A simple modeline with one separating bar; see ez-modeline.el."
  :global t :group 'ez-modeline
  (if ez-modeline-mode
      (progn (ez-modeline--install)
             (add-hook 'enable-theme-functions #'ez-modeline--on-theme)
             (add-hook 'disable-theme-functions #'ez-modeline--on-theme)
             (advice-add 'evil-refresh-mode-line :around #'ez-modeline--evil-refresh))
    (remove-hook 'enable-theme-functions #'ez-modeline--on-theme)
    (remove-hook 'disable-theme-functions #'ez-modeline--on-theme)
    (advice-remove 'evil-refresh-mode-line #'ez-modeline--evil-refresh)
    (ez-modeline--uninstall)))

(defun ez-modeline-refresh ()
  "Recompute the faces (after a font or theme change) and redraw."
  (interactive)
  (when ez-modeline-mode (ez-modeline--apply-faces))
  (force-mode-line-update t))

(defvar ez-modeline-position-changed-hook nil
  "Normal hook run after `ez-modeline-toggle-position' moved the modeline.")

;;;###autoload
(defun ez-modeline-toggle-position ()
  "Move the modeline between the bottom and the top of the windows."
  (interactive)
  (setopt ez-modeline-position (if (eq ez-modeline-position 'top) 'bottom 'top))
  (run-hooks 'ez-modeline-position-changed-hook)
  (message "Modeline at the %s" ez-modeline-position))

(provide 'ez-modeline)
(require 'ez-modeline-segments)
;;; ez-modeline.el ends here
