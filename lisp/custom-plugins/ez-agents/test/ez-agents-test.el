;;; ez-agents-test.el --- Tests for ez-agents -*- lexical-binding: t; -*-

;; Run: emacs --batch -L lisp/custom-plugins -L <elpa>/magit-section-* \
;;        -l lisp/custom-plugins/test/ez-agents-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
;; Never write state or logs into the user's real directories while testing.
(defvar ez-agents-data-directory)
(setq ez-agents-data-directory (make-temp-file "ez-agents-test-data" t))
(defvar ghostel-kill-buffer-on-exit)
(require 'ez-agents)
(require 'ez-agents-dashboard)

(defmacro ez-agents-test--with-session (var &rest body)
  "Run BODY with VAR bound to a fresh terminal-less session."
  (declare (indent 1))
  `(let ((ez-agents--table (make-hash-table :test #'equal))
         (ez-agents-notify-function #'ignore)
         (ez-agents-change-hook nil))
     (let ((,var (ez-agent--create :id "a1" :kind 'claude :project "/tmp/proj/"
                                   :name "Claude Code" :status 'starting
                                   :started (float-time) :activity (float-time))))
       (puthash "a1" ,var ez-agents--table)
       (ignore ,var)
       ,@body)))

(defun ez-agents-test--payload (alist)
  (base64-encode-string (encode-coding-string (json-serialize alist) 'utf-8) t))

(ert-deftest ez-agents-event-status-transitions ()
  (ez-agents-test--with-session s
    (should (equal (ez-agents-event "a1" "UserPromptSubmit") "ok"))
    (should (eq (ez-agent-status s) 'working))
    (ez-agents-event "a1" "Notification")
    (should (eq (ez-agent-status s) 'waiting))
    (ez-agents-event "a1" "Stop")
    (should (eq (ez-agent-status s) 'idle))
    (should (ez-agent-hook-p s))))

(ert-deftest ez-agents-event-unknown-session ()
  (ez-agents-test--with-session s
    (should (equal (ez-agents-event "nope" "Stop") "unknown"))))

(ert-deftest ez-agents-notifies-on-waiting ()
  (ez-agents-test--with-session s
    (let (notified)
      (let ((ez-agents-notify-function (lambda (x) (push x notified))))
        (ez-agents-event "a1" "Notification")
        (ez-agents-event "a1" "Notification"))
      (should (equal notified (list s))))))

(ert-deftest ez-agents-subagent-lifecycle ()
  (ez-agents-test--with-session s
    (let ((pre (ez-agents-test--payload
                '((tool_name . "Task") (tool_use_id . "toolu_1")
                  (tool_input . ((description . "explore auth"))))))
          (post (ez-agents-test--payload
                 '((tool_name . "Task") (tool_use_id . "toolu_1")))))
      (ez-agents-event "a1" "PreToolUse" pre)
      (let ((subs (ez-agents-sessions "a1")))
        (should (= (length subs) 1))
        (should (equal (ez-agent-name (car subs)) "explore auth"))
        (should (eq (ez-agent-status (car subs)) 'working)))
      (ez-agents-event "a1" "PostToolUse" post)
      (should (eq (ez-agent-status (car (ez-agents-sessions "a1"))) 'done))
      (should (eq (ez-agent-status s) 'working)))))

(ert-deftest ez-agents-stop-finishes-running-subagents ()
  (ez-agents-test--with-session s
    (ez-agents-event "a1" "PreToolUse"
                     (ez-agents-test--payload
                      '((tool_name . "Agent") (tool_use_id . "toolu_2"))))
    (ez-agents-event "a1" "Stop")
    (should (eq (ez-agent-status (car (ez-agents-sessions "a1"))) 'done))))

(ert-deftest ez-agents-remove-drops-children ()
  (ez-agents-test--with-session s
    (ez-agents--add-sub s "sub:x" "child" 'hook)
    (ez-agents--remove "a1")
    (should (zerop (hash-table-count ez-agents--table)))))

(ert-deftest ez-agents-hooks-install-is-idempotent-and-reversible ()
  (let* ((root (make-temp-file "ez-agents" t))
         (file (ez-agents--settings-file root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert "{\"permissions\":{\"allow\":[\"Bash(ls)\"]},\"hooks\":{\"Stop\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"echo mine\"}]}]}}"))
          (ez-agents-install-hooks root)
          (ez-agents-install-hooks root)
          (should (ez-agents-hooks-installed-p root))
          (let* ((s (ez-agents--read-settings file))
                 (stop (gethash "Stop" (gethash "hooks" s))))
            (should (= (length stop) 2))   ; user's hook + exactly one of ours
            (should (gethash "permissions" s)))
          (ez-agents-uninstall-hooks root)
          (should-not (ez-agents-hooks-installed-p root))
          (let ((s (ez-agents--read-settings file)))
            (should (= (length (gethash "Stop" (gethash "hooks" s))) 1))
            (should (gethash "permissions" s))))
      (delete-directory root t))))

(ert-deftest ez-agents-tail-returns-last-nonblank-lines ()
  (ez-agents-test--with-session s
    (with-temp-buffer
      (insert "one\n\n  \ntwo  \nthree\n")
      (setf (ez-agent-buffer s) (current-buffer))
      (should (equal (ez-agents-tail s 2) '("two" "three")))
      (should (equal (ez-agents-tail s) '("one" "two" "three"))))))

(ert-deftest ez-agents-resolve-target-filters-and-scopes ()
  (ez-agents-test--with-session s
    (let ((b (ez-agent--create :id "a2" :kind 'codex :project "/tmp/other/" :name "Codex"
                               :status 'waiting :started (float-time) :activity (float-time))))
      (puthash "a2" b ez-agents--table)
      (ez-agents--add-sub s "sub:z" "child" 'hook)
      (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t)))
        (should (equal (mapcar #'ez-agent-id (ez-agents-resolve-target 'all)) '("a1" "a2")))
        (should (equal (mapcar #'ez-agent-id (ez-agents-resolve-target 'waiting)) '("a2")))
        (should (equal (mapcar #'ez-agent-id (ez-agents-resolve-target '(project . "/tmp/proj/"))) '("a1")))
        ;; a sub-agent target resolves to its parent terminal
        (should (equal (mapcar #'ez-agent-id (ez-agents-resolve-target '(session . "sub:z"))) '("a1"))))
      (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) nil)))
        (should-not (ez-agents-resolve-target 'all))))))

(ert-deftest ez-agents-resolve-target-ids ()
  (ez-agents-test--with-session s
    (puthash "a2" (ez-agent--create :id "a2" :kind 'codex :project "/tmp/o/" :name "Codex"
                                    :status 'idle :started (float-time) :activity (float-time))
             ez-agents--table)
    (ez-agents--add-sub s "sub:q" "child" 'hook)
    (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t)))
      ;; sub-agent ids collapse onto their parent; duplicates and unknown ids drop;
      ;; first-seen order is kept
      (should (equal (mapcar #'ez-agent-id (ez-agents-resolve-target '(ids "a2" "sub:q" "a1" "gone")))
                     '("a2" "a1")))
      (should (equal (ez-agents-target-label '(ids "a1" "a2")) "2 selected agents")))))

(ert-deftest ez-agents-dashboard-filters ()
  (ez-agents-test--with-session s
    (let ((ez-agents-dashboard--status-filter nil) (ez-agents-dashboard--query nil))
      (should (ez-agents-dashboard--match-p s))
      (setq ez-agents-dashboard--status-filter 'waiting)
      (should-not (ez-agents-dashboard--match-p s))
      (setf (ez-agent-status s) 'waiting)
      (should (ez-agents-dashboard--match-p s))
      (setq ez-agents-dashboard--query "CLAUDE")          ; case-insensitive, matches name
      (should (ez-agents-dashboard--match-p s))
      (setq ez-agents-dashboard--query "proj")            ; matches project name
      (should (ez-agents-dashboard--match-p s))
      (setq ez-agents-dashboard--query "nothing-like-this")
      (should-not (ez-agents-dashboard--match-p s)))))

(ert-deftest ez-agents-dashboard-marks-and-bulk-actions ()
  (ez-agents-test--with-session s
    (let ((ez-agents-dashboard--marked (make-hash-table :test #'equal))
          sent)
      (puthash "a1" t ez-agents-dashboard--marked)
      (puthash "ghost" t ez-agents-dashboard--marked)
      (should (equal (mapcar #'ez-agent-id (ez-agents-dashboard--live-marks)) '("a1")))
      (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t))
                ((symbol-function 'ez-agents-send-raw) (lambda (x k) (push (cons (ez-agent-id x) k) sent))))
        (ez-agents-dashboard-approve)
        (ez-agents-dashboard-deny))
      (should (equal (reverse sent) '(("a1" . "\r") ("a1" . "\e"))))
      (ez-agents-dashboard--prune-marks)
      (should-not (gethash "ghost" ez-agents-dashboard--marked)))))

(require 'ez-agents-persist)

(defmacro ez-agents-test--with-tmux (&rest body)
  "Run BODY against a throwaway tmux server; skip when tmux is missing."
  (declare (indent 0))
  `(progn
     (skip-unless (executable-find "tmux"))
     (let ((ez-agents-tmux-socket (format "ez-agents-test-%d" (emacs-pid)))
           (ez-agents-data-directory (make-temp-file "ez-agents-state" t)))
       (unwind-protect (progn ,@body)
         (ez-agents--tmux "kill-server")
         (delete-directory ez-agents-data-directory t)))))

(ert-deftest ez-agents-tmux-session-survives-and-is-controllable ()
  (ez-agents-test--with-tmux
    (let ((name "ez-atest"))
      (should (eq 0 (car (ez-agents--tmux-new-session
                          name default-directory '("EZ_AGENT_SESSION=atest") "cat" nil))))
      (should (ez-agents--tmux-has-p name))
      (should (> (ez-agents--tmux-pane-pid name) 0))
      ;; typed text (CR -> Enter) reaches the process and shows in the pane
      (ez-agents--tmux-send-literal name "hello persistent world\r")
      (sleep-for 0.4)
      (should (cl-some (lambda (l) (string-match-p "hello persistent world" l))
                       (ez-agents--tmux-capture name 10)))
      ;; "closing Emacs" = the client going away; with no client the session lives on
      (should (member name (ez-agents--tmux-session-names)))
      (ez-agents--tmux "kill-session" "-t" (concat "=" name))
      (clrhash ez-agents--tmux-cache)           ; (answers are cached for a second)
      (should-not (ez-agents--tmux-has-p name)))))

(ert-deftest ez-agents-restore-rebuilds-sessions-from-state ()
  (ez-agents-test--with-tmux
    (let ((ez-agents--table (make-hash-table :test #'equal))
          (ez-agents-change-hook nil))
      (ez-agents--tmux-new-session "ez-alive1" default-directory nil "cat" nil)
      (let ((alive (ez-agent--create :id "alive1" :kind 'claude :project "/tmp/p/" :cwd "/tmp/p/"
                                     :name "Claude Code" :branch "agent/claude/x" :base "abc"
                                     :worktree t :tmux "ez-alive1" :started 100.0
                                     :notes '(("f.el" 3 "fix this")) :review-state 'changes
                                     :reviewed (let ((h (make-hash-table :test #'equal)))
                                                 (puthash "f.el" "deadbeef" h) h)))
            (dead (ez-agent--create :id "dead2" :kind 'codex :project "/tmp/p/" :cwd "/tmp/p/"
                                    :name "Codex" :tmux "ez-dead2" :started 200.0)))
        (puthash "alive1" alive ez-agents--table)
        (puthash "dead2" dead ez-agents--table)
        (ez-agents-save-state)
        (clrhash ez-agents--table)                      ; "Emacs restarted"
        (should (= 2 (ez-agents-restore t)))
        (let ((a (ez-agents-session "alive1")) (d (ez-agents-session "dead2")))
          (should (eq (ez-agent-status a) 'idle))
          (should (equal (ez-agent-branch a) "agent/claude/x"))
          (should (equal (ez-agent-notes a) '(("f.el" 3 "fix this"))))
          (should (equal (gethash "f.el" (ez-agent-reviewed a)) "deadbeef"))
          (should (eq (ez-agent-review-state a) 'changes))
          (should (> (ez-agent-pid a) 0))
          (should (eq (ez-agent-status d) 'done))       ; its tmux session never existed
          (should (ez-agents-live-p a))
          (should-not (ez-agents-live-p d)))))))

(require 'ez-agents-worktree)

(defmacro ez-agents-test--with-repo (&rest body)
  "Run BODY with REPO bound to a fresh git repo containing one commit."
  (declare (indent 0))
  `(let* ((tmp (file-name-as-directory (make-temp-file "ez-agents-git" t)))
          (repo (expand-file-name "proj/" tmp))
          (ez-agents-worktree-root (expand-file-name "wt" tmp))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (make-directory repo t)
           (ez-agents-git repo "init" "-q" "-b" "main")
           (with-temp-file (expand-file-name "a.txt" repo) (insert "one\ntwo\nthree\n"))
           (with-temp-file (expand-file-name "gone.txt" repo) (insert "bye\n"))
           (ez-agents-git repo "add" ".")
           (ez-agents-git repo "commit" "-q" "-m" "init")
           ,@body)
       (delete-directory tmp t))))

(ert-deftest ez-agents-worktree-lives-outside-repo-and-is-reversible ()
  (ez-agents-test--with-repo
    (let* ((base (ez-agents-git-head repo))
           (path (ez-agents-worktree-create repo "agent/claude/fix auth" base)))
      ;; separate folder, named after the repo, slugged branch
      (should (string-prefix-p (file-name-as-directory (expand-file-name ez-agents-worktree-root)) path))
      (should (string-match-p "/proj/agent-claude-fix-auth/\\'" path))
      (should (file-exists-p (expand-file-name "a.txt" path)))
      (should (equal (ez-agents-git-branch path) "agent/claude/fix-auth"))   ; sanitized
      ;; the worktree resolves back to the main repo
      (should (equal (ez-agents-git-main-root path) (ez-agents-git-root repo)))
      (should (= 2 (length (ez-agents-worktree-list repo))))
      ;; asking for the same branch again must not collide
      (let ((again (ez-agents-worktree-create repo "other" base)))
        (should-not (equal again path))
        (ez-agents-worktree-remove repo again))
      ;; dirty worktrees refuse removal without force
      (with-temp-file (expand-file-name "dirty.txt" path) (insert "x"))
      (should-error (ez-agents-worktree-remove repo path) :type 'user-error)
      (should (ez-agents-worktree-remove repo path t))
      (should-not (file-exists-p path))
      (should (= 1 (length (ez-agents-worktree-list repo)))))))

(ert-deftest ez-agents-worktree-branch-names-are-sanitized ()
  (should (equal (ez-agents-worktree-branch-name "agent/claude/fix auth") "agent/claude/fix-auth"))
  (should (equal (ez-agents-worktree-branch-name "  Fix: the bug!! ") "Fix-the-bug"))
  (should (equal (ez-agents-worktree-branch-name "a//b..c") "a/b.c"))
  (should (equal (ez-agents-worktree-branch-name "///") "agent/work")))

(ert-deftest ez-agents-worktree-reuses-existing-branch ()
  (ez-agents-test--with-repo
    (ez-agents-git repo "branch" "feature")
    (let ((path (ez-agents-worktree-create repo "feature" "main")))
      (should (equal (ez-agents-git-branch path) "feature"))
      ;; the same branch cannot be checked out twice
      (should-error (ez-agents-worktree-create repo "feature" "main") :type 'user-error))))

(ert-deftest ez-agents-git-changes-cover-committed-uncommitted-untracked ()
  (ez-agents-test--with-repo
    (let ((base (ez-agents-git-head repo)))
      (with-temp-file (expand-file-name "a.txt" repo) (insert "one\nTWO\nthree\nfour\n"))
      (delete-file (expand-file-name "gone.txt" repo))
      (ez-agents-git repo "commit" "-qam" "agent commit")
      (with-temp-file (expand-file-name "a.txt" repo) (insert "one\nTWO\nthree\nfour\nfive\n"))
      (with-temp-file (expand-file-name "new.txt" repo) (insert "x\ny\n"))
      (make-directory (expand-file-name ".claude" repo) t)
      (with-temp-file (expand-file-name ".claude/settings.local.json" repo) (insert "{}"))
      (let ((ch (ez-agents-git-changes repo base)))
        (should (equal (mapcar (lambda (c) (plist-get c :path)) ch)
                       '("a.txt" "gone.txt" "new.txt")))     ; hooks file ignored
        (should (equal (mapcar (lambda (c) (plist-get c :status)) ch) '("M" "D" "?"))))
      (let ((stat (ez-agents-git-diffstat repo base)))
        (should (equal (car stat) 3))                       ; files
        (should (> (nth 1 stat) 0)))                        ; lines added
      (should (string-match-p "^\\+five" (ez-agents-git-file-diff repo base "a.txt")))
      (should (string-match-p "^\\+x" (ez-agents-git-file-diff repo base "new.txt" t)))
      (should (null (ez-agents-git-string repo "diff" "--cached" "--name-only"))))))   ; index untouched

(require 'ez-agents-review)

(ert-deftest ez-agents-review-hunk-parsing-and-line-numbers ()
  (let* ((diff (concat "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n"
                       "@@ -10,4 +10,5 @@ ctx\n keep\n-old\n+new1\n+new2\n keep2\n"
                       "@@ -40,2 +41,2 @@\n a\n+b\n"))
         (hunks (ez-agents-review--parse-diff diff)))
    (should (= 2 (length hunks)))
    (should (= 10 (plist-get (car hunks) :start)))
    (should (equal (plist-get (car hunks) :lines)
                   '(" keep" "-old" "+new1" "+new2" " keep2")))
    ;; body line index -> line number in the new file (removed lines do not count)
    (should (= 10 (ez-agents-review--hunk-line (car hunks) 0)))   ; keep
    (should (= 11 (ez-agents-review--hunk-line (car hunks) 2)))   ; +new1 (after -old)
    (should (= 12 (ez-agents-review--hunk-line (car hunks) 3)))   ; +new2
    (should (= 42 (ez-agents-review--hunk-line (cadr hunks) 1))))) ; +b

(ert-deftest ez-agents-review-feedback-text-formats ()
  (let ((notes '(("src/a.el" 12 "handle nil") ("README.md" nil "document the flag"))))
    (let ((multi (ez-agents-review-feedback-text notes)))
      (should (string-match-p "1\\. src/a\\.el:12 — handle nil" multi))
      (should (string-match-p "2\\. README\\.md — document the flag" multi))
      (should (string-match-p "\n" multi)))
    (let ((one (ez-agents-review-feedback-text notes t)))
      (should-not (string-match-p "\n" one))
      (should (string-match-p " / 2\\. README" one)))))

(ert-deftest ez-agents-review-render-marks-notes-and-invalidation ()
  (ez-agents-test--with-repo
    (let* ((ez-agents--table (make-hash-table :test #'equal))
           (ez-agents-change-hook nil)
           (base (ez-agents-git-head repo))
           (s (ez-agent--create :id "r1" :kind 'claude :project repo :cwd repo :name "Claude Code"
                                :branch "main" :base base :started 1.0
                                :reviewed (make-hash-table :test #'equal))))
      (puthash "r1" s ez-agents--table)
      (with-temp-file (expand-file-name "a.txt" repo) (insert "one\nTWO\nthree\nfour\n"))
      (with-temp-file (expand-file-name "new.txt" repo) (insert "x\n"))
      (with-current-buffer (get-buffer-create "*review-test*")
        (ez-agents-review-mode)
        (setq ez-agents-review--session-id "r1")
        (ez-agents-review--render)
        (let ((text (buffer-string)))
          (should (string-match-p "2 files changed · 0/2 reviewed" text))
          (should (string-match-p "a\\.txt" text))
          (should (string-match-p "new\\.txt" text))
          (should (string-match-p "^\\+TWO" text)))
        ;; diffstat for the dashboard badge
        (should (equal (car (ez-agent-diffstat s)) 2))
        (should (ez-agents-review-needs-review-p s))
        ;; mark a.txt reviewed; it survives a re-render as reviewed
        (let ((f (cl-find "a.txt" ez-agents-review--files
                          :key (lambda (f) (plist-get f :path)) :test #'equal)))
          (ez-agents-review-mark s "a.txt" (plist-get f :hash) t))
        (ez-agents-review--render)
        (should (string-match-p "1/2 reviewed" (buffer-string)))
        ;; the agent edits the file again: the review mark must be void
        (with-temp-file (expand-file-name "a.txt" repo) (insert "one\nTWO\nthree\nfour\nfive\n"))
        (ez-agents-review--render)
        (should (string-match-p "0/2 reviewed" (buffer-string)))
        ;; notes show under the hunk and are counted
        (push (list "a.txt" 5 "why five?") (ez-agent-notes s))
        (ez-agents-review--render)
        (should (string-match-p "✎ line 5: why five\\?" (buffer-string)))
        (should (string-match-p "1 note" (buffer-string))))
      ;; approval is voided by new changes
      (setf (ez-agent-review-state s) 'approved)
      (with-temp-file (expand-file-name "later.txt" repo) (insert "more\n"))
      (should (ez-agents-review-refresh-stats s t))
      (should-not (ez-agent-review-state s)))))

(ert-deftest ez-agents-fullscreen-toggles-and-restores-layout ()
  (ez-agents-test--with-session s
    (let ((buf (generate-new-buffer "*agent-test*")) (ez-agents--zoom nil))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (setf (ez-agent-buffer s) buf)
            (let ((other (split-window-right)))
              (set-window-buffer other (get-buffer-create "*other-test*"))
              (set-window-dedicated-p other t)
              (let ((before (length (window-list))))
                (should (= before 2))
                (cl-letf (((symbol-function 'ez-agents-jump)
                           (lambda (_) (set-window-buffer (selected-window) buf))))
                  ;; on: only the agent's window is left
                  (ez-agents-toggle-fullscreen s)
                  (should (ez-agents-fullscreen-p))
                  (should (= 1 (length (window-list))))
                  (should (eq (window-buffer) buf))
                  ;; off: the saved layout is back, with its dedicated window
                  (ez-agents-toggle-fullscreen s)
                  (should-not (ez-agents-fullscreen-p))
                  (should (= before (length (window-list))))
                  (should (cl-some (lambda (w) (equal (buffer-name (window-buffer w)) "*other-test*"))
                                   (window-list)))))))
        (kill-buffer buf)
        (when (get-buffer "*other-test*") (kill-buffer "*other-test*"))))))

(ert-deftest ez-agents-fullscreen-finds-session-from-its-buffer ()
  (ez-agents-test--with-session s
    (with-temp-buffer
      (setf (ez-agent-buffer s) (current-buffer))
      (should (eq (ez-agents-current-session) s)))
    (should-not (ez-agents-current-session))))

(ert-deftest ez-agents-dashboard-keeps-point-across-redraws ()
  (let ((ez-agents--table (make-hash-table :test #'equal))
        (ez-agents-change-hook nil) (ez-agents-notify-function #'ignore)
        (tb (generate-new-buffer " *agent-out*"))
        (ez-agents-dashboard--collapsed (make-hash-table :test #'equal))
        (ez-agents-dashboard--marked (make-hash-table :test #'equal))
        (ez-agents-dashboard--expanded (make-hash-table :test #'equal))
        ez-agents-dashboard--status-filter ez-agents-dashboard--query)
    (with-current-buffer tb (insert "out one\nout two\n"))
    (dolist (spec '(("a1" "Claude Code" waiting) ("a2" "Codex" working)))
      (puthash (car spec) (ez-agent--create :id (car spec) :kind 'claude :project "/tmp/e/"
                                            :name (nth 1 spec) :status (nth 2 spec) :buffer tb
                                            :started (float-time) :activity (float-time))
               ez-agents--table))
    (ez-agents--add-sub (ez-agents-session "a2") "sub:1" "child task" 'hook)
    (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t)))
      (unwind-protect
          (with-current-buffer (get-buffer-create ez-agents-dashboard-buffer-name)
            (ez-agents-dashboard-mode)
            (ez-agents-dashboard--render)
            (cl-flet ((line-text () (buffer-substring-no-properties
                                     (line-beginning-position) (line-end-position)))
                      (goto-text (re) (goto-char (point-min)) (re-search-forward re)
                                 (beginning-of-line)))
              ;; opening the dashboard puts point on the first agent, not the cards
              (should (string-match-p "Claude Code" (line-text)))
              ;; an output line, a sub-agent row and the blank gap after a project
              ;; must each survive a redraw where they are (not snap to a heading)
              (dolist (re '("│ out one" "child task"))
                (goto-text re)
                (let ((before (line-number-at-pos)))
                  (ez-agents-dashboard--render)
                  (should (= before (line-number-at-pos)))
                  (should (string-match-p re (line-text)))))
              (goto-char (point-min))
              (re-search-forward "child task") (forward-line 1)   ; blank line after the project
              (should (string-empty-p (string-trim (line-text))))
              (let ((before (line-number-at-pos)))
                (ez-agents-dashboard--render)
                (should (= before (line-number-at-pos)))))
            (kill-buffer))
        (kill-buffer tb)))))

(ert-deftest ez-agents-workspace-dashboard-becomes-sidebar-beside-the-chat ()
  (let ((ez-agents--table (make-hash-table :test #'equal))
        (ez-agents-change-hook nil) (ez-agents-notify-function #'ignore)
        (ez-agents--workspace nil) (ez-agents--current-chat nil)
        (ez-agents--zoom nil)
        (ez-agents-dashboard--collapsed (make-hash-table :test #'equal))
        (ez-agents-dashboard--marked (make-hash-table :test #'equal))
        (ez-agents-dashboard--expanded (make-hash-table :test #'equal))
        ez-agents-dashboard--status-filter ez-agents-dashboard--query
        (chat1 (generate-new-buffer "*chat-1*")) (chat2 (generate-new-buffer "*chat-2*")))
    (puthash "a1" (ez-agent--create :id "a1" :kind 'claude :project "/tmp/e/" :name "Claude Code"
                                    :status 'working :buffer chat1 :started 1.0 :activity (float-time))
             ez-agents--table)
    (puthash "a2" (ez-agent--create :id "a2" :kind 'codex :project "/tmp/e/" :name "Codex"
                                    :status 'idle :buffer chat2 :started 2.0 :activity (float-time))
             ez-agents--table)
    (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t)))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (let ((dash (ez-agents-dashboard--ensure-buffer)))
              ;; the full dashboard: wide rendering, with card labels
              (switch-to-buffer dash)
              (ez-agents-dashboard--render)
              (should (string-match-p "Working 1" (with-current-buffer dash (buffer-string))))
              ;; selecting a chat from the dashboard transforms the frame
              (with-current-buffer dash (ez-agents-jump (ez-agents-session "a1")))
              (should (ez-agents-workspace-active-p))
              (should (= 2 (length (window-list nil 'no-minibuf))))
              (let ((left (get-buffer-window dash)) (right (get-buffer-window chat1)))
                (should (and left right))
                (should (= ez-agents-workspace-width (window-total-width left)))
                (should (window-dedicated-p left))
                (should (eq (selected-window) right))               ; focus is in the chat
                (should (< (car (window-edges left)) (car (window-edges right)))))   ; chat on the right
              ;; ...and the list is compact now, with the open chat marked
              (let ((text (with-current-buffer dash (buffer-string))))
                (should-not (string-match-p "Working 1" text))
                (should (string-match-p "▶" text))
                (should (string-match-p "Codex" text)))
              ;; choosing another agent only swaps the chat
              (ez-agents-jump (ez-agents-session "a2"))
              (should (= 2 (length (window-list nil 'no-minibuf))))
              (should (get-buffer-window chat2))
              (should-not (get-buffer-window chat1))
              (should (equal ez-agents--current-chat "a2"))
              ;; l expands to the full dashboard, and again returns to the layout
              (select-window (get-buffer-window dash))
              (ez-agents-dashboard-toggle-layout)
              (should-not (ez-agents-workspace-active-p))
              (should (= 1 (length (window-list nil 'no-minibuf))))
              (should (string-match-p "Working 1" (with-current-buffer dash (buffer-string))))
              (ez-agents-dashboard-toggle-layout)
              (should (ez-agents-workspace-active-p))
              (should (get-buffer-window chat2))
              ;; q closes the layout and brings back what was there before
              (select-window (get-buffer-window dash))
              (ez-agents-dashboard-quit)
              (should-not (ez-agents-workspace-active-p))
              (should (= 1 (length (window-list nil 'no-minibuf))))))
        (kill-buffer chat1) (kill-buffer chat2)
        (when (get-buffer ez-agents-dashboard-buffer-name)
          (kill-buffer ez-agents-dashboard-buffer-name))))))

(ert-deftest ez-agents-workspace-leaves-other-buffers-alone-by-default ()
  (let ((ez-agents--workspace nil) (ez-agents-workspace-trigger 'dashboard))
    (with-temp-buffer
      (fundamental-mode)
      (should-not (ez-agents--workspace-wanted-p)))
    (let ((ez-agents-workspace-trigger 'always)) (should (ez-agents--workspace-wanted-p)))
    (let ((ez-agents-workspace-trigger 'never))
      (with-temp-buffer (ez-agents-dashboard-mode) (should-not (ez-agents--workspace-wanted-p))))
    (with-temp-buffer (ez-agents-dashboard-mode) (should (ez-agents--workspace-wanted-p)))))

(require 'ez-agents-chats)

(defmacro ez-agents-test--with-chat-homes (&rest body)
  "Run BODY with throwaway Claude and Codex homes and a project dir PROJ."
  (declare (indent 0))
  `(let* ((home (file-name-as-directory (make-temp-file "ez-agents-chats" t)))
          (proj (file-name-as-directory (expand-file-name "my.proj_x/app" home)))
          (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" home "claude")
                                             (concat "CODEX_HOME=" home "codex"))
                                       process-environment)))
     (make-directory proj t)
     (unwind-protect (progn ,@body) (delete-directory home t))))

(defun ez-agents-test--write-claude (proj id age-secs &rest lines)
  (let ((dir (ez-agents-chats--claude-dir proj)))
    (make-directory dir t)
    (let ((f (expand-file-name (concat id ".jsonl") dir)))
      (with-temp-file f (dolist (l lines) (insert l "\n")))
      (set-file-times f (time-subtract nil age-secs))
      f)))

(ert-deftest ez-agents-chats-claude-dir-encoding-matches-claude ()
  (should (equal (file-name-nondirectory
                  (ez-agents-chats--claude-dir "/Users/ezechukwu69/.emacs.d/"))
                 "-Users-ezechukwu69--emacs-d"))
  (should (equal (file-name-nondirectory (ez-agents-chats--claude-dir "/a/b_c d/"))
                 "-a-b-c-d")))

(ert-deftest ez-agents-chats-claude-lists-titled-chats-newest-first ()
  (ez-agents-test--with-chat-homes
    (ez-agents-test--write-claude
     proj "11111111-aaaa" 7200
     "{\"type\":\"ai-title\",\"aiTitle\":\"Fix the login bug\",\"sessionId\":\"x\"}"
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"please fix login\"}}")
    (ez-agents-test--write-claude
     proj "22222222-bbbb" 60
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<command-message>x</command-message> add dark mode\"}]}}")
    ;; a chat that never got a message is not worth resuming
    (ez-agents-test--write-claude proj "33333333-cccc" 10
                                  "{\"type\":\"mode\",\"sessionId\":\"z\"}")
    (let ((chats (ez-agents-chats 'claude proj)))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) chats)
                     '("22222222-bbbb" "11111111-aaaa")))        ; newest first
      (should (equal (plist-get (cadr chats) :title) "Fix the login bug"))
      (should (equal (plist-get (car chats) :title) "x add dark mode")))  ; tags stripped
    (should-not (ez-agents-chats 'claude (expand-file-name "other/" home)))))

(ert-deftest ez-agents-chats-codex-matches-by-cwd ()
  (ez-agents-test--with-chat-homes
    (let ((dir (expand-file-name "2026/10/11" (concat home "codex/sessions"))))
      (make-directory dir t)
      (dolist (spec `(("rollout-2026-10-11T10-00-00-AAAA.jsonl" "AAAA" ,proj "build the api")
                      ("rollout-2026-10-11T11-00-00-BBBB.jsonl" "BBBB" "/somewhere/else/" "other")))
        (with-temp-file (expand-file-name (car spec) dir)
          (insert (format "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"cwd\":\"%s\"}}\n"
                          (nth 1 spec) (directory-file-name (nth 2 spec))))
          (insert (format "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"%s\"}]}}\n"
                          (nth 3 spec))))))
    ;; boilerplate context and chats with no real prompt are ignored
    (with-temp-file (expand-file-name "rollout-2026-10-11T12-00-00-CCCC.jsonl"
                                      (concat home "codex/sessions/2026/10/11"))
      (insert (format "{\"type\":\"session_meta\",\"payload\":{\"id\":\"CCCC\",\"cwd\":\"%s\"}}\n"
                      (directory-file-name proj)))
      (insert "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<environment_context>cwd</environment_context>\"}]}}\n"))
    (let ((chats (ez-agents-chats 'codex proj)))
      (should (= 1 (length chats)))
      (should (equal (plist-get (car chats) :id) "AAAA"))
      (should (equal (plist-get (car chats) :title) "build the api")))))

(ert-deftest ez-agents-chats-resume-commands ()
  (should (equal (ez-agents--resume-command 'claude "abc") '("claude" "--resume" "abc")))
  (should (equal (ez-agents--resume-command 'claude nil) '("claude" "--continue")))
  (should (equal (ez-agents--resume-command 'codex "abc") '("codex" "resume" "abc")))
  (should (equal (ez-agents--resume-command 'codex nil) '("codex" "resume" "--last")))
  (should (equal (ez-agents--resume-command 'gemini nil) '("gemini" "--resume" "latest")))
  ;; no per-chat resume for cursor: falls back to its latest-chat command
  (should (equal (ez-agents--resume-command 'cursor "id") '("cursor-agent" "resume"))))

(ert-deftest ez-agents-chats-choose-offers-new-latest-or-older ()
  (ez-agents-test--with-chat-homes
    (ez-agents-test--write-claude
     proj "old-1" 9000
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"first topic\"}}")
    (ez-agents-test--write-claude
     proj "new-2" 30
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"second topic\"}}")
    (let (seen)
      (cl-flet ((pick (re) (cl-letf (((symbol-function 'completing-read)
                                      (lambda (_p table &rest _)
                                        (let* ((all (all-completions "" table))
                                               (hit (cl-find-if (lambda (c) (string-match-p re c)) all)))
                                          (setq seen all)
                                          hit))))
                             (ez-agents-chats-choose 'claude proj))))
        ;; new chat
        (should-not (pick "\\`New chat"))
        ;; the menu lists: new chat, the most recent, then older ones
        (should (string-match-p "\\`New chat" (nth 0 seen)))
        (should (string-match-p "Continue most recent .*second topic" (nth 1 seen)))
        (should (string-match-p "first topic" (nth 2 seen)))
        ;; continue the latest / pick the older one
        (should (equal (pick "most recent") '(("claude" "--resume" "new-2") . "new-2")))
        (should (equal (pick "first topic") '(("claude" "--resume" "old-1") . "old-1"))))
      ;; policies
      (let ((ez-agents-resume-prompt 'latest))
        (should (equal (cdr (ez-agents-chats-choose 'claude proj)) "new-2")))
      (let ((ez-agents-resume-prompt 'never))
        (should-not (ez-agents-chats-choose 'claude proj)))
      ;; nothing stored for this directory: no question asked, new chat
      (should-not (ez-agents-chats-choose 'claude (expand-file-name "empty/" home)))
      ;; agents whose chats cannot be listed never prompt
      (should-not (ez-agents-chats-choose 'gemini proj)))))

(ert-deftest ez-agents-events-remember-the-chat-id-for-precise-resume ()
  (ez-agents-test--with-session s
    (ez-agents-event "a1" "UserPromptSubmit"
                     (ez-agents-test--payload '((session_id . "chat-uuid-9"))))
    (should (equal (ez-agent-chat s) "chat-uuid-9"))
    (should (equal (ez-agents--resume-command 'claude (ez-agent-chat s))
                   '("claude" "--resume" "chat-uuid-9")))))

(defmacro ez-agents-test--exit (s term event &rest body)
  "Report TERM's exit EVENT, settle it, then run BODY (messages land in MSG)."
  (declare (indent 3))
  `(let ((msg nil))
     (cl-letf (((symbol-function 'run-at-time) #'ignore)      ; settle by hand, below
               ((symbol-function 'message)
                (lambda (f &rest a) (setq msg (apply #'format f a)))))
       (ez-agents--on-exit ,term ,event)
       (ez-agents--settle-exit (ez-agent-id ,s) ,event)
       ,@body)))

(ert-deftest ez-agents-terminal-exit-keeps-the-buffer-when-the-agent-lives-on ()
  (ez-agents-test--with-session s
    (let ((term (generate-new-buffer "*dead-terminal*")))
      (setf (ez-agent-buffer s) term (ez-agent-tmux s) "ez-a1")
      (unwind-protect
          (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) t)))
            (ez-agents-test--exit s term "exited abnormally with code 1\n"
              ;; Ghostel must not kill it (that would swap another buffer into its window)
              (with-current-buffer term (should-not ghostel-kill-buffer-on-exit))
              (should (buffer-live-p term))
              (should (string-match-p "terminal exited (exited abnormally with code 1)" msg))
              (should (string-match-p "still running in tmux" msg))
              (should-not (memq (ez-agent-status s) '(done error)))))
        (kill-buffer term)))))

(ert-deftest ez-agents-exit-is-judged-after-tmux-has-dropped-the-session ()
  "The terminal exits just *before* tmux drops the session of an agent that died."
  (ez-agents-test--with-session s
    (let ((term (generate-new-buffer "*dying*")) (alive t))
      (with-current-buffer term
        (insert "Session abc is currently running as a background agent (bg).\n"
                "add --fork-session to branch off a copy.\n"))
      (setf (ez-agent-buffer s) term (ez-agent-tmux s) "ez-a1")
      (unwind-protect
          (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (_) alive))
                    ((symbol-function 'run-at-time) #'ignore)
                    ((symbol-function 'message) #'ignore))
            ;; the terminal exits while tmux still lists the session ...
            (ez-agents--on-exit term "finished\n")
            ;; ... which is gone by the time the exit is judged
            (setq alive nil)
            (let (msg)
              (cl-letf (((symbol-function 'message) (lambda (f &rest a) (setq msg (apply #'format f a)))))
                (ez-agents--settle-exit "a1" "finished\n"))
              (should (eq (ez-agent-status s) 'error))             ; died right after starting
              (should (string-match-p "stopped right after starting" msg))
              (should (string-match-p "--fork-session" msg))        ; and says why
              (should-not (string-match-p "still running" msg))))
        (kill-buffer term)))))

(ert-deftest ez-agents-terminal-exit-marks-a-plain-agent-finished ()
  (ez-agents-test--with-session s
    (let ((term (generate-new-buffer "*plain-terminal*")))
      (setf (ez-agent-buffer s) term
            (ez-agent-started s) (- (float-time) 3600))             ; ran for a long time
      (unwind-protect
          (ez-agents-test--exit s term "finished\n"
            (should (eq (ez-agent-status s) 'done))
            (should (string-match-p "ended" msg)))
        (kill-buffer term)))))

(ert-deftest ez-agents-failed-start-leaves-nothing-behind ()
  (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
        (ez-agents-definitions '((fake :name "Fake" :command ("sh"))))
        (ez-agents-backend 'ghostel) killed
        (before (length (buffer-list))))
    (cl-letf (((symbol-function 'ez-agents--server-socket) (lambda () nil))
              ((symbol-function 'ez-agents-backend-start)
               (lambda (&rest _) (error "attach blew up")))
              ((symbol-function 'ez-agents-backend-kill)
               (lambda (_b s) (push (ez-agent-id s) killed))))
      (should-error (ez-agents-spawn 'fake temporary-file-directory) :type 'error))
    (should (zerop (hash-table-count ez-agents--table)))
    (should (= 1 (length killed)))                       ; the backend was told to clean up
    (should (= before (length (buffer-list))))))          ; and the terminal buffer is gone

(ert-deftest ez-agents-dashboard-draws-compactly-when-any-window-is-narrow ()
  (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
        (ez-agents-dashboard--collapsed (make-hash-table :test #'equal))
        (ez-agents-dashboard--marked (make-hash-table :test #'equal))
        (ez-agents-dashboard--expanded (make-hash-table :test #'equal))
        ez-agents-dashboard--status-filter ez-agents-dashboard--query
        (ez-agents-dashboard-compact-width 40))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((dash (ez-agents-dashboard--ensure-buffer))
                 (wide (selected-window))
                 (narrow (split-window-right -30)))
            (set-window-buffer wide dash)
            (set-window-buffer narrow dash)
            (select-window wide)                          ; the wide window comes first
            (should (> (window-body-width wide) 40))
            (should (< (window-body-width narrow) 40))
            (ez-agents-dashboard--render)
            ;; compact cards carry no labels
            (should-not (string-match-p "Working" (with-current-buffer dash (buffer-string))))))
      (when (get-buffer ez-agents-dashboard-buffer-name)
        (kill-buffer ez-agents-dashboard-buffer-name)))))

(ert-deftest ez-agents-workspace-failure-restores-the-previous-layout ()
  (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
        (ez-agents--workspace nil) (ez-agents--current-chat nil)
        (chat (generate-new-buffer "*chat*"))
        (s (ez-agent--create :id "w1" :kind 'claude :project "/tmp/" :name "C" :started 1.0
                             :activity (float-time))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer (get-buffer-create "*before-layout*"))
          (cl-letf (((symbol-function 'select-window)
                     (lambda (&rest _) (error "select failed"))))
            (should-error (ez-agents-workspace-show s chat)))
          ;; one window, showing what was there before, and no half-made layout
          (should (= 1 (length (window-list nil 'no-minibuf))))
          (should (equal (buffer-name (window-buffer)) "*before-layout*"))
          (should-not ez-agents--workspace))
      (kill-buffer chat)
      (kill-buffer "*before-layout*")
      (when (get-buffer ez-agents-dashboard-buffer-name)
        (kill-buffer ez-agents-dashboard-buffer-name)))))

(ert-deftest ez-agents-restore-adopts-running-agents-that-have-no-record ()
  (ez-agents-test--with-tmux
    (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
          (ez-agents-definitions '((fake :name "Fake Agent" :command ("cat")))))
      ;; running agent, but no state file at all (e.g. Emacs died before saving)
      (ez-agents--tmux-new-session "ez-orph9" temporary-file-directory nil "cat" nil)
      ;; and a stranger that merely shares the prefix but is not one of our agents
      (ez-agents--tmux-new-session "ez-stranger" temporary-file-directory nil "sleep" '("60"))
      (should (= 1 (ez-agents-restore t)))
      (let ((s (ez-agents-session "orph9")))
        (should s)
        (should (eq (ez-agent-kind s) 'fake))
        (should (equal (ez-agent-name s) "Fake Agent"))
        (should (equal (ez-agent-tmux s) "ez-orph9"))
        (should (file-equal-p (ez-agent-cwd s) temporary-file-directory))
        (should (ez-agents-detached-p s))
        (should (> (ez-agent-pid s) 0)))
      (should-not (ez-agents-session "stranger"))
      ;; restoring again does not duplicate it
      (should (= 0 (ez-agents-restore t)))
      (should (= 1 (hash-table-count ez-agents--table))))))

(ert-deftest ez-agents-an-agent-that-dies-at-once-stays-visible-with-the-reason ()
  (ez-agents-test--with-session s
    (let ((term (generate-new-buffer "*dying-agent*")))
      (with-current-buffer term (insert "starting...\nError: No conversation found with session ID: x\n"))
      (setf (ez-agent-buffer s) term)                      ; plain Ghostel agent, no tmux
      (ez-agents-test--exit s term "exited abnormally with code 1\n" (ignore msg))
      ;; Ghostel now kills the buffer: that must not make the session vanish
      (with-current-buffer term
        (add-hook 'kill-buffer-hook (lambda () (ez-agents--buffer-killed "a1")) nil t))
      (let ((kill-buffer-query-functions nil)) (kill-buffer term))
      (should (ez-agents-session "a1"))
      (should (eq (ez-agent-status s) 'error))
      (should-not (ez-agent-buffer s))
      ;; and the dashboard/tail can say why
      (let ((tail (ez-agents-tail s 5)))
        (should (cl-some (lambda (l) (string-match-p "exited abnormally with code 1" l)) tail))
        (should (cl-some (lambda (l) (string-match-p "No conversation found" l)) tail))))))

(ert-deftest ez-agents-an-explicit-kill-still-forgets-the-session ()
  (ez-agents-test--with-session s
    (cl-letf (((symbol-function 'ez-agents-backend-kill) #'ignore))
      (ez-agents-kill s))
    (should-not (ez-agents-session "a1"))))

(ert-deftest ez-agents-tmux-answers-are-cached-briefly ()
  (let ((ez-agents--tmux-cache (make-hash-table :test #'equal)) (calls 0))
    (let ((thunk (lambda () (cl-incf calls))))
      (should (= 1 (ez-agents--tmux-cached '(k) 10 thunk)))
      (should (= 1 (ez-agents--tmux-cached '(k) 10 thunk)))   ; served from the cache
      (should (= 1 calls))
      (should (= 2 (ez-agents--tmux-cached '(other) 10 thunk)))
      (should (= 3 (ez-agents--tmux-cached '(k) 0 thunk)))))) ; expired: asked again

(ert-deftest ez-agents-debug-log-is-written-and-never-fails ()
  (let* ((dir (make-temp-file "ez-agents-log" t))
         (ez-agents-data-directory dir) (ez-agents-debug t))
    (unwind-protect
        (progn
          (ez-agents--log "hello %s" "world")
          (ez-agents--log "second line")
          (with-temp-buffer
            (insert-file-contents (ez-agents-debug-log-file))
            (should (string-match-p "hello world" (buffer-string)))
            (should (= 2 (count-lines (point-min) (point-max)))))
          (let ((ez-agents-debug nil))
            (ez-agents--log "not written")
            (with-temp-buffer
              (insert-file-contents (ez-agents-debug-log-file))
              (should-not (string-match-p "not written" (buffer-string)))))
          ;; an unwritable location must not raise
          (let ((ez-agents-data-directory "/proc/definitely/not/writable/"))
            (should-not (ez-agents--log "ignored"))))
      (delete-directory dir t))))

(ert-deftest ez-agents-chats-claude-marks-live-chats-and-opens-them-as-a-copy ()
  (ez-agents-test--with-chat-homes
    (ez-agents-test--write-claude
     proj "live-bg" 100
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"in use right now\"}}")
    (ez-agents-test--write-claude
     proj "idle-one" 500
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"not running\"}}")
    (let ((sdir (expand-file-name "claude/sessions" home)))
      (make-directory sdir t)
      ;; a live process (this Emacs) running chat live-bg as a background agent ...
      (with-temp-file (expand-file-name (format "%d.json" (emacs-pid)) sdir)
        (insert (format "{\"pid\":%d,\"sessionId\":\"live-bg\",\"kind\":\"bg\"}" (emacs-pid))))
      ;; ... and a stale record whose process is long gone, for the other chat
      (with-temp-file (expand-file-name "99999999.json" sdir)
        (insert "{\"pid\":99999999,\"sessionId\":\"idle-one\",\"kind\":\"interactive\"}")))
    (let* ((chats (ez-agents-chats 'claude proj))
           (live (cl-find "live-bg" chats :key (lambda (c) (plist-get c :id)) :test #'equal))
           (idle (cl-find "idle-one" chats :key (lambda (c) (plist-get c :id)) :test #'equal)))
      (should (equal (plist-get live :live) "bg"))
      (should-not (plist-get idle :live))
      (should (string-match-p "running now (opens a copy)" (ez-agents-chats--label live)))
      (should-not (string-match-p "running now" (ez-agents-chats--label idle)))
      ;; live chats are forked, so Claude accepts them; idle ones resume in place
      (should (equal (ez-agents-chats--command 'claude live)
                     '("claude" "--resume" "live-bg" "--fork-session")))
      (should (equal (ez-agents-chats--command 'claude idle)
                     '("claude" "--resume" "idle-one"))))))

(ert-deftest ez-agents-clear-ended-removes-only-sessions-with-nothing-left-to-attach-to ()
  (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
        (live-ids '("run1")))
    (dolist (spec '(("run1" idle) ("done1" done) ("err1" error) ("work1" working)))
      (puthash (car spec) (ez-agent--create :id (car spec) :kind 'claude :project "/p/" :name (car spec)
                                            :status (cadr spec) :started 1.0 :activity 1.0)
               ez-agents--table))
    (cl-letf (((symbol-function 'ez-agents-live-p) (lambda (s) (member (ez-agent-id s) live-ids)))
              ((symbol-function 'ez-agents-backend-kill) #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (should (equal (sort (mapcar #'ez-agent-id (ez-agents-ended-sessions)) #'string<)
                     '("done1" "err1")))
      (ez-agents-clear-ended)
      (should (equal (sort (mapcar #'ez-agent-id (ez-agents-sessions)) #'string<)
                     '("run1" "work1")))                      ; running ones untouched
      (should (null (ez-agents-ended-sessions))))))

(ert-deftest ez-agents-adopted-sessions-get-distinct-numbered-names ()
  (ez-agents-test--with-tmux
    (let ((ez-agents--table (make-hash-table :test #'equal)) (ez-agents-change-hook nil)
          (ez-agents-definitions '((fake :name "Fake Agent" :command ("cat")))))
      (ez-agents--tmux-new-session "ez-n1" temporary-file-directory nil "cat" nil)
      (ez-agents--tmux-new-session "ez-n2" temporary-file-directory nil "cat" nil)
      (should (= 2 (ez-agents-restore t)))
      (should (equal (sort (mapcar #'ez-agent-name (ez-agents-sessions)) #'string<)
                     '("Fake Agent" "Fake Agent #2"))))))

(ert-deftest ez-agents-save-state-writes-nothing-when-there-is-nothing-to-say ()
  (let ((ez-agents--table (make-hash-table :test #'equal))
        (ez-agents-data-directory (file-name-as-directory (make-temp-file "ez-agents-empty" t))))
    (unwind-protect
        (progn
          ;; no sessions, no file: no file is created
          (ez-agents-save-state)
          (should-not (file-exists-p (ez-agents--state-file)))
          ;; with a session it is written ...
          (puthash "s1" (ez-agent--create :id "s1" :kind 'claude :project "/p/" :tmux "ez-s1"
                                          :started 1.0 :activity 1.0)
                   ez-agents--table)
          (ez-agents-save-state)
          (should (file-exists-p (ez-agents--state-file)))
          ;; ... and once all agents are gone the stale record is replaced, not left behind
          (clrhash ez-agents--table)
          (ez-agents-save-state)
          (should (null (ez-agents--read-state))))
      (delete-directory ez-agents-data-directory t))))

(ert-deftest ez-agents-current-root-asks-the-chooser-only-outside-a-project ()
  (ez-agents-test--with-repo
    (let* ((asked 0) (ez-agents-project-chooser (lambda () (cl-incf asked) "/chosen/project/")))
      ;; inside a project: its root, and nobody is asked
      (let ((default-directory (expand-file-name "sub/" repo)))
        (make-directory default-directory t)
        (should (equal (ez-agents--current-root) (ez-agents--normalize-root repo)))
        (should (= asked 0)))
      ;; outside any project (a plain directory): the chooser decides
      (let ((default-directory (file-name-as-directory (make-temp-file "ez-agents-plain" t))))
        (unwind-protect
            (progn (should (equal (ez-agents--current-root) "/chosen/project/"))
                   (should (= asked 1)))
          (delete-directory default-directory t)))
      ;; without a chooser it is just the current directory
      (let ((ez-agents-project-chooser nil)
            (default-directory (file-name-as-directory (make-temp-file "ez-agents-plain" t))))
        (unwind-protect
            (should (equal (ez-agents--current-root) (ez-agents--normalize-root default-directory)))
          (delete-directory default-directory t))))))

(provide 'ez-agents-test)
;;; ez-agents-test.el ends here
