;;; ez-dashboard.el --- A status dashboard for Emacs -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; One buffer that shows what is going on in Emacs: startup figures, agents and
;; their usage, recent projects, recent conversations, recent files, what is
;; running right now.  This file is the engine: the buffer, the layout, the
;; stat tiles, item navigation and refresh.  What fills it is registered by
;; `ez-dashboard-define-section' and `ez-dashboard-cards'; see
;; ez-dashboard-sections.el for the built-in ones.
;;
;; Layout follows `ez-dashboard-layout': a list of rows, each the symbol `cards'
;; (the stat tiles) or a list of one or two section ids.  Two sections share a
;; row on wide windows and stack on narrow ones.  The page is a pure function of
;; the window width (`ez-dashboard--page'), centred in the window.
;;
;; Alignment: columns are placed with `:align-to' display specs, not counted
;; spaces, so wide icon glyphs cannot push a column out of line.  Keep any
;; `:height' scaling off lines that must stay aligned.
;;
;; Keys (the module binds them for Evil too):
;;   RET / click  open the item          j k TAB S-TAB  next / previous item
;;   a p c f s m  jump to a section      g  refresh      q  close      ?  help

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)

(defgroup ez-dashboard nil
  "A dashboard of what is going on in Emacs."
  :group 'applications
  :prefix "ez-dashboard-")

(defconst ez-dashboard-buffer-name "*Dashboard*")

(defcustom ez-dashboard-max-width 112
  "Widest the dashboard grows; wider windows are centred around it."
  :type 'integer :group 'ez-dashboard)

(defcustom ez-dashboard-two-column-min-width 96
  "Windows narrower than this stack two-section rows instead of side by side."
  :type 'integer :group 'ez-dashboard)

(defcustom ez-dashboard-name nil
  "Name used in the greeting, or nil for none."
  :type '(choice (const nil) string) :group 'ez-dashboard)

(defcustom ez-dashboard-layout '(cards (agents) (projects chats) (files session) (config))
  "Rows of the page.  See the Commentary of ez-dashboard.el."
  :type 'sexp :group 'ez-dashboard)

(defcustom ez-dashboard-refresh-interval 60
  "Seconds between refreshes while the dashboard is visible."
  :type 'integer :group 'ez-dashboard)

(defvar ez-dashboard-fill-function nil
  "Function that loads the slow data and asks for a redraw, or nil.
Queued through `ez-dashboard-defer-function' every time the dashboard opens.")

(defcustom ez-dashboard-defer-function #''ez-dashboard--defer-idle
  "Function that runs a thunk later, once Emacs is idle.
The slow parts of the dashboard (agents, chat history) fill in through it so
the first paint never waits on them."
  :type 'function :group 'ez-dashboard)

;;;; Faces

(defface ez-dashboard-section '((t :inherit font-lock-keyword-face :weight bold))
  "Section titles." :group 'ez-dashboard)
(defface ez-dashboard-rule '((t :inherit shadow)) "Rules and borders." :group 'ez-dashboard)
(defface ez-dashboard-dim '((t :inherit shadow)) "Secondary text." :group 'ez-dashboard)
(defface ez-dashboard-value '((t :weight bold)) "Figures." :group 'ez-dashboard)
(defface ez-dashboard-key '((t :inherit font-lock-constant-face :weight bold))
  "Key hints." :group 'ez-dashboard)
(defface ez-dashboard-hover '((t :inherit highlight)) "Mouse over an item."
  :group 'ez-dashboard)
(defface ez-dashboard-selected '((t :inherit highlight :weight bold))
  "The item at point." :group 'ez-dashboard)

;;;; Registries

(defvar ez-dashboard-sections nil
  "Alist ID -> plist (:title :icon :fn :key).  See `ez-dashboard-define-section'.")

(defvar ez-dashboard-cards nil
  "Functions, each returning a plist describing one stat tile, or nil.
Keys: :label :value :sub :face (accent) :icon :action.")

(defvar ez-dashboard-tick-hook nil
  "Normal hook run on every periodic refresh while the dashboard is visible.
Providers use it to refresh their own caches.")

(defvar ez-dashboard-mode-map)

(defun ez-dashboard-define-section (id title icon fn &optional key)
  "Register section ID with TITLE, ICON, body function FN and jump KEY.
FN takes the section width and returns a list of line strings."
  (setf (alist-get id ez-dashboard-sections)
        (list :title title :icon icon :fn fn :key key))
  (when (and key (boundp 'ez-dashboard-mode-map))
    (define-key ez-dashboard-mode-map key
                (lambda () (interactive) (ez-dashboard-goto-section id)))))

;;;; Text helpers

(defvar ez-dashboard--use-align t
  "Non-nil: place columns with `:align-to'.  Tests turn it off to count spaces.")

(defvar ez-dashboard--item-counter 0)

(defun ez-dashboard--truncate (string width)
  "STRING cut to WIDTH columns, ending in an ellipsis when it was cut."
  (if (<= (string-width string) width)
      string
    (truncate-string-to-width string (max 0 width) nil nil "…")))

(defun ez-dashboard--to-col (string col &optional face)
  "STRING followed by padding that reaches absolute window column COL.
With FACE on the padding.  Used for page-level placement only: the padding is
an `:align-to' space, so STRING must be plain text (its width is never measured)
unless `ez-dashboard--use-align' is off, as in tests."
  (if ez-dashboard--use-align
      (concat string (propertize " " 'display `(space :align-to ,col) 'face face))
    (let ((w (string-width string)))
      (if (>= w col)
          string
        (concat string (propertize (make-string (- col w) ?\s) 'face face))))))

(defun ez-dashboard--pad-to (string width)
  "STRING padded with plain spaces to WIDTH columns, for use inside sections."
  (let ((w (string-width string)))
    (if (>= w width) string (concat string (make-string (- width w) ?\s)))))

(defun ez-dashboard--ago (time)
  "A short age for TIME (a float): 5m, 3h, 2d."
  (let ((s (max 0 (floor (- (float-time) time)))))
    (cond ((< s 60) "now")
          ((< s 3600) (format "%dm" (/ s 60)))
          ((< s 86400) (format "%dh" (/ s 3600)))
          ((< s (* 60 86400)) (format "%dd" (/ s 86400)))
          (t (format-time-string "%b %d" time)))))

(defun ez-dashboard--bar (percent width)
  "A thin bar WIDTH columns wide, PERCENT full, coloured by how full it is."
  (let* ((filled (round (* width (/ (min 100.0 (max 0.0 percent)) 100.0))))
         (face (cond ((< percent 60) 'success) ((< percent 85) 'warning) (t 'error))))
    (concat (propertize (make-string filled ?━) 'face face)
            (propertize (make-string (- width filled) ?─) 'face 'ez-dashboard-rule))))

(defun ez-dashboard-icon (name fallback &optional face)
  "The nerd-icons mdicon NAME, or the plain character FALLBACK; both use FACE."
  (or (and name (require 'nerd-icons nil t) (fboundp 'nerd-icons-mdicon)
           (ignore-errors (nerd-icons-mdicon name :face face)))
      (propertize fallback 'face face)))

(defvar ez-dashboard-item-map)

(defun ez-dashboard--item-props (action id &optional help)
  "A fresh property list for an item running ACTION, identified by ID.
HELP is the hover text.  Every line of a multi-line item shares one list."
  (list 'ez-dashboard-item (cl-incf ez-dashboard--item-counter)
        'ez-dashboard-action action 'ez-dashboard-id id
        'mouse-face 'ez-dashboard-hover 'help-echo (or help "RET: open")
        'keymap ez-dashboard-item-map 'follow-link t))

(defun ez-dashboard--same-item (text item-props)
  "TEXT carrying the item properties ITEM-PROPS (a plist)."
  (let ((s (copy-sequence text)))
    (add-text-properties 0 (length s) item-props s)
    s))

(defun ez-dashboard-item (text action &optional id help)
  "TEXT made into a clickable item running ACTION (a function of no arguments).
ID identifies the item across refreshes; HELP is shown on hover."
  (ez-dashboard--same-item text (ez-dashboard--item-props action id help)))

;;;; Stat tiles

(defun ez-dashboard--dark-p ()
  "Non-nil if the theme's background is dark."
  (let ((bg (face-background 'default nil t)))
    (if (and bg (color-defined-p bg))
        (< (apply #'+ (color-name-to-rgb bg)) 1.5)
      t)))

(defun ez-dashboard--tile-bg ()
  "A background slightly off the theme's, for the stat tiles; nil if unavailable."
  (let ((bg (face-background 'default nil t)))
    (when (and bg (color-defined-p bg) (not (equal bg "unspecified-bg")))
      (ignore-errors
        (if (ez-dashboard--dark-p) (color-lighten-name bg 7) (color-darken-name bg 5))))))

(defun ez-dashboard--cards-row (cards width lead)
  "Lines (complete, with LEAD) for one row of CARDS in WIDTH columns."
  (let* ((n (length cards))
         (gap 2)
         (cw (/ (- width (* gap (1- n))) n))
         (bg (ez-dashboard--tile-bg))
         (bgface (if bg (list :background bg) 'secondary-selection))
         (rows (make-list 5 (ez-dashboard--to-col "" lead)))
         (x lead))
    (dolist (card cards)
      (let* ((accent (or (plist-get card :face) 'ez-dashboard-key))
             (props (and (plist-get card :action)
                         (ez-dashboard--item-props (plist-get card :action)
                                                   (plist-get card :label)
                                                   (plist-get card :help))))
             (inner (- cw 2))
             ;; Keep the icon's own face: it names the icon font.  Only the tile
             ;; background is added to it (replacing it would drop the font).
             (icon (let ((i (copy-sequence (or (plist-get card :icon) ""))))
                     (add-face-text-property 0 (length i) bgface t i)
                     i))
             (label (concat icon
                            (propertize (concat " " (ez-dashboard--truncate
                                                     (or (plist-get card :label) "")
                                                     (max 1 (- inner (string-width icon) 1))))
                                        'face (list 'ez-dashboard-dim bgface))))
             (cells (list ""
                          label
                          (propertize (ez-dashboard--truncate (or (plist-get card :value) "") inner)
                                      'face (list 'ez-dashboard-value accent bgface))
                          (propertize (ez-dashboard--truncate (or (plist-get card :sub) "") inner)
                                      'face (list 'ez-dashboard-dim bgface))
                          ""))
             (i 0))
        (setq rows
              (mapcar
               (lambda (row)
                 (let* ((cell (nth i cells))
                        (bar (propertize "▎" 'face (list accent bgface)))
                        (body (concat bar (propertize " " 'face bgface)
                                      (if props (ez-dashboard--same-item cell props) cell)))
                        (line (concat row body)))
                   (setq i (1+ i))
                   (ez-dashboard--to-col line (+ x cw) bgface)))
               rows))
        (setq x (+ x cw gap))
        (setq rows (mapcar (lambda (r) (ez-dashboard--to-col r x)) rows))))
    rows))

;;;; Sections

(defun ez-dashboard--section-lines (id width)
  "The lines of section ID for WIDTH columns: title line, body, blank line."
  (when-let* ((def (alist-get id ez-dashboard-sections)))
    (let* ((icon (or (plist-get def :icon) ""))
           (title (concat icon (if (string-empty-p icon) "" " ")
                          (propertize (plist-get def :title) 'face 'ez-dashboard-section)))
           (key (plist-get def :key))
           (hint (if key (propertize (format "  %s" key) 'face 'ez-dashboard-key) ""))
           (head (concat title hint " "))
           (rule (propertize (make-string (max 2 (- width (string-width head) 1)) ?─)
                             'face 'ez-dashboard-rule))
           (body (condition-case err
                     (funcall (plist-get def :fn) (- width 1))
                   (error (list (propertize (format "error: %s" (error-message-string err))
                                            'face 'error))))))
      (append (list (propertize (concat head rule) 'ez-dashboard-section id))
              (mapcar (lambda (l)
                        (let ((s (copy-sequence (ez-dashboard--truncate l width))))
                          (add-text-properties 0 (length s) (list 'ez-dashboard-in id) s)
                          s))
                      (or body (list (propertize "nothing yet" 'face 'ez-dashboard-dim))))
              (list "")))))

(defun ez-dashboard--hjoin (left lw right x2 lead)
  "Join the LEFT (LW wide) and RIGHT line lists side by side.
RIGHT starts at column X2; every line is led by LEAD columns."
  (let ((n (max (length left) (length right))) out)
    (dotimes (i n)
      (let* ((l (ez-dashboard--truncate (or (nth i left) "") lw))
             (r (or (nth i right) ""))
             (s (concat (ez-dashboard--to-col "" lead) l)))
        (push (if (string-empty-p r) s (concat (ez-dashboard--to-col s x2) r)) out)))
    (nreverse out)))

(defun ez-dashboard--indent (lines lead)
  "LINES each preceded by LEAD columns."
  (mapcar (lambda (l) (concat (ez-dashboard--to-col "" lead) l)) lines))

;;;; Header and footer

(defconst ez-dashboard--banner
  '("╔═╗╔╦╗╔═╗╔═╗╔═╗"
    "║╣ ║║║╠═╣║  ╚═╗"
    "╚═╝╩ ╩╩ ╩╚═╝╚═╝")
  "EMACS in the Calvin S figlet font.")

(defconst ez-dashboard--banner-faces
  '(font-lock-keyword-face font-lock-function-name-face font-lock-type-face
    font-lock-string-face font-lock-constant-face))

(defun ez-dashboard--greeting ()
  "A time-of-day greeting."
  (let ((h (decoded-time-hour (decode-time))))
    (format "%s%s"
            (cond ((< h 5) "Still up") ((< h 12) "Good morning")
                  ((< h 18) "Good afternoon") (t "Good evening"))
            (if ez-dashboard-name (format ", %s" ez-dashboard-name) ""))))

(defun ez-dashboard--banner-line (i)
  "Row I of the banner, each letter in its own theme colour."
  (let ((row (nth i ez-dashboard--banner)) (out "") (pos 0) (k 0))
    (while (< pos (length row))
      (let ((chunk (substring row pos (min (length row) (+ pos 3)))))
        (setq out (concat out (propertize chunk 'face
                                          (list (nth (mod k (length ez-dashboard--banner-faces))
                                                     ez-dashboard--banner-faces)
                                                :weight 'bold)))
              pos (+ pos 3) k (1+ k))))
    out))

(defvar ez-dashboard-header-info-function #'ez-dashboard--default-info
  "Function returning up to three info lines shown beside the banner.")

(defun ez-dashboard--default-info ()
  "Greeting, date and Emacs version lines for the header."
  (list (propertize (ez-dashboard--greeting) 'face 'ez-dashboard-value)
        (propertize (format-time-string "%A, %-d %B · %H:%M") 'face 'ez-dashboard-dim)
        (propertize (format "Emacs %s · up %s" emacs-version (emacs-uptime "%h:%.2m"))
                    'face 'ez-dashboard-dim)))

(defun ez-dashboard--header (width lead)
  "Banner and info lines for WIDTH columns, led by LEAD."
  (let* ((info (funcall ez-dashboard-header-info-function))
         (narrow (< width 56)))
    (append
     (list "")
     (cl-loop for i from 0 below 3
              collect (let ((s (concat (ez-dashboard--to-col "" lead)
                                       (ez-dashboard--banner-line i))))
                        (if narrow
                            s
                          (concat (ez-dashboard--to-col s (+ lead 19))
                                  (ez-dashboard--truncate (or (nth i info) "") (- width 19))))))
     (when narrow
       (ez-dashboard--indent (mapcar (lambda (l) (ez-dashboard--truncate l width)) info) lead))
     (list ""))))

(defun ez-dashboard--footer (width lead)
  "The key hint line for WIDTH columns, led by LEAD."
  (let* ((keys '(("RET" . "open") ("j/k" . "move") ("a p c f s m" . "sections")
                 ("g" . "refresh") ("q" . "close") ("?" . "help")))
         (text (mapconcat (lambda (k)
                            (concat (propertize (car k) 'face 'ez-dashboard-key) " "
                                    (propertize (cdr k) 'face 'ez-dashboard-dim)))
                          keys "   ")))
    (list "" (concat (ez-dashboard--to-col "" lead) (ez-dashboard--truncate text width)))))

;;;; The page

(defun ez-dashboard--page (total-width)
  "All lines of the dashboard for a window TOTAL-WIDTH columns wide."
  (let* ((width (max 40 (min ez-dashboard-max-width (- total-width 4))))
         (lead (max 0 (/ (- total-width width) 2)))
         (two (>= width ez-dashboard-two-column-min-width))
         lines)
    (setq lines (ez-dashboard--header width lead))
    (dolist (row ez-dashboard-layout)
      (cond
       ((eq row 'cards)
        (let* ((cards (delq nil (mapcar (lambda (f) (condition-case nil (funcall f) (error nil)))
                                        ez-dashboard-cards)))
               (n (length cards))
               (per (max 1 (min n (/ (+ width 2) 19))))
               (per (if (> n 0) (ceiling n (ceiling n per)) 1)))
          (while cards
            (let ((chunk (cl-loop repeat per while cards collect (pop cards))))
              (setq lines (append lines (ez-dashboard--cards-row chunk width lead) (list "")))))))
       ((and (consp row) (cdr row) two)
        (let* ((gap 4)
               (lw (/ (- width gap) 2))
               (rw (- width gap lw)))
          (setq lines
                (append lines
                        (ez-dashboard--hjoin (ez-dashboard--section-lines (car row) lw) lw
                                             (ez-dashboard--section-lines (cadr row) rw)
                                             (+ lead lw gap) lead)))))
       ((consp row)
        (dolist (id row)
          (setq lines (append lines (ez-dashboard--indent
                                     (ez-dashboard--section-lines id width) lead)))))))
    (append lines (ez-dashboard--footer width lead))))

;;;; Mode

(defvar ez-dashboard-item-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'ez-dashboard-click)
    m)
  "Keys on an item (clicking opens it).")

(defvar-keymap ez-dashboard-mode-map
  :doc "Keymap for `ez-dashboard-mode'."
  :parent special-mode-map
  "RET" #'ez-dashboard-activate
  "j" #'ez-dashboard-next-item
  "k" #'ez-dashboard-previous-item
  "<down>" #'ez-dashboard-next-item
  "<up>" #'ez-dashboard-previous-item
  "TAB" #'ez-dashboard-next-item
  "<backtab>" #'ez-dashboard-previous-item
  "g" #'ez-dashboard-refresh
  "q" #'quit-window
  "?" #'ez-dashboard-help)

(defvar-local ez-dashboard--overlay nil)
(defvar-local ez-dashboard--last-width nil)

(define-derived-mode ez-dashboard-mode special-mode "Dashboard"
  "Major mode of the dashboard buffer.

\\{ez-dashboard-mode-map}"
  (setq-local cursor-type nil
              truncate-lines t
              mode-line-format nil
              header-line-format nil
              left-fringe-width 0 right-fringe-width 0
              display-line-numbers nil
              show-trailing-whitespace nil
              cursor-in-non-selected-windows nil)
  (buffer-disable-undo)
  (add-hook 'post-command-hook #'ez-dashboard--highlight nil t)
  (add-hook 'window-configuration-change-hook #'ez-dashboard--maybe-resize nil t)
  (add-hook 'kill-buffer-hook #'ez-dashboard--cleanup nil t))

(defun ez-dashboard--cleanup ()
  "Drop the highlight overlay when the buffer goes."
  (when ez-dashboard--overlay (delete-overlay ez-dashboard--overlay)))

(defun ez-dashboard--maybe-resize ()
  "Redraw when the window width changed."
  (when-let* ((win (get-buffer-window (current-buffer) 'visible))
              ((not (eql (window-body-width win) ez-dashboard--last-width))))
    (ez-dashboard-refresh)))

;;;; Items

(defun ez-dashboard--item-at (&optional pos)
  "The item id at POS (default point), or nil."
  (get-text-property (or pos (point)) 'ez-dashboard-item))

(defun ez-dashboard-activate ()
  "Open the item at point."
  (interactive)
  (if-let* ((action (get-text-property (point) 'ez-dashboard-action)))
      (funcall action)
    (user-error "Nothing to open here")))

(defun ez-dashboard-click (event)
  "Open the item under the mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (ez-dashboard-activate))

(defun ez-dashboard--section-rank (section)
  "Reading order of SECTION: the tiles (nil) first, then layout order."
  (or (and section (cl-position section (flatten-tree ez-dashboard-layout))) -1))

(defun ez-dashboard--items ()
  "Every item as (ID POSITION SECTION), once each, in reading order.
Reading order goes section by section, top to bottom inside a section, so in
a two-column row `j' walks down one column before the other.  A tile spanning
several lines is one item, found at its first line."
  (let ((seen (make-hash-table :test #'eql)) items (pos (point-min)))
    (while (< pos (point-max))
      (let ((id (get-text-property pos 'ez-dashboard-item)))
        (when (and id (not (gethash id seen)))
          (puthash id t seen)
          (push (list id pos (get-text-property pos 'ez-dashboard-in)) items)))
      (setq pos (or (next-single-property-change pos 'ez-dashboard-item) (point-max))))
    (sort (nreverse items)
          (lambda (a b)
            (let ((ra (ez-dashboard--section-rank (nth 2 a)))
                  (rb (ez-dashboard--section-rank (nth 2 b))))
              (or (< ra rb) (and (= ra rb) (< (nth 1 a) (nth 1 b)))))))))

(defun ez-dashboard--move-item (step)
  "Move STEP items (1 or -1) in reading order from the item at point."
  (let* ((items (ez-dashboard--items))
         (here (ez-dashboard--item-at))
         (idx (or (and here (cl-position here items :key #'car))
                  ;; not on an item: pretend to stand just before/after point
                  (cl-position-if (lambda (i) (>= (nth 1 i) (point))) items)
                  (length items)))
         (new (if (and here (cl-position here items :key #'car))
                  (+ idx step)
                (if (> step 0) idx (1- idx)))))
    (cond ((null items) (message "Nothing to open here"))
          ((< new 0) (message "First item"))
          ((>= new (length items)) (message "Last item"))
          (t (goto-char (nth 1 (nth new items)))))))

(defun ez-dashboard-next-item ()
  "Move to the next item."
  (interactive)
  (ez-dashboard--move-item 1))

(defun ez-dashboard-previous-item ()
  "Move to the previous item."
  (interactive)
  (ez-dashboard--move-item -1))

(defun ez-dashboard-goto-section (id)
  "Move to the first item of section ID."
  (if-let* ((item (cl-find id (ez-dashboard--items) :key (lambda (i) (nth 2 i)))))
      (goto-char (nth 1 item))
    (message "No items in that section")))

(defun ez-dashboard--highlight ()
  "Mark the item at point with an overlay (the cursor itself is hidden)."
  (let ((id (ez-dashboard--item-at)))
    (if (not id)
        (when ez-dashboard--overlay (delete-overlay ez-dashboard--overlay))
      (let ((beg (or (previous-single-property-change (1+ (point)) 'ez-dashboard-item nil
                                                      (line-beginning-position))
                     (line-beginning-position)))
            (end (or (next-single-property-change (point) 'ez-dashboard-item nil
                                                  (line-end-position))
                     (line-end-position))))
        (unless ez-dashboard--overlay
          (setq ez-dashboard--overlay (make-overlay beg end))
          (overlay-put ez-dashboard--overlay 'face 'ez-dashboard-selected)
          (overlay-put ez-dashboard--overlay 'priority 100))
        (move-overlay ez-dashboard--overlay beg end)))))

(defun ez-dashboard-help ()
  "Explain the keys."
  (interactive)
  (message "RET open · j/k or TAB move · g refresh · q close · jump: %s"
           (mapconcat (lambda (s) (format "%s %s" (plist-get (cdr s) :key)
                                          (plist-get (cdr s) :title)))
                      (cl-remove-if-not (lambda (s) (plist-get (cdr s) :key))
                                        ez-dashboard-sections)
                      " · ")))

;;;; Refresh

(defun ez-dashboard--defer-idle (thunk)
  "Run THUNK once Emacs has been idle a moment."
  (run-with-idle-timer 0.3 nil thunk))

(defvar ez-dashboard--timer nil)
(defvar ez-dashboard--debounce nil)

(defun ez-dashboard-visible-p ()
  "Non-nil if the dashboard buffer is showing in some window."
  (and (get-buffer ez-dashboard-buffer-name)
       (get-buffer-window ez-dashboard-buffer-name 'visible)))

(defun ez-dashboard-refresh ()
  "Redraw the dashboard, keeping point on the same item when it can."
  (interactive)
  (when-let* ((buf (get-buffer ez-dashboard-buffer-name)))
    (with-current-buffer buf
      (let* ((win (get-buffer-window buf 'visible))
             (total (cond (win (window-body-width win)) (ez-dashboard--last-width)
                          (t 100)))
             (id (get-text-property (point) 'ez-dashboard-id))
             (line (line-number-at-pos))
             (inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'identity (ez-dashboard--page total) "\n") "\n")
        (setq ez-dashboard--last-width total)
        (goto-char (point-min))
        (let ((found (and id (text-property-any (point-min) (point-max) 'ez-dashboard-id id))))
          (if found (goto-char found) (forward-line (1- line))))
        (dolist (w (get-buffer-window-list buf nil t))
          (set-window-point w (point)))
        (ez-dashboard--highlight)))))

(defun ez-dashboard-refresh-soon ()
  "Redraw shortly, merging bursts of calls; does nothing unless visible."
  (when (and (ez-dashboard-visible-p) (not ez-dashboard--debounce))
    (setq ez-dashboard--debounce
          (run-with-timer 0.6 nil (lambda ()
                                    (setq ez-dashboard--debounce nil)
                                    (when (ez-dashboard-visible-p) (ez-dashboard-refresh)))))))

(defun ez-dashboard--tick ()
  "Periodic refresh while the dashboard is visible."
  (cond ((not (get-buffer ez-dashboard-buffer-name))
         (when ez-dashboard--timer (cancel-timer ez-dashboard--timer))
         (setq ez-dashboard--timer nil))
        ((ez-dashboard-visible-p)
         (run-hooks 'ez-dashboard-tick-hook)
         (ez-dashboard-refresh))))

;;;###autoload
(defun ez-dashboard-buffer ()
  "The dashboard buffer, created and drawn.  Cheap: only already-cached data."
  (let ((buf (get-buffer-create ez-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ez-dashboard-mode) (ez-dashboard-mode))
      (unless ez-dashboard--last-width
        (setq ez-dashboard--last-width (window-body-width (selected-window)))))
    (unless ez-dashboard--timer
      (setq ez-dashboard--timer
            (run-with-timer ez-dashboard-refresh-interval ez-dashboard-refresh-interval
                            #'ez-dashboard--tick)))
    (ez-dashboard-refresh)
    (when ez-dashboard-fill-function
      (funcall ez-dashboard-defer-function ez-dashboard-fill-function))
    buf))

;;;###autoload
(defun ez-dashboard ()
  "Show the dashboard."
  (interactive)
  (let ((buf (ez-dashboard-buffer)))
    (switch-to-buffer buf)
    (ez-dashboard-refresh)
    buf))

(provide 'ez-dashboard)
;;; ez-dashboard.el ends here
