;;; ez-agents-usage.el --- Usage cards for ez-agents -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;;; Commentary:

;; One card per installed agent showing the usage limits the agent itself
;; reports (never estimates).  An agent only gets a card when it is installed,
;; has a provider in `ez-agents-usage-providers', and the provider returned
;; limits; otherwise it is left out.
;;
;; A provider is a function (CALLBACK) that gathers the limits in the
;; background and calls CALLBACK with a list of windows, or nil when none are
;; available.  A window is a plist (:label "5h" :percent 6 :reset TIME).
;; Add an agent with `ez-agents-usage-register'.
;;
;;   Claude Code  `claude -p /usage'
;;   Codex        `codex app-server', request account/rateLimits/read

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'ez-agents)

(defcustom ez-agents-usage-cache-seconds 120
  "Seconds a usage reading is reused before the agent is asked again."
  :type 'number
  :group 'ez-agents)

(defvar ez-agents-usage-providers nil
  "Alist (KIND . FUNCTION); see the Commentary.")

(defun ez-agents-usage-register (kind function)
  "Make FUNCTION the usage provider of agent KIND."
  (setf (alist-get kind ez-agents-usage-providers) function))

(defvar ez-agents-usage--cache (make-hash-table :test #'eq)
  "Kind -> (TIME . WINDOWS).")

(defvar ez-agents-usage--busy nil "Kinds whose provider is running.")

(defun ez-agents-usage--refresh (kind)
  "Ask KIND's provider for fresh limits in the background."
  (when-let* ((fn (alist-get kind ez-agents-usage-providers))
              ((not (memq kind ez-agents-usage--busy))))
    (push kind ez-agents-usage--busy)
    (let ((done nil))
      (condition-case nil
          (funcall fn (lambda (windows)
                        (unless done
                          (setq done t
                                ez-agents-usage--busy (delq kind ez-agents-usage--busy))
                          (puthash kind (cons (float-time) windows) ez-agents-usage--cache)
                          (when (fboundp 'ez-agents-dashboard-refresh)
                            (ez-agents-dashboard-refresh)))))
        (error (setq ez-agents-usage--busy (delq kind ez-agents-usage--busy)))))))

(defun ez-agents-usage (kind)
  "Last known limit windows of agent KIND (nil if none); refreshes when stale."
  (let ((hit (gethash kind ez-agents-usage--cache)))
    (when (or (null hit) (> (- (float-time) (car hit)) ez-agents-usage-cache-seconds))
      (ez-agents-usage--refresh kind))
    (cdr hit)))

(defun ez-agents-usage-visible-kinds ()
  "Installed agents whose provider has limits to show, in definition order."
  (cl-loop for (kind . def) in ez-agents-definitions
           when (and (alist-get kind ez-agents-usage-providers)
                     (executable-find (car (plist-get def :command)))
                     (ez-agents-usage kind))
           collect kind))

(defun ez-agents-usage--run (command callback parse &optional input)
  "Run COMMAND in the background and call CALLBACK with (PARSE output).
INPUT, when given, is sent to the process on stdin (each element a line).
CALLBACK gets nil if the command fails or takes more than 30 seconds."
  (let* ((default-directory temporary-file-directory)
         (process-environment (cl-remove-if (lambda (e) (string-prefix-p "EZ_AGENT" e))
                                            process-environment))
         (buf (generate-new-buffer " *ez-agents-usage*"))
         (finish (lambda (proc)
                   (when (buffer-live-p buf)
                     (let ((text (with-current-buffer buf (buffer-string))))
                       (kill-buffer buf)
                       (when (process-live-p proc) (delete-process proc))
                       (funcall callback (ignore-errors (funcall parse text)))))))
         (proc (make-process :name "ez-agents-usage" :buffer buf :noquery t
                             :command command :connection-type 'pipe
                             :sentinel (lambda (p _e) (unless (process-live-p p) (funcall finish p))))))
    (run-at-time 30 nil (lambda () (when (process-live-p proc) (funcall finish proc))))
    (dolist (line input) (process-send-string proc (concat line "\n")))
    proc))

;;;; Claude Code: `claude -p /usage'

(defun ez-agents-usage--parse-reset (text)
  "Time of the reset described by TEXT, e.g. \"Oct 19 at 12:59am (Africa/Lagos)\"."
  (when (string-match
         (concat "\\(?:\\([A-Z][a-z][a-z]\\)[a-z]* \\([0-9]+\\) at \\)?"
                 "\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\([ap]m\\) (\\([^)]+\\))")
         text)
    (let* ((mon (match-string 1 text)) (day (match-string 2 text))
           (hour (mod (string-to-number (match-string 3 text)) 12))
           (hour (if (equal (match-string 5 text) "pm") (+ hour 12) hour))
           (min (string-to-number (or (match-string 4 text) "0")))
           (zone (match-string 6 text))
           (now (decode-time nil zone))
           (month (if mon (1+ (seq-position '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug"
                                              "Sep" "Oct" "Nov" "Dec") mon))
                    (decoded-time-month now)))
           (d (if day (string-to-number day) (decoded-time-day now)))
           (year (decoded-time-year now))
           (try (lambda (y) (float-time (encode-time 0 min hour d month y zone))))
           (tm (funcall try year)))
      (cond ((> tm (- (float-time) 60)) tm)
            (mon (funcall try (1+ year)))
            (t (+ tm 86400))))))

(defun ez-agents-usage--parse-claude (text)
  "Limit windows in the output TEXT of `/usage', or nil."
  (let (out)
    (dolist (spec '(("Current session" . "5h") ("Current week (all models)" . "Week")))
      (when (string-match (concat (regexp-quote (car spec))
                                  ": \\([0-9.]+\\)% used\\(?: · resets \\(.*\\)\\)?")
                          text)
        (push (list :label (cdr spec)
                    :percent (string-to-number (match-string 1 text))
                    :reset (and (match-string 2 text)
                                (ez-agents-usage--parse-reset (match-string 2 text))))
              out)))
    (nreverse out)))

(defun ez-agents-usage--claude (callback)
  (ez-agents-usage--run (list (or (executable-find "claude") "claude") "-p" "/usage")
                        callback #'ez-agents-usage--parse-claude))

(ez-agents-usage-register 'claude #'ez-agents-usage--claude)

;;;; Codex: app-server rate limits

(defun ez-agents-usage--minutes-label (mins)
  (cond ((null mins) "Limit")
        ((= mins 300) "5h")
        ((= mins 10080) "Week")
        ((>= mins 40320) "Month")
        ((>= mins 1440) (format "%dd" (round mins 1440)))
        (t (format "%dh" (round mins 60)))))

(defun ez-agents-usage--parse-codex (text)
  "Limit windows in the JSON-RPC output TEXT of `codex app-server', or nil."
  (catch 'found
    (dolist (line (split-string text "\n" t))
      (when-let* ((d (ignore-errors (json-parse-string line :object-type 'alist)))
                  ((eql (alist-get 'id d) 2))
                  (rl (alist-get 'rateLimits (alist-get 'result d))))
        (throw 'found
               (cl-loop for key in '(primary secondary)
                        for w = (alist-get key rl)
                        when (and (consp w) (numberp (alist-get 'usedPercent w)))
                        collect (list :label (ez-agents-usage--minutes-label
                                              (alist-get 'windowDurationMins w))
                                      :percent (alist-get 'usedPercent w)
                                      :reset (when-let* ((r (alist-get 'resetsAt w))) (float r)))))))
    nil))

(defun ez-agents-usage--codex (callback)
  (let ((proc
         (ez-agents-usage--run
          (list (or (executable-find "codex") "codex") "app-server")
          callback #'ez-agents-usage--parse-codex
          (list (json-serialize (list :jsonrpc "2.0" :id 1 :method "initialize"
                                      :params (list :clientInfo (list :name "ez-agents" :version "1")
                                                    :capabilities (make-hash-table))))
                (json-serialize '(:jsonrpc "2.0" :method "initialized"))
                (json-serialize '(:jsonrpc "2.0" :id 2 :method "account/rateLimits/read"))))))
    ;; The server stays up until told otherwise: stop it once the answer is in.
    (set-process-filter
     proc
     (lambda (p chunk)
       (when (buffer-live-p (process-buffer p))
         (with-current-buffer (process-buffer p) (goto-char (point-max)) (insert chunk)
                              (when (save-excursion (goto-char (point-min))
                                                    (re-search-forward "\"id\":2[,}]" nil t))
                                (process-send-eof p) (delete-process p))))))
    proc))

(ez-agents-usage-register 'codex #'ez-agents-usage--codex)

;;;; Rendering

;; Cards and bars are drawn with background colours and `:align-to' spaces rather
;; than box-drawing and block glyphs: those come from fallback fonts whose widths
;; differ from the text font, which skewed the borders.

(defun ez-agents-usage--shade (amount)
  "The default background shifted toward the foreground by AMOUNT percent."
  (let ((bg (face-background 'default nil t)))
    (if (and bg (color-defined-p bg))
        (if (eq (frame-parameter nil 'background-mode) 'dark)
            (color-lighten-name bg amount)
          (color-darken-name bg amount))
      "gray50")))

(defun ez-agents-usage--dim (s) (propertize s 'face 'ez-agents-dim))

(defun ez-agents-usage--bar (percent width)
  "A WIDTH-column bar filled to PERCENT, made of coloured spaces."
  (let* ((p (max 0 (min 100 (or percent 0))))
         (n (round (* width (/ p 100.0))))
         (fill (face-foreground (cond ((>= p 90) 'error) ((>= p 70) 'warning) (t 'success))
                                nil t)))
    (concat (propertize (make-string n ?\s) 'face `(:background ,fill))
            (propertize (make-string (- width n) ?\s)
                        'face `(:background ,(ez-agents-usage--shade 14))))))

(defun ez-agents-usage--pct (pct)
  "PCT as a fixed five-column string, so bars and figures line up."
  (format " %4s" (format "%.0f%%" pct)))

(defun ez-agents-usage--reset (time)
  (let ((secs (and time (- time (float-time)))))
    (cond ((null secs) "")
          ((<= secs 0) "reset due")
          ((< secs 172800) (format "resets %dh%02dm" (/ (floor secs) 3600) (/ (mod (floor secs) 3600) 60)))
          (t (format "resets %dd%02dh" (/ (floor secs) 86400) (/ (mod (floor secs) 86400) 3600))))))

(defun ez-agents-usage--detail (w)
  (format "%.0f%% left · %s" (max 0 (- 100 (plist-get w :percent)))
          (ez-agents-usage--reset (plist-get w :reset))))

(defun ez-agents-usage--card-lines (kind col width &optional airy height)
  "Lines of the card for KIND starting at column COL, each WIDTH columns wide.
Every line positions itself with `:align-to', so cards line up exactly."
  (let* ((def (cdr (assq kind ez-agents-definitions)))
         (inner (- width 2))
         (bar-w (max 4 (min 14 (- inner 12))))
         (card-bg `(:background ,(ez-agents-usage--shade 5) :extend nil))
         (pad (lambda (s)
                (let ((line (concat (propertize " " 'display `(space :align-to ,col))
                                    " "
                                    (truncate-string-to-width s inner nil ?\s "…")
                                    " "
                                    (propertize " " 'display `(space :align-to ,(+ col width))))))
                  ;; not the leading spacer: that is the gap between cards
                  (add-face-text-property 1 (length line) card-bg t line)
                  line)))
         ;; Blank rows inside the card only when there is room: a tall stack of
         ;; them is too spaced out in the narrow sidebar.
         (body (cons (propertize (plist-get def :name) 'face 'bold)
                     (append
                      (and airy (list ""))
                      (funcall
                       (if airy #'butlast #'identity)
                       (cl-loop for w in (ez-agents-usage kind)
                                collect (concat (ez-agents-usage--dim (format "%-6s" (plist-get w :label)))
                                                (ez-agents-usage--bar (plist-get w :percent) bar-w)
                                                (ez-agents-usage--pct (plist-get w :percent)))
                                collect (ez-agents-usage--dim (ez-agents-usage--detail w))
                                when airy collect ""))))))
    (let ((lines (append (list (funcall pad "")) (mapcar pad body) (list (funcall pad "")))))
      ;; shorter cards are padded so a row of cards forms even rectangles
      (while (< (length lines) (or height 0))
        (setq lines (append (butlast lines) (list (funcall pad "") (car (last lines))))))
      lines)))

(defun ez-agents-usage-cards (total-width &optional compact)
  "Cards for the agents with limits to show, fitted to TOTAL-WIDTH columns.
Cards sit side by side while they fit, otherwise one per row, always with a
gap between them.  Nil when no agent has anything to show."
  (when-let* ((kinds (ez-agents-usage-visible-kinds)))
    (let* ((gap 4)
           (min-w 26)
           (per-row (min (max 1 (/ (+ total-width gap) (+ min-w gap))) (length kinds)))
           (w (max min-w (min 34 (/ (- total-width (* gap (1- per-row))) per-row))))
           out)
      (dolist (row (seq-partition kinds per-row))
        (let* ((lay (lambda (height)
                      (cl-loop for k in row for i from 0
                               collect (ez-agents-usage--card-lines
                                        k (+ 2 (* i (+ w gap))) w (not compact) height))))
               (height (apply #'max (mapcar #'length (funcall lay nil))))
               (cols (funcall lay height)))
          (dotimes (i height)
            (push (mapconcat (lambda (c) (or (nth i c) "")) cols "") out))
          (push "" out)))
      (concat (mapconcat #'identity (nreverse out) "\n") "\n"))))

(provide 'ez-agents-usage)
;;; ez-agents-usage.el ends here
