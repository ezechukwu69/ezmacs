;;; ez-dashboard-test.el --- Tests for ez-dashboard -*- lexical-binding: t; -*-

;; Run from the config root.  `load-prefer-newer' matters: build output (.elc)
;; from an older version of the code may sit next to the sources, and a bare
;; `emacs -Q' would load it instead of the source you just edited.
;;   emacs -Q --batch --eval '(setq load-prefer-newer t)' \
;;     -L lisp/custom-plugins/ez-dashboard -L lisp/custom-plugins/ez-agents \
;;     -L <elpa>/magit-section-... -l lisp/custom-plugins/ez-dashboard/test/ez-dashboard-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The chat-history tests need ez-agents-chats and skip themselves without it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ez-dashboard-sections)

(defconst ez-dashboard-test--root
  (expand-file-name "../../../.." (file-name-directory (or load-file-name buffer-file-name))))

;; Module data as my-modules.el keeps it; global defvars so `let' really binds them.
(defvar my-modules--order nil)
(defvar my-modules--table nil)

(defmacro ez-dashboard-test--with-data (&rest body)
  "Run BODY with fixed fake data behind every panel and column counting on."
  (declare (indent 0))
  `(let* ((now (float-time))
          (ez-dashboard--use-align nil)
          (ez-dashboard-name "Tester")
          (my-modules--order (list (cons :core 'a) (cons :core 'b) (cons :ui 'c) (cons :lang 'd)))
          (my-modules--table (let ((h (make-hash-table :test #'equal)))
                               (dolist (k my-modules--order) (puthash k (list :status 'loaded) h))
                               h))
          (ez-dashboard--chats
           (cons now (list (list :kind 'claude :id "a" :time (- now 120) :dir "/tmp/proj-one/"
                                 :title "Add a beautiful dashboard on starting emacs")
                           (list :kind 'codex :id "b" :time (- now 7200) :dir "/tmp/a-rather-long-project-name/"
                                 :title "Fix the flaky payments webhook retry logic")))))
     (cl-letf* (((symbol-function 'ez-dashboard--agents-ready-p) (lambda () t))
                ((symbol-function 'ez-dashboard--agent-sessions)
                 (lambda () (list (list :id "1" :status 'working :name "Claude Code"
                                        :project "lendville-admin" :since (- now 1500))
                                  (list :id "2" :status 'waiting :name "Codex"
                                        :project "metric_id" :since (- now 400)))))
                ((symbol-function 'ez-dashboard--usage-data)
                 (lambda () (list (cons "Claude Code"
                                        (list (list :label "5h" :percent 26 :reset (+ now 7200))
                                              (list :label "Week" :percent 71 :reset (+ now 400000))))
                                  (cons "Codex" (list (list :label "5h" :percent 92 :reset (+ now 3000)))))))
                ((symbol-function 'ez-dashboard--project-entries)
                 (lambda () (list (list :dir "/Users/x/dev/lendville-admin/" :name "lendville-admin"
                                        :branch "main" :last nil :agents 1)
                                  (list :dir "/Users/x/.emacs.d/" :name ".emacs.d"
                                        :branch "feature/dashboard" :last t :agents 0))))
                ((symbol-function 'ez-dashboard--recent-files)
                 (lambda () '("/Users/x/.emacs.d/init.el" "/Users/x/notes/todo.org"))))
       ,@body)))

(defun ez-dashboard-test--text (lines)
  (mapcar #'substring-no-properties lines))

;;;; Page layout

(ert-deftest ez-dashboard-no-line-is-wider-than-the-window ()
  (ez-dashboard-test--with-data
    (dolist (w '(50 60 80 100 140 200))
      (dolist (line (ez-dashboard-test--text (ez-dashboard--page w)))
        (should (<= (string-width line) w))))))

(ert-deftest ez-dashboard-two-sections-share-a-row-only-when-wide ()
  (ez-dashboard-test--with-data
    (let ((wide (ez-dashboard-test--text (ez-dashboard--page 140)))
          (narrow (ez-dashboard-test--text (ez-dashboard--page 60))))
      (should (cl-some (lambda (l) (and (string-match-p "Recent projects" l)
                                        (string-match-p "Recent conversations" l)))
                       wide))
      (should-not (cl-some (lambda (l) (and (string-match-p "Recent projects" l)
                                            (string-match-p "Recent conversations" l)))
                           narrow))
      ;; both titles still exist when stacked
      (should (cl-some (lambda (l) (string-match-p "Recent conversations" l)) narrow)))))

(ert-deftest ez-dashboard-content-is-centred ()
  (ez-dashboard-test--with-data
    (let* ((lines (ez-dashboard-test--text (ez-dashboard--page 200)))
           (title (cl-find-if (lambda (l) (string-match-p "Agents  a" l)) lines)))
      (should (> (string-match "[^ ]" title) 30)))))

(ert-deftest ez-dashboard-tiles-share-one-row-when-wide-and-wrap-without-orphans ()
  (ez-dashboard-test--with-data
    (let ((wide (ez-dashboard-test--text (ez-dashboard--page 140))))
      ;; first and last tile on the same line: one row of six
      (should (= 1 (cl-count-if (lambda (l) (and (string-match-p "Startup" l)
                                                 (string-match-p "Agents" l)))
                                wide))))
    ;; at 100 columns the six tiles wrap 3 + 3, never 5 + 1.  A tile label line
    ;; starts every tile with the accent bar, so count bars on those lines.
    (let* ((mid (ez-dashboard-test--text (ez-dashboard--page 100)))
           (labels (cl-remove-if-not
                    (lambda (l) (and (string-match-p "▎ . \\(Startup\\|Packages\\|Modules\\|Plugins\\|Emacs\\|Agents\\)" l)))
                    mid)))
      (should (= 2 (length labels)))
      (dolist (l labels)
        (should (= 3 (cl-count ?▎ l)))))))

(ert-deftest ez-dashboard-icons-keep-their-font-in-tiles-and-titles ()
  "An icon drawn without its own font face shows as an empty box."
  (skip-unless (and (require 'nerd-icons nil t) (fboundp 'nerd-icons-mdicon)))
  (ez-dashboard-test--with-data
    (cl-flet ((icon-family (line)
                (let ((i (cl-position-if (lambda (c) (>= c #xF0000)) line)))
                  (should i)
                  (let ((face (get-text-property i 'face line)))
                    (cl-labels ((family (f)
                                  (cond ((and (consp f) (keywordp (car f))) (plist-get f :family))
                                        ((consp f) (cl-some #'family f)))))
                      (family face))))))
      ;; a stat tile
      (let ((rows (ez-dashboard--cards-row (list (ez-dashboard--tile-startup)) 40 0)))
        (should (equal (icon-family (nth 1 rows)) nerd-icons-font-family)))
      ;; a section title
      (should (equal (icon-family (car (ez-dashboard--section-lines 'agents 60)))
                     nerd-icons-font-family)))))

(ert-deftest ez-dashboard-header-greets-by-name ()
  (ez-dashboard-test--with-data
    (should (cl-some (lambda (l) (string-match-p ", Tester" l))
                     (ez-dashboard-test--text (ez-dashboard--page 100))))))

(ert-deftest ez-dashboard-a-failing-section-does-not-break-the-page ()
  (ez-dashboard-test--with-data
    (let ((saved (copy-tree ez-dashboard-sections)))
      (unwind-protect
          (progn
            (ez-dashboard-define-section 'files "Recent files" "" (lambda (_w) (error "Boom")) "f")
            (let ((text (ez-dashboard-test--text (ez-dashboard--page 100))))
              (should (cl-some (lambda (l) (string-match-p "error: Boom" l)) text))
              (should (cl-some (lambda (l) (string-match-p "Recent projects" l)) text))))
        (setq ez-dashboard-sections saved)))))

(ert-deftest ez-dashboard-align-mode-places-columns-with-display-specs ()
  (ez-dashboard-test--with-data
    (let* ((ez-dashboard--use-align t)
           (lines (ez-dashboard--page 140))
           (title (cl-find-if (lambda (l) (string-match-p "Recent projects" l)) lines)))
      (should (cl-some (lambda (i) (let ((d (get-text-property i 'display title)))
                                     (and (consp d) (eq (car d) 'space) (plist-get (cdr d) :align-to))))
                       (number-sequence 0 (1- (length title))))))))

;;;; Pure renderers

(ert-deftest ez-dashboard-ago ()
  (let ((now (float-time)))
    (should (equal (ez-dashboard--ago (- now 5)) "now"))
    (should (equal (ez-dashboard--ago (- now 125)) "2m"))
    (should (equal (ez-dashboard--ago (- now 7300)) "2h"))
    (should (equal (ez-dashboard--ago (- now (* 3 86400))) "3d"))))

(ert-deftest ez-dashboard-bar-has-the-requested-width-and-colours ()
  (dolist (p '(0 26 60 85 100 140))
    (should (= 10 (string-width (ez-dashboard--bar p 10)))))
  (should (eq (get-text-property 0 'face (ez-dashboard--bar 30 10)) 'success))
  (should (eq (get-text-property 0 'face (ez-dashboard--bar 70 10)) 'warning))
  (should (eq (get-text-property 0 'face (ez-dashboard--bar 95 10)) 'error)))

(ert-deftest ez-dashboard-usage-line-shows-name-bars-and-percent ()
  (let* ((now (float-time))
         (wide (substring-no-properties
                (ez-dashboard--usage-line "Claude Code"
                                          (list (list :label "5h" :percent 26 :reset (+ now 7200))
                                                (list :label "Week" :percent 71))
                                          90 12)))
         (narrow (substring-no-properties
                  (ez-dashboard--usage-line "Codex" (list (list :label "5h" :percent 9 :reset (+ now 60)))
                                            40))))
    (should (string-match-p "\\`Claude Code +5h +[━─]+ +26% ↻" wide))
    (should (string-match-p "Week +[━─]+ +71%" wide))
    (should-not (string-match-p "↻" narrow))
    (should (<= (string-width narrow) 40))))

(ert-deftest ez-dashboard-agent-counts ()
  (let ((counts (ez-dashboard--agent-counts
                 (list (list :status 'working) (list :status 'starting) (list :status 'waiting)
                       (list :status 'idle) (list :status 'done) (list :status 'error)))))
    (should (equal (alist-get 'working counts) 2))
    (should (equal (alist-get 'waiting counts) 1))
    (should (equal (alist-get 'idle counts) 1))
    (should (equal (alist-get 'ended counts) 2))))

(ert-deftest ez-dashboard-agents-panel-states ()
  (ez-dashboard-test--with-data
    (should (equal (substring-no-properties (car (ez-dashboard--agents-lines nil nil nil nil 60)))
                   "loading…"))
    (let ((lines (ez-dashboard-test--text (ez-dashboard--agents-section 80))))
      (should (string-match-p "1 working" (car lines)))
      (should (cl-some (lambda (l) (string-match-p "Claude Code +lendville-admin" l)) lines))
      (should (cl-some (lambda (l) (string-match-p "Codex +metric_id" l)) lines)))
    (cl-letf (((symbol-function 'ez-dashboard--agent-sessions) (lambda () nil))
              ((symbol-function 'ez-dashboard--usage-data) (lambda () nil)))
      (should (cl-some (lambda (l) (string-match-p "No agents running" l))
                       (ez-dashboard-test--text (ez-dashboard--agents-section 80)))))))

(ert-deftest ez-dashboard-project-lines ()
  (let* ((entries (list (list :dir "/Users/x/dev/lendville-admin/" :name "lendville-admin"
                              :branch "main" :last nil :agents 1)
                        (list :dir "/Users/x/.emacs.d/" :name ".emacs.d" :branch nil :last t :agents 0)))
         (wide (ez-dashboard-test--text (ez-dashboard--project-lines entries 90)))
         (narrow (ez-dashboard-test--text (ez-dashboard--project-lines entries 36))))
    (should (string-match-p "▸ lendville-admin +main +● 1 +.*lendville-admin" (car wide)))
    (should (string-prefix-p "★ " (cadr wide)))
    (should-not (cl-some (lambda (l) (string-match-p "/Users/" l)) narrow))
    (should (equal (ez-dashboard-test--text (ez-dashboard--project-lines nil 60))
                   '("No projects yet: open one with SPC p p")))
    (should (functionp (get-text-property 3 'ez-dashboard-action
                                          (car (ez-dashboard--project-lines entries 90)))))))

(ert-deftest ez-dashboard-chat-lines-align-and-truncate ()
  (let* ((now (float-time))
         (chats (list (list :kind 'claude :id "a" :time (- now 90) :dir "/tmp/proj/"
                            :title "A very long conversation title that has to be cut somewhere sensible")
                      (list :kind 'codex :id "b" :time (- now 7300) :dir "/tmp/other-project-name-long/"
                            :title "Short")))
         (lines (ez-dashboard-test--text (ez-dashboard--chat-lines chats 60))))
    (should (string-prefix-p "✱ " (car lines)))
    (should (string-prefix-p "◇ " (cadr lines)))
    (should (string-match-p "…" (car lines)))
    (dolist (l lines) (should (<= (string-width l) 60)))
    ;; ages end at the same column
    (should (= (length (string-trim-right (car lines))) (length (string-trim-right (cadr lines)))))
    (should (equal (ez-dashboard-test--text (ez-dashboard--chat-lines :loading 60)) '("loading…")))
    (should (string-match-p "No conversations" (car (ez-dashboard--chat-lines nil 60))))))

(ert-deftest ez-dashboard-file-lines ()
  (let ((lines (ez-dashboard-test--text (ez-dashboard--file-lines '("/a/b/init.el" "/x/y/todo.org") 70))))
    (should (string-match-p "init\\.el +/a/b/" (car lines)))
    (should (string-match-p "todo\\.org" (cadr lines)))))

(ert-deftest ez-dashboard-config-lines ()
  (let* ((info (list :total 3 :categories '((:core . 2) (:ui . 1)) :failed '((:ui . broken))))
         (lines (ez-dashboard-test--text (ez-dashboard--config-lines info '("ez-agents" "ez-flutter") 70))))
    (should (string-match-p "core 2 +ui 1" (car lines)))
    (should (cl-some (lambda (l) (string-match-p "failed: ui/broken" l)) lines))
    (should (cl-some (lambda (l) (string-match-p "Plugins +ez-agents · ez-flutter" l)) lines))
    (should (cl-some (lambda (l) (string-match-p "modules\\.el +module report +install guide" l)) lines))))

(ert-deftest ez-dashboard-reset-text-does-not-depend-on-the-locale ()
  (let ((today-pm (let ((d (decode-time))) (setf (decoded-time-hour d) 15 (decoded-time-minute d) 5)
                       (float-time (encode-time d)))))
    (should (equal (ez-dashboard--reset-text today-pm) "3:05pm"))
    (should (string-match-p "\\`[A-Z][a-z][a-z] [0-9]+\\'"
                            (ez-dashboard--reset-text (+ (float-time) (* 5 86400)))))))

;;;; Data gathering

(ert-deftest ez-dashboard-git-head ()
  (let ((dir (make-temp-file "ezd-git" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir))
          (with-temp-file (expand-file-name ".git/HEAD" dir) (insert "ref: refs/heads/feature/x\n"))
          (should (equal (ez-dashboard--git-head dir) "feature/x"))
          (with-temp-file (expand-file-name ".git/HEAD" dir) (insert "0123456789abcdef0123456789abcdef01234567\n"))
          (should (equal (ez-dashboard--git-head dir) "0123456"))
          (should-not (ez-dashboard--git-head (make-temp-file "ezd-none" t))))
      (delete-directory dir t))))

(ert-deftest ez-dashboard-git-head-follows-a-worktree-file ()
  (let ((dir (make-temp-file "ezd-wt" t)) (gd (make-temp-file "ezd-gd" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".git" dir) (insert "gitdir: " gd "\n"))
          (with-temp-file (expand-file-name "HEAD" gd) (insert "ref: refs/heads/wt-branch\n"))
          (should (equal (ez-dashboard--git-head dir) "wt-branch")))
      (delete-directory dir t) (delete-directory gd t))))

(ert-deftest ez-dashboard-chat-scan-reads-both-agents-and-drops-dead-directories ()
  (skip-unless (require 'ez-agents-chats nil t))
  (let* ((home (make-temp-file "ezd-home" t))
         (alive (make-temp-file "ezd-alive" t))
         (claude (expand-file-name "claude" home))
         (codex (expand-file-name "codex" home))
         (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" claude)
                                            (concat "CODEX_HOME=" codex))
                                      process-environment))
         (ez-dashboard-chat-ignore-regexp nil)   ; the fixtures live in the temp dir
         (ez-dashboard-list-length 5))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "projects/-p1" claude) t)
          (make-directory (expand-file-name "sessions/2026/11/01" codex) t)
          (cl-flet ((claude-chat (id cwd text age)
                      (let ((f (expand-file-name (concat "projects/-p1/" id ".jsonl") claude)))
                        (with-temp-file f
                          (insert (json-serialize (list :type "user" :cwd cwd :sessionId id
                                                        :message (list :role "user" :content text)))
                                  "\n"))
                        (set-file-times f (time-subtract (current-time) age)))))
            (claude-chat "c-new" alive "Fix the build" 60)
            (claude-chat "c-old" alive "Older thing" 7200)
            (claude-chat "c-dead" "/nonexistent/dir/zzz" "Dead directory chat" 30))
          (let ((f (expand-file-name "sessions/2026/11/01/rollout-2026-11-01T00-00-00-abc.jsonl" codex)))
            (with-temp-file f
              (insert (json-serialize (list :type "session_meta"
                                            :payload (list :id "cx-1" :cwd alive)))
                      "\n"
                      (json-serialize (list :type "response_item"
                                            :payload (list :role "user" :type "message"
                                                           :content (vector (list :type "input_text" :text "Write the migration")))))
                      "\n"))
            (set-file-times f (time-subtract (current-time) 600)))
          (let* ((chats (ez-dashboard--scan-chats))
                 (ids (mapcar (lambda (c) (plist-get c :id)) chats)))
            (should (equal ids '("c-new" "cx-1" "c-old")))
            (should-not (member "c-dead" ids))
            (should (equal (plist-get (car chats) :title) "Fix the build"))
            (should (eq (plist-get (cadr chats) :kind) 'codex))
            (should (equal (plist-get (car chats) :dir) (file-name-as-directory alive)))))
      (delete-directory home t) (delete-directory alive t))))

(ert-deftest ez-dashboard-chats-in-temp-directories-are-ignored-by-default ()
  (let ((dir (make-temp-file "ezd-ign" t)))
    (unwind-protect
        (progn
          (should-not (ez-dashboard--chat-dir-ok-p dir))               ; under the temp dir
          (should-not (ez-dashboard--chat-dir-ok-p "/tmp/anything"))
          (should-not (ez-dashboard--chat-dir-ok-p "/nonexistent/zzz"))
          (should (ez-dashboard--chat-dir-ok-p (expand-file-name "~")))
          (let ((ez-dashboard-chat-ignore-regexp nil))
            (should (ez-dashboard--chat-dir-ok-p dir))))
      (delete-directory dir t))))

(ert-deftest ez-dashboard-projects-with-the-same-name-show-their-parent ()
  (let* ((entries (list (list :dir "/Users/x/development/flutter/metric_id/" :name "metric_id"
                              :branch "main" :last nil :agents 0)
                        (list :dir "/Users/x/development/rails/metric_id/" :name "metric_id"
                              :branch "main" :last nil :agents 0)
                        (list :dir "/Users/x/development/web/solo/" :name "solo"
                              :branch "dev" :last nil :agents 0)))
         (lines (ez-dashboard-test--text (ez-dashboard--project-lines entries 70))))
    (should (string-match-p "metric_id (flutter)" (nth 0 lines)))
    (should (string-match-p "metric_id (rails)" (nth 1 lines)))
    (should (string-match-p "▸ solo +dev" (nth 2 lines)))
    (should-not (string-match-p "solo (" (nth 2 lines)))))

;;;; Interaction

(defmacro ez-dashboard-test--in-buffer (&rest body)
  (declare (indent 0))
  `(ez-dashboard-test--with-data
     (let ((ez-dashboard--timer t))
       (unwind-protect
           (progn (ez-dashboard-buffer)
                  (with-current-buffer ez-dashboard-buffer-name
                    ,@body))
         (when (get-buffer ez-dashboard-buffer-name) (kill-buffer ez-dashboard-buffer-name))))))

(ert-deftest ez-dashboard-items-can-be-walked-and-activated ()
  (let ((ez-dashboard-fill-function nil) (hits nil))
    (ez-dashboard-test--in-buffer
      (goto-char (point-min))
      (ez-dashboard-next-item)
      (should (ez-dashboard--item-at))
      (let ((first (ez-dashboard--item-at)))
        (ez-dashboard-next-item)
        (should-not (eql first (ez-dashboard--item-at)))
        (ez-dashboard-previous-item)
        (should (eql first (ez-dashboard--item-at))))
      ;; activating runs the item's action
      (let ((inhibit-read-only t))
        (put-text-property (point) (1+ (point)) 'ez-dashboard-action (lambda () (push 'ran hits))))
      (ez-dashboard-activate)
      (should (equal hits '(ran))))))

(defmacro ez-dashboard-test--in-buffer-width (width &rest body)
  "Like `ez-dashboard-test--in-buffer' but drawn for a window WIDTH columns wide."
  (declare (indent 1))
  `(ez-dashboard-test--with-data
     (let ((ez-dashboard--timer t) (ez-dashboard-fill-function nil))
       (unwind-protect
           (with-current-buffer (get-buffer-create ez-dashboard-buffer-name)
             (ez-dashboard-mode)
             (setq ez-dashboard--last-width ,width)
             (ez-dashboard-refresh)
             ,@body)
         (when (get-buffer ez-dashboard-buffer-name) (kill-buffer ez-dashboard-buffer-name))))))

(defun ez-dashboard-test--line ()
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(ert-deftest ez-dashboard-two-column-navigation-walks-one-section-at-a-time ()
  (ez-dashboard-test--in-buffer-width 140
    ;; the jump key lands on the CONVERSATION, not on the project beside it
    (ez-dashboard-goto-section 'chats)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "a"))
    (should (string-match-p "Add a beautiful dashboard" (ez-dashboard-test--line)))
    ;; j walks down the chats column ...
    (ez-dashboard-next-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "b"))
    ;; ... and k goes back up it
    (ez-dashboard-previous-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "a"))
    ;; the project column is walked on its own, then the next section follows
    (ez-dashboard-goto-section 'projects)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "/Users/x/dev/lendville-admin/"))
    (ez-dashboard-next-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "/Users/x/.emacs.d/"))
    (ez-dashboard-next-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "a"))))

(ert-deftest ez-dashboard-a-multi-line-tile-is-a-single-stop ()
  (ez-dashboard-test--in-buffer-width 140
    (goto-char (point-min))
    (ez-dashboard-next-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "Modules"))
    (ez-dashboard-next-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "Agents"))
    ;; the next stop is in the agents section, not the Modules tile's second line
    (ez-dashboard-next-item)
    (should-not (member (get-text-property (point) 'ez-dashboard-id) '("Modules" "Agents")))
    (should (eq (get-text-property (point) 'ez-dashboard-in) 'agents))
    ;; and k walks back through them in order
    (ez-dashboard-previous-item)
    (should (equal (get-text-property (point) 'ez-dashboard-id) "Agents"))))

(ert-deftest ez-dashboard-navigation-stops-at-the-ends ()
  (ez-dashboard-test--in-buffer-width 100
    (goto-char (point-min))
    (ez-dashboard-previous-item)             ; nothing before the first item
    (should (= (point) (point-min)))
    (goto-char (point-max))
    (ez-dashboard-next-item)                 ; nothing after the last
    (should (= (point) (point-max)))))

(ert-deftest ez-dashboard-section-jump-keys-reach-their-section ()
  (let ((ez-dashboard-fill-function nil))
    (ez-dashboard-test--in-buffer
      (ez-dashboard-goto-section 'chats)
      (should (string-match-p "Add a beautiful dashboard"
                              (buffer-substring (line-beginning-position) (line-end-position))))
      (ez-dashboard-goto-section 'projects)
      (should (string-match-p "lendville-admin"
                              (buffer-substring (line-beginning-position) (line-end-position)))))))

(ert-deftest ez-dashboard-refresh-keeps-point-on-the-same-item ()
  (let ((ez-dashboard-fill-function nil))
    (ez-dashboard-test--in-buffer
      (ez-dashboard-goto-section 'chats)
      (let ((id (get-text-property (point) 'ez-dashboard-id)))
        (should id)
        (ez-dashboard-refresh)
        (should (equal id (get-text-property (point) 'ez-dashboard-id)))))))

(ert-deftest ez-dashboard-section-keys-are-bound-in-the-mode-map ()
  (dolist (k '("a" "p" "c" "f" "s" "m"))
    (should (commandp (lookup-key ez-dashboard-mode-map k))))
  (dolist (k '("j" "k" "g" "q" "?" "RET"))
    (should (lookup-key ez-dashboard-mode-map (kbd k)))))

(ert-deftest ez-dashboard-opening-queues-the-slow-fill-instead-of-running-it ()
  (let* ((queued nil)
         (ez-dashboard-defer-function (lambda (thunk) (push thunk queued)))
         (ez-dashboard-fill-function (lambda () (error "Must not run during the first paint"))))
    (ez-dashboard-test--in-buffer
      (should (= 1 (length queued))))))

;;;; The startup path

(ert-deftest ez-dashboard-first-paint-does-not-load-ez-agents ()
  "A fresh Emacs must paint the page without loading the agent plugin."
  (let* ((root ez-dashboard-test--root)
         (out (with-temp-buffer
                (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                              "-Q" "--batch" "--eval" "(setq load-prefer-newer t)"
                              "-L" (expand-file-name "lisp/custom-plugins/ez-dashboard" root)
                              "--eval" "(progn (require 'ez-dashboard-sections) (ez-dashboard--page 100) (princ (list (featurep 'ez-agents) (featurep 'ez-agents-usage) (featurep 'ez-agents-chats))))")
                (buffer-string))))
    (should (string-match-p "(nil nil nil)" out))))

;;;; The module's initial-buffer logic

;; The module only declares this variable locally; make it really special here
;; so the tests' `let' bindings reach the module's code.
(defvar my/start-in-last-project nil)

(defun ez-dashboard-test--load-module ()
  "Load my-tools-dashboard.el with its config dependencies stubbed."
  (require 'use-package)
  (unless (fboundp 'my/leader) (defun my/leader (&rest _)))
  (unless (fboundp 'my/after-startup-idle) (defun my/after-startup-idle (&rest _)))
  (load (expand-file-name "lisp/tools/my-tools-dashboard.el" ez-dashboard-test--root) nil t))

(ert-deftest ez-dashboard-initial-buffer-rules ()
  (ez-dashboard-test--load-module)
  (let ((file-buf (generate-new-buffer "file-buf")))
    (unwind-protect
        (progn
          (with-current-buffer file-buf (setq buffer-file-name "/tmp/ezd-fake.txt"))
          ;; at startup with a file on the command line: that file, not the dashboard
          ;; (any file buffer will do: ERT itself may have visited this test file)
          (let ((my/dashboard--startup-done nil) (my/start-in-last-project nil))
            (should (buffer-file-name (my/dashboard-initial-buffer))))
          ;; the opt-in last-project mode keeps *scratch*
          (let ((my/dashboard--startup-done nil) (my/start-in-last-project t))
            (should (equal (buffer-name (my/dashboard-initial-buffer)) "*scratch*")))
          ;; later (a new emacsclient frame): the dashboard, even with files open
          (let ((my/dashboard--startup-done t) (my/start-in-last-project nil)
                (ez-dashboard-fill-function nil) (ez-dashboard--timer t))
            (let ((b (my/dashboard-initial-buffer)))
              (should (buffer-live-p b))
              (should (equal (buffer-name b) ez-dashboard-buffer-name))
              (kill-buffer b))))
      (with-current-buffer file-buf (setq buffer-file-name nil))
      (kill-buffer file-buf))))

(ert-deftest ez-dashboard-initial-buffer-is-always-live ()
  (ez-dashboard-test--load-module)
  (let ((my/dashboard--startup-done nil) (my/start-in-last-project nil)
        (ez-dashboard-fill-function nil) (ez-dashboard--timer t))
    (should (buffer-live-p (my/dashboard-initial-buffer)))
    (when (get-buffer ez-dashboard-buffer-name) (kill-buffer ez-dashboard-buffer-name))))

(provide 'ez-dashboard-test)
;;; ez-dashboard-test.el ends here
