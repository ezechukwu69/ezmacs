;;; ez-review-test.el --- Tests for ez-review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Run from the package directory:
;;   emacs --batch -L . -L <elpa>/magit-section-* -l test/ez-review-test.el \
;;         -f ert-run-tests-batch-and-exit
;; The tests use fake `gh' and `glab' scripts; they never touch the network or
;; your credentials.

;;; Code:

(require 'ert)
(require 'ez-review)

(defvar corfu-mode)
(defvar corfu-auto)

(defconst ez-review-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst ez-review-test--bin (expand-file-name "fixtures/bin" ez-review-test--dir))

(defmacro ez-review-test--with-fakes (&rest body)
  "Run BODY with `gh' and `glab' replaced by the fixture scripts."
  `(let* ((ez-review-gh-program (expand-file-name "gh" ez-review-test--bin))
          (ez-review-glab-program (expand-file-name "glab" ez-review-test--bin))
          (ez-review-data-directory (file-name-as-directory (make-temp-file "ez-review-data" t)))
          (log (make-temp-file "ez-review-log"))
          (stdin (make-temp-file "ez-review-stdin"))
          (process-environment (append (list (concat "EZ_REVIEW_FAKE_LOG=" log)
                                             (concat "EZ_REVIEW_FAKE_STDIN=" stdin))
                                       process-environment))
          (ez-review-confirm-writes nil))
     (unwind-protect (progn ,@body) (delete-file log) (delete-file stdin))))

(defun ez-review-test--read (var)
  (with-temp-buffer (insert-file-contents (getenv var)) (buffer-string)))
(defun ez-review-test--log () (ez-review-test--read "EZ_REVIEW_FAKE_LOG"))
(defun ez-review-test--stdin () (ez-review-test--read "EZ_REVIEW_FAKE_STDIN"))

(defun ez-review-test--await (fn)
  "Call FN with a callback; wait for it and return the callback's argument."
  (let (result done)
    (funcall fn (lambda (r) (setq result r done t)))
    (with-timeout (5 (error "Timed out waiting for the CLI"))
      (while (not done) (accept-process-output nil 0.05)))
    result))

(defun ez-review-test--repo (url)
  "Make a temp git repo whose origin is URL; return its directory."
  (let ((dir (file-name-as-directory (make-temp-file "ez-review-repo" t))))
    (let ((default-directory dir))
      (call-process "git" nil nil nil "init" "-q")
      (call-process "git" nil nil nil "remote" "add" "origin" url))
    dir))

(defun ez-review-test--gh ()
  (ez-review-forge-current (ez-review-test--repo "https://github.com/o/r.git")))

(defun ez-review-test--gl ()
  (setq ez-review-host-alist (cons '("lab.example.com" . gitlab) ez-review-host-alist))
  (ez-review-forge-current (ez-review-test--repo "https://lab.example.com/g/p.git")))

(defun ez-review-test--draft (&rest args)
  ;; ARGS first: with duplicate keywords the earlier one wins.
  (apply #'make-ez-review-draft
         (append args (list :path "src/a.el" :old-path "src/a.el" :side 'right
                            :line 2 :old-line nil :new-line 2 :body "Please rename"))))

;;;; URL parsing and detection

(ert-deftest ez-review-test-parse-url ()
  (should (equal (ez-review-forge-parse-url "https://github.com/ezechukwu69/ezmacs.git")
                 '("github.com" . "ezechukwu69/ezmacs")))
  (should (equal (ez-review-forge-parse-url "git@github.com:o/r.git") '("github.com" . "o/r")))
  (should (equal (ez-review-forge-parse-url "ssh://git@lab.example.com:2222/g/sub/p.git")
                 '("lab.example.com" . "g/sub/p")))
  (should (equal (ez-review-forge-parse-url "https://user@lab.example.com/g/p/")
                 '("lab.example.com" . "g/p")))
  (should-not (ez-review-forge-parse-url "not a url")))

(ert-deftest ez-review-test-detect-known-hosts ()
  (should (ez-review-github-p (ez-review-test--gh)))
  (should (ez-review-gitlab-p (ez-review-forge-current (ez-review-test--repo "git@gitlab.com:g/p.git")))))

(ert-deftest ez-review-test-detect-self-hosted-by-login ()
  (ez-review-test--with-fakes
   (let ((ez-review-host-alist nil))
     (should (ez-review-gitlab-p
              (ez-review-forge-current (ez-review-test--repo "https://lab.example.com/g/p.git"))))
     (should (equal (alist-get "lab.example.com" ez-review-host-alist nil nil #'equal) 'gitlab)))))

(ert-deftest ez-review-test-not-a-repo ()
  (should-error (ez-review-forge-current (make-temp-file "ez-review-empty" t)) :type 'ez-review-error))

;;;; GitHub backend

(ert-deftest ez-review-test-github-list-prs ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (prs (ez-review-test--await
                (lambda (cb) (ez-review-forge-list forge 'pr '(:filter mine :state closed) cb)))))
     ;; closed means closed + merged: two queries, duplicates collapsed
     (should (= (length prs) 2))
     ;; newest update first
     (should (equal (mapcar #'ez-review-pr-number prs) '(8 7)))
     (let ((pr (cl-find 7 prs :key #'ez-review-pr-number)))
       (should (equal (ez-review-pr-author pr) "alice"))
       (should (equal (ez-review-pr-labels pr) '(("bug" . "d73a4a"))))
       (should (eq (ez-review-pr-draft pr) t))
       (should (equal (ez-review-pr-decision pr) "approved")))
     (should-not (ez-review-pr-decision (cl-find 8 prs :key #'ez-review-pr-number)))
     (let ((log (ez-review-test--log)))
       (should (string-match-p "GH_HOST=github.com pr list --limit 100 --state closed" log))
       (should (string-match-p "pr list --limit 100 --state merged" log))
       (should (string-match-p "--author @me" log))
       (should (string-match-p "-R github.com/o/r" log))))))

(ert-deftest ez-review-test-github-list-issues ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (issues (ez-review-test--await
                   (lambda (cb) (ez-review-forge-list forge 'issue '(:filter review :state open) cb)))))
     (should (= (length issues) 1))
     (should (equal (ez-review-issue-assignees (car issues)) '("alice")))
     (should (string-match-p "issue list .*--assignee @me" (ez-review-test--log))))))

(ert-deftest ez-review-test-github-view-pr ()
  (ez-review-test--with-fakes
   (let ((pr (ez-review-test--await (lambda (cb) (ez-review-forge-view (ez-review-test--gh) 'pr 7 cb)))))
     (should (string-match-p "Adds a widget" (ez-review-pr-body pr)))
     (should (equal (ez-review-pr-checks pr)
                    '(("build" . success) ("lint" . failure) ("ci/x" . pending))))
     (should (equal (ez-review-pr-reviewers pr) '("bob")))
     (should (= (ez-review-pr-additions pr) 12))
     (should (equal (ez-review-pr-mergeable pr) "mergeable"))
     (should (eq 'failure (ez-review-ui-checks-summary (ez-review-pr-checks pr)))))))

(ert-deftest ez-review-test-github-view-issue ()
  (ez-review-test--with-fakes
   (let ((issue (ez-review-test--await (lambda (cb) (ez-review-forge-view (ez-review-test--gh) 'issue 12 cb)))))
     (should (equal (ez-review-issue-state issue) "closed"))
     (should (equal (ez-review-issue-body issue) "It crashes.")))))

(ert-deftest ez-review-test-github-timeline ()
  (ez-review-test--with-fakes
   (let ((tl (ez-review-test--await (lambda (cb) (ez-review-forge-timeline (ez-review-test--gh) 'pr 7 cb)))))
     ;; inline x2, general x1, one APPROVED review; the empty COMMENTED review is dropped
     (should (= (length tl) 4))
     (should (equal (mapcar #'ez-review-comment-id tl) '(101 102 201 301)))
     (let ((first (nth 0 tl)) (reply (nth 1 tl)) (review (nth 3 tl)))
       (should (eq (ez-review-comment-kind first) 'inline))
       (should (equal (ez-review-comment-path first) "src/a.el"))
       (should (= (ez-review-comment-line first) 2))
       (should (eq (ez-review-comment-side first) 'right))
       (should (= (ez-review-comment-reply-to reply) 101))
       (should (= (ez-review-comment-thread reply) 101))
       (should (eq (ez-review-comment-kind review) 'review))
       (should (equal (ez-review-comment-state review) "approved"))))))

(ert-deftest ez-review-test-github-diff-and-checkout ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (diff (plist-get (ez-review-test--await (lambda (cb) (ez-review-forge-diff forge 7 cb))) :diff)))
     (should (string-prefix-p "diff --git a/src/a.el" diff))
     (should (eq t (ez-review-test--await (lambda (cb) (ez-review-forge-checkout forge 7 cb)))))
     (should (string-match-p "pr checkout 7" (ez-review-test--log))))))

(ert-deftest ez-review-test-github-submit-review-payload ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (result (ez-review-test--await
                   (lambda (cb)
                     (ez-review-forge-submit-review
                      forge 7 'request-changes "Needs work"
                      (list (ez-review-test--draft)
                            (ez-review-test--draft :start-line 4 :line 6 :side 'left))
                      cb))))
          (payload (json-parse-string (ez-review-test--stdin) :object-type 'plist :array-type 'list)))
     (should (eq result t))
     (should (string-match-p "api --method POST --input - repos/o/r/pulls/7/reviews" (ez-review-test--log)))
     (should (equal (plist-get payload :event) "REQUEST_CHANGES"))
     (should (equal (plist-get payload :body) "Needs work"))
     (let ((c1 (nth 0 (plist-get payload :comments))) (c2 (nth 1 (plist-get payload :comments))))
       (should (equal (plist-get c1 :path) "src/a.el"))
       (should (equal (plist-get c1 :side) "RIGHT"))
       (should (= (plist-get c1 :line) 2))
       (should-not (plist-member c1 :start_line))
       (should (equal (plist-get c2 :side) "LEFT"))
       (should (= (plist-get c2 :start_line) 4))
       (should (equal (plist-get c2 :start_side) "LEFT"))))))

(ert-deftest ez-review-test-github-approve-event ()
  (ez-review-test--with-fakes
   (ez-review-test--await
    (lambda (cb) (ez-review-forge-submit-review (ez-review-test--gh) 7 'approve nil nil cb)))
   (let ((payload (json-parse-string (ez-review-test--stdin) :object-type 'plist :array-type 'list)))
     (should (equal (plist-get payload :event) "APPROVE"))
     (should (null (plist-get payload :comments))))))

(ert-deftest ez-review-test-github-reply-comment-create-merge-state ()
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gh)))
     (should (eq t (ez-review-test--await
                    (lambda (cb) (ez-review-forge-reply forge 7 (make-ez-review-comment :id 101) "Thanks" cb)))))
     (should (string-match-p "comments/101/replies" (ez-review-test--log)))
     (should (equal (plist-get (json-parse-string (ez-review-test--stdin) :object-type 'plist) :body) "Thanks"))
     (should (equal "https://github.com/o/r/pull/9"
                    (ez-review-test--await
                     (lambda (cb) (ez-review-forge-create forge 'pr (list :title "T" :body "B" :base "main"
                                                                          :head "feat" :draft t :labels '("bug"))
                                                          cb)))))
     (let ((log (ez-review-test--log)))
       (should (string-match-p "pr create --title T --body-file - .*--base main --head feat --draft --label bug" log)))
     (should (equal (ez-review-test--stdin) "B"))
     (should (eq t (ez-review-test--await (lambda (cb) (ez-review-forge-merge forge 7 'squash t cb)))))
     (should (string-match-p "pr merge 7 --squash .*--delete-branch" (ez-review-test--log)))
     (should (eq t (ez-review-test--await (lambda (cb) (ez-review-forge-set-state forge 'issue 12 'closed cb)))))
     (should (string-match-p "issue close 12" (ez-review-test--log))))))

;;;; GitLab backend

(ert-deftest ez-review-test-gitlab-list-and-me ()
  (ez-review-test--with-fakes
   (clrhash ez-review-gitlab--users)
   (let* ((forge (ez-review-test--gl))
          (prs (ez-review-test--await
                (lambda (cb) (ez-review-forge-list forge 'pr '(:filter review :state open) cb)))))
     (should (= (length prs) 1))
     (let ((pr (car prs)))
       (should (= (ez-review-pr-number pr) 3))
       (should (equal (ez-review-pr-state pr) "open"))
       (should (equal (ez-review-pr-labels pr) '(("backend"))))
       (should (eq (ez-review-pr-draft pr) t)))
     (should (string-match-p "projects/g%2Fp/merge_requests\\?state=opened&per_page=100.*&reviewer_username=carol"
                             (ez-review-test--log)))
     (should (string-match-p "GITLAB_HOST=lab.example.com" (ez-review-test--log))))))

(ert-deftest ez-review-test-gitlab-closed-includes-merged ()
  (ez-review-test--with-fakes
   (let ((prs (ez-review-test--await
               (lambda (cb) (ez-review-forge-list (ez-review-test--gl) 'pr '(:filter all :state closed) cb)))))
     (should (= (length prs) 1))
     (let ((log (ez-review-test--log)))
       (should (string-match-p "merge_requests\\?state=closed" log))
       (should (string-match-p "merge_requests\\?state=merged" log))))))

(ert-deftest ez-review-test-list-state-header-and-keys ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-list-mode)
     (setq ez-review-list--forge (ez-review-test--gh) ez-review-list--what 'pr ez-review-list--state 'closed)
     (let ((h (ez-review-list--header)))
       (should (string-match-p "open" h))
       (should (string-match-p "merged" h))
       (should (eq 'ez-review-tab-active (get-text-property (string-match " closed " h) 'face h))))
     (setq ez-review-list--what 'issue)
     (should-not (string-match-p "merged" (ez-review-list--header)))
     (should (eq (lookup-key ez-review-list-mode-map "C") 'ez-review-list-state-closed))
     (should (commandp 'ez-review-list-closed)))))

(ert-deftest ez-review-test-gitlab-issues ()
  (ez-review-test--with-fakes
   (let ((issues (ez-review-test--await
                  (lambda (cb) (ez-review-forge-list (ez-review-test--gl) 'issue '(:filter all :state closed) cb)))))
     (should (equal (ez-review-issue-state (car issues)) "closed"))
     (should (equal (ez-review-issue-assignees (car issues)) '("carol")))
     (should (string-match-p "projects/g%2Fp/issues\\?state=closed" (ez-review-test--log))))))

(ert-deftest ez-review-test-gitlab-view-mr ()
  (ez-review-test--with-fakes
   (let ((pr (ez-review-test--await (lambda (cb) (ez-review-forge-view (ez-review-test--gl) 'pr 3 cb)))))
     (should (equal (ez-review-pr-decision pr) "approved"))
     (should (equal (ez-review-pr-checks pr) '(("pipeline" . failure))))
     (should (= (ez-review-pr-files pr) 4))
     (should (equal (ez-review-pr-refs pr) '(:base "aaa" :start "bbb" :head "ccc")))
     (should (equal (ez-review-pr-reviewers pr) '("bob"))))))

(ert-deftest ez-review-test-gitlab-timeline ()
  (ez-review-test--with-fakes
   (let ((tl (ez-review-test--await (lambda (cb) (ez-review-forge-timeline (ez-review-test--gl) 'pr 3 cb)))))
     ;; the system note is skipped; sorted oldest first: Hello, Rename this, Done
     (should (equal (mapcar #'ez-review-comment-body tl) '("Hello" "Rename this" "Done")))
     (let ((inline (nth 1 tl)) (reply (nth 2 tl)))
       (should (eq (ez-review-comment-kind inline) 'inline))
       (should (equal (ez-review-comment-path inline) "src/a.el"))
       (should (= (ez-review-comment-line inline) 2))
       (should (eq (ez-review-comment-side inline) 'right))
       (should (equal (ez-review-comment-thread reply) "d1"))
       (should (= (ez-review-comment-reply-to reply) 11))))))

(ert-deftest ez-review-test-gitlab-submit-posts-position-then-summary-then-approval ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gl))
          (posted nil)
          (hook (lambda (d) (push (ez-review-draft-body d) posted)))
          (result (progn
                    (add-hook 'ez-review-forge-draft-posted-hook hook)
                    (unwind-protect
                        (ez-review-test--await
                         (lambda (cb)
                           (ez-review-forge-submit-review
                            forge 3 'approve "Looks good"
                            (list (ez-review-test--draft :old-line 2)
                                  (ez-review-test--draft :side 'left :line 9 :old-line 9 :new-line nil :body "Gone?"))
                            cb)))
                      (remove-hook 'ez-review-forge-draft-posted-hook hook)))))
     (should (eq result t))
     (should (equal (nreverse posted) '("Please rename" "Gone?")))
     (let* ((log (ez-review-test--log))
            (disc (string-match "merge_requests/3/discussions" log))
            (notes (string-match "merge_requests/3/notes" log))
            (approve (string-match "merge_requests/3/approve" log)))
       (should (and disc notes approve (< disc notes approve))))
     (let ((stdin (ez-review-test--stdin)))
       ;; first discussion: both lines for an unchanged/added line, shas from diff_refs
       (should (string-match-p "\"base_sha\":\"aaa\"" stdin))
       (should (string-match-p "\"head_sha\":\"ccc\"" stdin))
       (should (string-match-p "\"new_line\":2" stdin))
       (should (string-match-p "\"old_line\":2" stdin))
       ;; second: a removed line carries only old_line
       (should (string-match-p "\"body\":\"Gone\\?\",\"position\":{[^}]*\"old_line\":9}" stdin))))))

(ert-deftest ez-review-test-gitlab-request-changes-is-refused ()
  (ez-review-test--with-fakes
   (let ((result (ez-review-test--await
                  (lambda (cb) (ez-review-forge-submit-review (ez-review-test--gl) 3 'request-changes nil nil cb)))))
     (should (stringp result))
     (should (string-match-p "no \"request changes\"" result)))))

(ert-deftest ez-review-test-gitlab-misc ()
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gl)))
     (should (equal "https://lab.example.com/g/p/-/merge_requests/5"
                    (ez-review-test--await
                     (lambda (cb) (ez-review-forge-create forge 'pr (list :title "T" :body "B" :base "main"
                                                                          :head "feat" :draft t)
                                                          cb)))))
     (should (string-match-p "\"title\":\"Draft: T\"" (ez-review-test--stdin)))
     (should (eq t (ez-review-test--await (lambda (cb) (ez-review-forge-merge forge 3 'squash nil cb)))))
     (should (string-match-p "merge_requests/3/merge" (ez-review-test--log)))
     (should (stringp (ez-review-test--await (lambda (cb) (ez-review-forge-merge forge 3 'rebase nil cb)))))
     (should (eq t (ez-review-test--await (lambda (cb) (ez-review-forge-set-state forge 'pr 3 'closed cb)))))
     (should (string-match-p "\"state_event\":\"close\"" (ez-review-test--stdin)))
     (should (eq t (ez-review-test--await
                    (lambda (cb) (ez-review-forge-reply forge 3 (make-ez-review-comment :thread "d1" :id 11) "ok" cb)))))
     (should (string-match-p "discussions/d1/notes" (ez-review-test--log)))
     (should (string-prefix-p "diff --git" (plist-get (ez-review-test--await (lambda (cb) (ez-review-forge-diff forge 3 cb))) :diff))))))

;;;; Errors

(ert-deftest ez-review-test-missing-cli-reports-error ()
  (let* ((ez-review-gh-program "ez-review-no-such-program")
         (result (ez-review-test--await
                  (lambda (cb) (ez-review-forge-list (ez-review-test--gh) 'pr nil cb)))))
    (should (stringp result))
    (should (string-match-p "not found" result))))

(ert-deftest ez-review-test-cli-failure-carries-stderr ()
  (ez-review-test--with-fakes
   (let ((result (ez-review-test--await
                  (lambda (cb) (ez-review-github--run (ez-review-test--gh) '("bogus" "cmd")
                                                      (lambda (ok out) (funcall cb (list ok out))))))))
     (should-not (car result))
     (should (string-match-p "unhandled" (cadr result))))))

(ert-deftest ez-review-test-args-are-not-shell-interpreted ()
  (ez-review-test--with-fakes
   (let ((result (ez-review-process-sync ez-review-gh-program '("pr" "view" "7; echo pwned"))))
     (should-not (string-match-p "pwned" (nth 1 result))))))

(ert-deftest ez-review-test-gather-reports-first-error ()
  (let ((out (ez-review-test--await
              (lambda (cb)
                (ez-review-process-gather
                 (list (lambda (k) (funcall k '(1))) (lambda (k) (funcall k "boom")) (lambda (k) (funcall k '(3))))
                 cb)))))
    (should (equal out "boom")))
  (should (equal '((1) (3))
                 (ez-review-test--await
                  (lambda (cb)
                    (ez-review-process-gather
                     (list (lambda (k) (funcall k '(1))) (lambda (k) (funcall k '(3)))) cb))))))

(ert-deftest ez-review-test-error-text-merges-stderr-and-json-body ()
  (should (equal (ez-review-process-error-text
                  1 "{\"message\":\"Validation Failed\",\"errors\":[{\"message\":\"Can not approve your own pull request\"}]}"
                  "gh: Unprocessable Entity (HTTP 422)" "gh")
                 "gh: Unprocessable Entity (HTTP 422): Validation Failed — Can not approve your own pull request"))
  (should (equal (ez-review-process-error-text 1 "{\"message\":\"404 Not found\"}" "" "glab") "404 Not found"))
  (should (equal (ez-review-process-error-text 2 "plain text" "" "gh") "plain text"))
  (should (equal (ez-review-process-error-text 3 "" "" "glab") "glab exited 3")))

;;;; Diff parsing

(defun ez-review-test--sample-files ()
  (ez-review-diff-parse
   (with-temp-buffer (insert-file-contents (expand-file-name "fixtures/sample.diff" ez-review-test--dir))
                     (buffer-string))))

(ert-deftest ez-review-test-diff-parse ()
  (let ((files (ez-review-test--sample-files)))
    (should (= (length files) 2))
    (let* ((a (nth 0 files)) (b (nth 1 files))
           (lines (ez-review-hunk-lines (car (ez-review-file-hunks a)))))
      (should (equal (ez-review-file-path a) "src/a.el"))
      (should (= (ez-review-file-add a) 2))
      (should (= (ez-review-file-del a) 1))
      (should (equal (mapcar #'ez-review-dline-type lines) '(ctx del add add ctx ctx)))
      ;; the deleted line counts on the old side, additions on the new side
      (should (equal (list (ez-review-dline-old (nth 1 lines)) (ez-review-dline-new (nth 1 lines))) '(2 nil)))
      (should (equal (list (ez-review-dline-old (nth 2 lines)) (ez-review-dline-new (nth 2 lines))) '(nil 2)))
      (should (equal (list (ez-review-dline-old (nth 4 lines)) (ez-review-dline-new (nth 4 lines))) '(3 4)))
      (should (eq (ez-review-file-status b) 'added))
      (should (equal (ez-review-file-path b) "new.txt"))
      (should (null (ez-review-file-old b))))))

(ert-deftest ez-review-test-diff-parse-delete-rename-binary ()
  (let ((files (ez-review-diff-parse
                (concat "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n"
                        "@@ -1,2 +0,0 @@\n-x\n-y\n"
                        "diff --git a/old.el b/new.el\nsimilarity index 100%\nrename from old.el\nrename to new.el\n"
                        "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n"))))
    (should (= (length files) 3))
    (should (eq (ez-review-file-status (nth 0 files)) 'deleted))
    (should (equal (ez-review-file-path (nth 0 files)) "gone.txt"))
    (should (= (ez-review-file-del (nth 0 files)) 2))
    (should (eq (ez-review-file-status (nth 1 files)) 'renamed))
    (should (equal (ez-review-file-new (nth 1 files)) "new.el"))
    (should (ez-review-file-binary (nth 2 files)))))

(ert-deftest ez-review-test-diff-parse-dashes-inside-hunk ()
  "A removed line whose text starts with \"-- \" is a deletion, not a header."
  (let* ((files (ez-review-diff-parse "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n--- not a header\n kept\n"))
         (lines (ez-review-hunk-lines (car (ez-review-file-hunks (car files))))))
    (should (= (length files) 1))
    (should (equal (mapcar #'ez-review-dline-type lines) '(del ctx)))
    (should (equal (ez-review-dline-text (car lines)) "-- not a header"))))

;;;; Drafts, compose

(ert-deftest ez-review-test-drafts-roundtrip ()
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gh))
         (a (ez-review-test--draft)) (b (ez-review-test--draft :body "Two" :start-line 1)))
     (should (null (ez-review-drafts-load forge 7)))
     (ez-review-drafts-add forge 7 a)
     (ez-review-drafts-add forge 7 b)
     (should (equal (ez-review-drafts-load forge 7) (list a b)))
     (should (= (ez-review-drafts-count forge 7) 2))
     (ez-review-drafts-remove forge 7 a)
     (should (equal (ez-review-drafts-load forge 7) (list b)))
     (let ((b2 (copy-sequence b)))
       (setf (ez-review-draft-body b2) "Edited")
       (ez-review-drafts-replace forge 7 b b2)
       (should (equal (ez-review-draft-body (car (ez-review-drafts-load forge 7))) "Edited")))
     (ez-review-drafts-save forge 7 nil)
     (should-not (file-exists-p (ez-review-drafts--file forge 7))))))

(ert-deftest ez-review-test-compose-parse ()
  (should (equal (ez-review-compose-parse "Title: Fix it\nBase: main\nLabels: a, b\n\nBody line\n\nmore")
                 '((("Title" . "Fix it") ("Base" . "main") ("Labels" . "a, b")) . "Body line\n\nmore")))
  (should (equal (ez-review-compose-parse "just text") '(nil . "just text"))))

(ert-deftest ez-review-test-create-helpers ()
  (should (= 9 (ez-review-create--url-number "https://github.com/o/r/pull/9")))
  (should (= 6 (ez-review-create--url-number "https://lab.example.com/g/p/-/issues/6/")))
  (should-not (ez-review-create--url-number "nonsense"))
  (should (equal (ez-review-create--parse-labels "bug, ui  docs") '("bug" "ui" "docs"))))

;;;; UI pieces

(ert-deftest ez-review-test-ui-reltime ()
  (let ((iso (lambda (secs) (format-time-string "%FT%TZ" (time-subtract nil secs) t))))
    (should (equal (ez-review-ui-reltime (funcall iso 5)) "just now"))
    (should (equal (ez-review-ui-reltime (funcall iso 7300)) "2h ago"))
    (should (equal (ez-review-ui-reltime (funcall iso (* 3 86400))) "3d ago"))
    (should-not (ez-review-ui-reltime nil))))

(ert-deftest ez-review-test-ui-markdown ()
  (let ((out (ez-review-ui-markdown "# Title\n**bold** and `code`\n```sh\nmake\n```\n> quote\n- [x] done")))
    (should-not (string-match-p "```" out))
    (should-not (string-match-p "\\*\\*" out))
    (should (string-match-p "☑ done" out))
    (should (eq 'ez-review-heading (get-text-property 0 'face out)))
    (should (eq 'bold (get-text-property (string-match "bold" out) 'face out)))))

(ert-deftest ez-review-test-ui-label-contrast ()
  (let ((light (ez-review-ui-label '("x" . "ffff00")))
        (dark (ez-review-ui-label '("y" . "000080"))))
    (should (equal (plist-get (get-text-property 1 'face light) :foreground) "#1f2328"))
    (should (equal (plist-get (get-text-property 1 'face dark) :foreground) "#ffffff"))
    ;; no colour -> stable derived colour
    (should (equal (ez-review-ui-label '("same")) (ez-review-ui-label '("same"))))))

(ert-deftest ez-review-test-ui-card ()
  (let ((card (ez-review-ui-card "alice" "line one\nline two" :indent 2 :chip "[x]")))
    (should (= 3 (length (split-string card "\n" t))))
    (should (string-match-p "alice \\[x\\]" card))))

;;;; Rendering

(ert-deftest ez-review-test-list-render ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-list-mode)
     (setq ez-review-list--forge (ez-review-test--gh)
           ez-review-list--items
           (ez-review-test--await (lambda (cb) (ez-review-forge-list (ez-review-test--gh) 'pr nil cb)))
           ez-review-list--counts '(:pr 2))
     (ez-review-list--render)
     (let ((text (buffer-string)))
       (should (string-match-p "github.com/o/r" text))
       (should (string-match-p "#7 +Add widget" text))
       (should (string-match-p "feat/widget → main" text))
       (should (string-match-p "bug" text)))
     (should (string-match-p "Pull requests" (substring-no-properties (ez-review-list--header))))
     (setq ez-review-list--what 'issue ez-review-list--items
           (ez-review-test--await (lambda (cb) (ez-review-forge-list (ez-review-test--gh) 'issue nil cb))))
     (ez-review-list--render)
     (should (string-match-p "Crash on start" (buffer-string))))))

(ert-deftest ez-review-test-view-render-pr ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-view-mode)
     (let ((forge (ez-review-test--gh)))
       (setq ez-review-view--forge forge ez-review-view--what 'pr ez-review-view--number 7
             ez-review-view--item (ez-review-test--await (lambda (cb) (ez-review-forge-view forge 'pr 7 cb)))
             ez-review-view--timeline (ez-review-test--await (lambda (cb) (ez-review-forge-timeline forge 'pr 7 cb)))))
     (ez-review-view--render)
     (let ((text (buffer-string)))
       (should (string-match-p "#7 Add widget" text))
       (should (string-match-p "wants to merge feat/widget into main" text))
       (should (string-match-p "1/3 passing" text))
       (should (string-match-p "LGTM overall" text))
       (should (string-match-p "approved" text))
       (should (string-match-p "2 inline review comments" text))
       (should (string-match-p "make" text))))))

(ert-deftest ez-review-test-view-render-issue ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-view-mode)
     (let ((forge (ez-review-test--gh)))
       (setq ez-review-view--forge forge ez-review-view--what 'issue ez-review-view--number 12
             ez-review-view--item (ez-review-test--await (lambda (cb) (ez-review-forge-view forge 'issue 12 cb)))
             ez-review-view--timeline (ez-review-test--await (lambda (cb) (ez-review-forge-timeline forge 'issue 12 cb)))))
     (ez-review-view--render)
     (should (string-match-p "Closed" (buffer-string)))
     (should (string-match-p "It crashes" (buffer-string)))
     (should (string-match-p "LGTM overall" (buffer-string))))))

(defun ez-review-test--diff-buffer ()
  "Fill the current buffer as a diff review of PR 7 and return nothing."
  (let ((forge (ez-review-test--gh)))
    (ez-review-diff-mode)
    (setq ez-review-diff--forge forge ez-review-diff--number 7
          ez-review-diff--pr (ez-review-test--await (lambda (cb) (ez-review-forge-view forge 'pr 7 cb)))
          ez-review-diff--files (ez-review-test--sample-files)
          ez-review-diff--comments (ez-review-test--await (lambda (cb) (ez-review-forge-timeline forge 'pr 7 cb))))
    (ez-review-diff--render)))

(ert-deftest ez-review-test-diff-render-places-threads-and-drafts ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (let ((text (buffer-string)))
       (should (string-match-p "src/a.el" text))
       (should (string-match-p "\\+ +  2)" text))
       ;; inside Changes, the thread sits right under the added line, replies after it
       (let ((changes (string-match "^Changes" text)))
         (should (< (string-match "  2)" text changes) (string-match "Why\\?" text changes)
                    (string-match "Because\\." text changes))))
       (should-not (string-match-p "Outdated or unplaced" text)))
     ;; add a pending comment on the same line
     (ez-review-drafts-add (ez-review-test--gh) 7 (ez-review-test--draft))
     (ez-review-diff--render)
     (let ((text (buffer-string)))
       (should (string-match-p "pending" text))
       (should (string-match-p "1 pending" text))
       (let ((changes (string-match "^Changes" text)))
         (should (< (string-match "Because\\." text changes) (string-match "Please rename" text changes))))))))

(ert-deftest ez-review-test-diff-unplaced-comment-listed ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (push (make-ez-review-comment :id 999 :author "zed" :body "Old thread" :kind 'inline
                                   :path "src/a.el" :side 'right :line 400)
           ez-review-diff--comments)
     (ez-review-diff--render)
     (should (string-match-p "Outdated or unplaced" (buffer-string)))
     (should (string-match-p "src/a.el:400" (buffer-string))))))

(ert-deftest ez-review-test-diff-new-draft-from-point ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (goto-char (point-min))
     (search-forward "(defun b () 3)")
     (let ((d (ez-review-diff--new-draft "hi")))
       (should (equal (ez-review-draft-path d) "src/a.el"))
       (should (eq (ez-review-draft-side d) 'right))
       (should (= (ez-review-draft-line d) 3))
       (should (null (ez-review-draft-old-line d)))
       (should (= (ez-review-draft-new-line d) 3)))
     ;; a removed line is on the left side, counted in the old file
     (goto-char (point-min))
     (search-forward "-   1)")
     (let ((d (ez-review-diff--new-draft "hi")))
       (should (eq (ez-review-draft-side d) 'left))
       (should (= (ez-review-draft-line d) 2)))
     ;; a region over two added lines becomes a range ending on the last
     (goto-char (point-min))
     (search-forward "+   2)")
     (beginning-of-line)
     (transient-mark-mode 1)
     (set-mark (point))
     ;; the thread cards sit between the two lines, so jump by search
     (search-forward "(defun b () 3)")
     (end-of-line)
     (activate-mark)
     (let ((d (ez-review-diff--new-draft "range")))
       (should (= (ez-review-draft-start-line d) 2))
       (should (= (ez-review-draft-line d) 3)))
     (deactivate-mark))))

(ert-deftest ez-review-test-diff-comment-navigation ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (goto-char (point-min))
     (ez-review-diff-next-comment)
     (should (eq (ez-review-comment-id (get-text-property (point) 'ez-review-comment)) 101))
     (ez-review-diff-next-comment)
     (should (eq (ez-review-comment-id (get-text-property (point) 'ez-review-comment)) 102))
     (ez-review-diff-previous-comment)
     (should (eq (ez-review-comment-id (get-text-property (point) 'ez-review-comment)) 101)))))

;;;; Actions

(ert-deftest ez-review-test-actions-submit-flow ()
  "Drafts are sent with the chosen verdict and cleared afterwards."
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gh)) (done nil))
     (ez-review-drafts-add forge 7 (ez-review-test--draft))
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Approve"))
               ((symbol-function 'ez-review-compose)
                (lambda (_name _initial callback &rest _) (funcall callback "Ship it"))))
       (ez-review-actions-submit forge 7 (lambda () (setq done t))))
     (with-timeout (5 (error "submit timed out")) (while (not done) (accept-process-output nil 0.05)))
     (let ((payload (json-parse-string (ez-review-test--stdin) :object-type 'plist :array-type 'list)))
       (should (equal (plist-get payload :event) "APPROVE"))
       (should (equal (plist-get payload :body) "Ship it"))
       (should (= 1 (length (plist-get payload :comments)))))
     (should (null (ez-review-drafts-load forge 7))))))

(ert-deftest ez-review-test-actions-confirmation-can-cancel ()
  (ez-review-test--with-fakes
   (let ((ez-review-confirm-writes t) (forge (ez-review-test--gh)))
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
       (ez-review-actions-set-state forge 'pr 7 'closed nil))
     (should-not (string-match-p "pr close" (ez-review-test--log))))))

(ert-deftest ez-review-test-actions-gitlab-hides-request-changes ()
  (let ((labels (mapcar #'car (ez-review-actions--events (ez-review-test--gl)))))
    (should-not (member "Request changes" labels)))
  (should (member "Request changes" (mapcar #'car (ez-review-actions--events (ez-review-test--gh))))))

;;;; Regressions: diff via the real fetch path, faces, suggestions

(ert-deftest ez-review-test-diff-open-renders-in-buffer-not-echo-area ()
  "Opening the diff goes through `ez-review-process-gather'; the diff text, being
a string, must not be taken for an error and echoed."
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gh)) (messages nil))
     (cl-letf (((symbol-function 'pop-to-buffer-same-window) (lambda (b &rest _) (set-buffer b))))
       (let ((buf (progn
                    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
                      (ez-review-diff-open forge 7)
                      (let ((b (current-buffer)))
                        (with-timeout (5 (error "diff never rendered"))
                          (while (null (buffer-local-value 'ez-review-diff--files b))
                            (accept-process-output nil 0.05)))
                        b)))))
         (with-current-buffer buf
           (should (string-match-p "src/a.el" (buffer-string)))
           (should (string-match-p "defun b" (buffer-string))))
         (should-not (cl-some (lambda (m) (string-match-p "diff --git\\|ez-review: " m)) messages))
         (kill-buffer buf))))))

(ert-deftest ez-review-test-modes-keep-their-faces ()
  "font-lock would erase our face properties in magit-section buffers."
  (global-font-lock-mode 1)
  (dolist (mode '(ez-review-list-mode ez-review-view-mode ez-review-diff-mode))
    (with-temp-buffer
      (funcall mode)
      (should-not font-lock-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "chip" 'face 'ez-review-chip-open)))
      (font-lock-ensure)
      (should (eq 'ez-review-chip-open (get-text-property 1 'face))))))

(ert-deftest ez-review-test-markdown-suggestion-block ()
  (let ((out (ez-review-ui-markdown "Nice, but:\n```suggestion\n  (foo 2)\n```\nafter")))
    (should (string-match-p "Suggested change" out))
    (should (string-match-p "^+   (foo 2)" out))
    (should-not (string-match-p "```" out))
    (should (eq 'ez-review-suggestion (get-text-property (string-match "(foo 2)" out) 'face out)))
    (should (string-match-p "after" out))))

(ert-deftest ez-review-test-suggest-text-and-source-lines ()
  (let* ((files (ez-review-test--sample-files))
         (a (car files)))
    (should (equal (ez-review-diff--source-lines a 2 3) '("  2)" "(defun b () 3)")))
    (should (equal (ez-review-diff--source-lines a 4 4) '("(provide 'a)")))
    ;; line 9 is not in the diff at all
    (should-not (ez-review-diff--source-lines a 2 9)))
  (should (equal (ez-review-diff--suggestion-text (ez-review-test--gh) '("a" "b"))
                 "\n\n```suggestion\na\nb\n```"))
  (should (string-match-p "```suggestion:-1\\+0\n" (ez-review-diff--suggestion-text (ez-review-test--gl) '("a" "b")))))

(ert-deftest ez-review-test-suggest-command-builds-draft ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (let (captured-initial captured-cb)
       (cl-letf (((symbol-function 'ez-review-compose)
                  (lambda (_name initial callback &rest _)
                    (setq captured-initial initial captured-cb callback)
                    (with-current-buffer (generate-new-buffer " *fake compose*")
                      (insert initial) (current-buffer)))))
         (goto-char (point-min))
         (search-forward "(defun b () 3)")
         (ez-review-diff-suggest))
       (should (string-match-p "```suggestion\n(defun b () 3)\n```" captured-initial))
       (funcall captured-cb "Use a docstring\n```suggestion\n(defun b () \"x\" 3)\n```")
       (let ((d (car (ez-review-drafts-load (ez-review-test--gh) 7))))
         (should (= (ez-review-draft-line d) 3))
         (should (eq (ez-review-draft-side d) 'right))
         (should (string-match-p "docstring" (ez-review-draft-body d))))
       (should (string-match-p "Suggested change" (buffer-string)))
       ;; removed lines cannot be replaced
       (goto-char (point-min))
       (search-forward "-   1)")
       (should-error (ez-review-diff-suggest) :type 'user-error)))))

;;;; Commits and paging

(ert-deftest ez-review-test-github-commits-and-commit-diff ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (commits (ez-review-test--await (lambda (cb) (ez-review-forge-commits forge 7 cb)))))
     (should (equal (mapcar #'ez-review-commit-subject commits) '("Add widget skeleton" "Wire widget in")))
     (should (equal (ez-review-commit-author (car commits)) "alice"))
     (should (equal (ez-review-commit-sha (car commits)) "abc1234def5678"))
     (let* ((diff (plist-get (ez-review-test--await
                              (lambda (cb) (ez-review-forge-commit-diff forge "abc1234def5678" cb)))
                             :diff))
            (files (ez-review-diff-parse diff)))
       (should (= 1 (length files)))
       (should (= 1 (ez-review-file-add (car files)))))
     (should (string-match-p "repos/o/r/commits/abc1234def5678" (ez-review-test--log))))))

(ert-deftest ez-review-test-gitlab-commits-oldest-first-and-diff-rebuilt ()
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gl))
          (commits (ez-review-test--await (lambda (cb) (ez-review-forge-commits forge 3 cb)))))
     (should (equal (mapcar #'ez-review-commit-subject commits) '("First" "Second")))
     (let* ((diff (plist-get (ez-review-test--await
                              (lambda (cb) (ez-review-forge-commit-diff forge "abc1234def5678" cb)))
                             :diff))
            (files (ez-review-diff-parse diff)))
       (should (equal (mapcar #'ez-review-file-path files) '("src/a.el" "n.txt")))
       (should (eq (ez-review-file-status (cadr files)) 'added))
       (should (= 1 (ez-review-file-add (car files))))))))

(ert-deftest ez-review-test-list-limit-github-and-gitlab ()
  (ez-review-test--with-fakes
   (ez-review-test--await
    (lambda (cb) (ez-review-forge-list (ez-review-test--gh) 'pr '(:limit 250 :state open) cb)))
   (should (string-match-p "pr list --limit 250 " (ez-review-test--log))))
  (ez-review-test--with-fakes
   (let ((prs (ez-review-test--await
               (lambda (cb) (ez-review-forge-list (ez-review-test--gl) 'pr '(:limit 250 :state open) cb)))))
     (let ((log (ez-review-test--log)))
       ;; three bounded requests, never an unbounded --paginate
       (should (string-match-p "per_page=100&page=1" log))
       (should (string-match-p "per_page=100&page=2" log))
       (should (string-match-p "per_page=100&page=3" log))
       (should-not (string-match-p "page=4" log))
       (should-not (string-match-p "--paginate .*merge_requests\\?state" log)))
     (should (<= (length prs) 250)))))

(ert-deftest ez-review-test-list-more-raises-limit-and-hint ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-list-mode)
     (let ((ez-review-list-limit 2))
       (setq ez-review-list--forge (ez-review-test--gh) ez-review-list--limit 2
             ez-review-list--items (list 1 2))
       (should (string-match-p "first 2, > for more" (ez-review-list--header)))
       (cl-letf (((symbol-function 'ez-review-list--fetch) #'ignore))
         (ez-review-list-more))
       (should (= ez-review-list--limit 4))
       (should-not (string-match-p "for more" (ez-review-list--header))))
     (should (eq (lookup-key ez-review-list-mode-map ">") 'ez-review-list-more)))))

(defun ez-review-test--open-commit-diff ()
  "Fill the current buffer as the diff of commit 1 of PR 7."
  (ez-review-test--diff-buffer)
  (setq ez-review-diff--commits
        (ez-review-test--await (lambda (cb) (ez-review-forge-commits (ez-review-test--gh) 7 cb))))
  (setq ez-review-diff--commit (car ez-review-diff--commits)
        ez-review-diff--files
        (ez-review-diff-parse
         (with-temp-buffer (insert-file-contents (expand-file-name "fixtures/commit.diff" ez-review-test--dir))
                           (buffer-string))))
  (ez-review-diff--render))

(ert-deftest ez-review-test-diff-commit-mode-is-read-only-and-walks ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--open-commit-diff)
     (let ((text (buffer-string)))
       (should (string-match-p "commit 1/2  abc1234" text))
       (should (string-match-p "Add widget skeleton" text))
       (should (string-match-p "read-only" text))
       ;; the PR's threads and pending drafts do not appear in a commit's diff
       (should-not (string-match-p "Why\\?" text)))
     (goto-char (point-min))
     (search-forward "(defun b () 3)")
     (should-error (ez-review-diff-comment) :type 'user-error)
     (should-error (ez-review-diff-suggest) :type 'user-error)
     (let (shown)
       (cl-letf (((symbol-function 'ez-review-diff--show-commit) (lambda (c) (setq shown c))))
         (ez-review-diff-next-commit)
         (should (equal (ez-review-commit-sha shown) "fed9876cba4321"))
         (should-error (progn (setq ez-review-diff--commit (cadr ez-review-diff--commits))
                              (ez-review-diff-next-commit))
                       :type 'user-error)
         (ez-review-diff-previous-commit)
         (should (equal (ez-review-commit-sha shown) "abc1234def5678"))
         (ez-review-diff-all-changes)
         (should (null shown)))))))

(ert-deftest ez-review-test-diff-open-commit-through-real-fetch ()
  (ez-review-test--with-fakes
   (let ((forge (ez-review-test--gh)))
     (cl-letf (((symbol-function 'pop-to-buffer-same-window) (lambda (b &rest _) (set-buffer b))))
       (let* ((commits (ez-review-test--await (lambda (cb) (ez-review-forge-commits forge 7 cb)))))
         (ez-review-diff-open forge 7 (car commits))
         (let ((b (current-buffer)))
           (with-timeout (5 (error "commit diff never rendered"))
             (while (null (buffer-local-value 'ez-review-diff--files b)) (accept-process-output nil 0.05)))
           (with-current-buffer b
             (should (string-match-p "commit 1/2" (buffer-string)))
             (should (= 1 (length ez-review-diff--files)))
             (should (string-match-p "pr view 7 --json commits" (ez-review-test--log))))
           (kill-buffer b)))))))

(ert-deftest ez-review-test-view-lists-commits ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-view-mode)
     (let ((forge (ez-review-test--gh)))
       (setq ez-review-view--forge forge ez-review-view--what 'pr ez-review-view--number 7
             ez-review-view--item (ez-review-test--await (lambda (cb) (ez-review-forge-view forge 'pr 7 cb)))
             ez-review-view--timeline nil
             ez-review-view--commits (ez-review-test--await (lambda (cb) (ez-review-forge-commits forge 7 cb)))))
     (ez-review-view--render)
     (let ((text (buffer-string)))
       (should (string-match-p "Commits  2" text))
       (should (string-match-p "abc1234  Add widget skeleton" text))
       (should (string-match-p "fed9876  Wire widget in" text)))
     (goto-char (point-min))
     (search-forward "Wire widget in")
     (should (ez-review-commit-p (magit-section-value-if 'review-commit))))))

(ert-deftest ez-review-test-diff-visual-selection-becomes-range ()
  "An Evil visual selection counts as a region for range comments."
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (goto-char (point-min))
     (search-forward "+   2)")
     (beginning-of-line)
     (let ((start (point)))
       (search-forward "(defun b () 3)")
       (end-of-line)
       (cl-letf (((symbol-function 'ez-review-diff--region) (lambda () (cons start (point)))))
         (let ((d (ez-review-diff--new-draft "x")))
           (should (= (ez-review-draft-start-line d) 2))
           (should (= (ez-review-draft-line d) 3))))))))

;;;; Sectioned diff buffer

(ert-deftest ez-review-test-diff-buffer-has-separate-sections ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (ez-review-drafts-add (ez-review-test--gh) 7 (ez-review-test--draft :body "Rename pls"))
     (ez-review-diff--render)
     (let* ((text (substring-no-properties (buffer-string)))
            (files (string-match "^Files changed" text))
            (threads (string-match "^Review threads" text))
            (changes (string-match "^Changes" text)))
       ;; overview, then files index, then threads index, then the diff itself
       (should (and files threads changes (< 0 files threads changes)))
       (should (string-match-p "2 files" (substring text 0 files)))
       (should (string-match-p "c comment" (substring text 0 files)))
       ;; files index: one row per file with its counts and badges
       (let ((index (substring text files threads)))
         (should (string-match-p "src/a.el +\\+2 −1" index))
         (should (string-match-p "new.txt +\\+2 −0" index))
         (should (string-match-p "1 pending" index)))
       ;; threads index: the bob/alice thread (2 comments) and the pending draft
       (let ((idx (substring text threads changes)))
         (should (string-match-p "src/a.el:2 +bob \\+1 · Why\\?" idx))
         (should (string-match-p "pending.*src/a.el:2.*you · Rename pls" idx)))))))

(ert-deftest ez-review-test-diff-banner-and-card-faces ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (ez-review-drafts-add (ez-review-test--gh) 7 (ez-review-test--draft))
     (ez-review-diff--render)
     (goto-char (point-min))
     (re-search-forward "^Changes")
     (re-search-forward "^. src/a.el")
     (beginning-of-line)
     ;; the file heading carries the banner background out to the window edge
     (should (memq 'ez-review-diff-banner (ensure-list (get-text-property (+ (point) 3) 'face))))
     (should (memq 'ez-review-diff-banner (ensure-list (get-text-property (line-end-position) 'face))))
     (goto-char (point-min))
     (re-search-forward "^Changes")
     (re-search-forward "Why\\?")
     (should (memq 'ez-review-card-bg (ensure-list (get-text-property (match-beginning 0) 'face))))
     (re-search-forward "Please rename")
     (should (memq 'ez-review-card-bg-pending (ensure-list (get-text-property (match-beginning 0) 'face)))))))

(ert-deftest ez-review-test-diff-index-rows-jump-into-the-diff ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     ;; file row -> the file's heading in Changes
     (goto-char (point-min))
     (re-search-forward "^  . new.txt")
     (cl-letf (((symbol-function 'recenter) #'ignore))
       (ez-review-diff-visit)
       (should (looking-at ".*new.txt"))
       (should (> (point) (save-excursion (goto-char (point-min)) (re-search-forward "^Changes") (point))))
       ;; thread row -> the comment card in the diff
       (goto-char (point-min))
       (re-search-forward "src/a.el:2 +bob")
       (ez-review-diff-visit)
       (should (equal "Why?" (ez-review-comment-body (get-text-property (point) 'ez-review-comment))))))))

(ert-deftest ez-review-test-diff-index-jump-unfolds-collapsed-file ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (let ((ez-review-diff-collapse-lines 1))
       (ez-review-diff--render))
     (goto-char (point-min))
     (re-search-forward "src/a.el:2 +bob")
     (cl-letf (((symbol-function 'recenter) #'ignore))
       (ez-review-diff-visit))
     (should (get-text-property (point) 'ez-review-comment))
     (should-not (invisible-p (point))))))

(ert-deftest ez-review-test-diff-next-previous-file ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (cl-letf (((symbol-function 'recenter) #'ignore))
       (goto-char (point-min))
       (re-search-forward "^Changes")
       (ez-review-diff-next-file)
       (should (looking-at ".*src/a.el"))
       (ez-review-diff-next-file)
       (should (looking-at ".*new.txt"))
       (ez-review-diff-previous-file)
       (should (looking-at ".*src/a.el"))))))

(ert-deftest ez-review-test-diff-commit-view-skips-thread-index ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--open-commit-diff)
     (let ((text (substring-no-properties (buffer-string))))
       (should (string-match-p "^Files changed" text))
       (should-not (string-match-p "^Review threads" text))
       (should (string-match-p "^Changes" text))))))

;;;; Outdated comments and the commented-only filter

(ert-deftest ez-review-test-outdated-comment-is-not-placed-by-its-old-line ()
  "GitHub's original_line counts in an older commit; using it would put the
comment under the wrong line of the combined diff."
  (ez-review-test--with-fakes
   (let* ((forge (ez-review-test--gh))
          (tl (ez-review-test--await (lambda (cb) (ez-review-forge-timeline forge 'pr 8 cb))))
          (c (car tl)))
     (should (= 1 (length tl)))
     (should (null (ez-review-comment-line c)))
     (should (= 9 (ez-review-comment-original-line c)))
     (should (equal "src/a.el" (ez-review-comment-path c))))))

(ert-deftest ez-review-test-outdated-comment-listed-with-old-line-note ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (setq ez-review-diff--comments
           (ez-review-test--await (lambda (cb) (ez-review-forge-timeline (ez-review-test--gh) 'pr 8 cb))))
     (ez-review-diff--render)
     (let* ((text (substring-no-properties (buffer-string)))
            (outdated (string-match "Outdated or unplaced" text)))
       (should outdated)
       (should (string-match-p "src/a.el  (outdated: was line 9 in an earlier commit)" text))
       (should (string-match-p "Old thread" (substring text outdated)))
       ;; and it is not drawn under line 9 (or any line) of the diff
       (should-not (string-match-p "Old thread" (substring text (string-match "^Changes" text) outdated)))
       (should (string-match-p "outdated" (substring text (string-match "^Review threads" text) outdated)))))))

(ert-deftest ez-review-test-commented-only-filter ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (let ((changes (lambda () (let ((text (substring-no-properties (buffer-string))))
                                 (substring text (string-match "^Changes" text))))))
       (should (string-match-p "new.txt" (funcall changes)))
       (ez-review-diff-toggle-commented-only)
       ;; only src/a.el has a thread; new.txt drops out of Changes but stays in the index
       (should-not (string-match-p "new.txt" (funcall changes)))
       (should (string-match-p "src/a.el" (funcall changes)))
       (should (string-match-p "commented files only" (funcall changes)))
       (should (string-match-p "new.txt" (substring-no-properties (buffer-string) 0 (string-match "^Changes" (buffer-string)))))
       (ez-review-diff-toggle-commented-only)
       (should (string-match-p "new.txt" (funcall changes)))))))

(ert-deftest ez-review-test-replies-stay-one-level-deep ()
  "However many replies a thread has, they all sit at the same indent."
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (dotimes (i 4)
       (push (make-ez-review-comment :id (+ 500 i) :thread 101 :reply-to 101 :author "x"
                                     :body (format "reply %d" i) :created (format "2026-10-03T1%d:00:00Z" i)
                                     :kind 'inline :path "src/a.el" :side 'right :line 2)
             ez-review-diff--comments))
     (ez-review-diff--render)
     (goto-char (point-min))
     (re-search-forward "^Changes")
     (let (columns)
       (dotimes (i 4)
         (goto-char (point-min))
         (re-search-forward "^Changes")
         (re-search-forward (format "reply %d" i))
         (push (save-excursion (goto-char (match-beginning 0)) (current-column)) columns))
       (should (= 1 (length (delete-dups columns))))))))

;;;; @-mentions

(ert-deftest ez-review-test-users-github-and-gitlab ()
  (ez-review-test--with-fakes
   (should (equal '("alice" "bob" "zed")
                  (ez-review-test--await (lambda (cb) (ez-review-forge-users (ez-review-test--gh) cb)))))
   ;; one page only, never every page
   (should (string-match-p "repos/o/r/assignees\\?per_page=100" (ez-review-test--log)))
   (should-not (string-match-p "--paginate .*assignees" (ez-review-test--log))))
  (ez-review-test--with-fakes
   (should (equal '("carol" "erin")
                  (ez-review-test--await (lambda (cb) (ez-review-forge-users (ez-review-test--gl) cb)))))
   (let ((log (ez-review-test--log)))
     (should (string-match-p "projects/g%2Fp/members/all\\?per_page=100&page=1" log))
     (should-not (string-match-p "--paginate" log)))))

(ert-deftest ez-review-test-mention-function-lists-participants-first ()
  (ez-review-test--with-fakes
   (clrhash ez-review-forge--users)
   (clrhash ez-review-forge--users-pending)
   (let* ((forge (ez-review-test--gh))
          (fn (ez-review-forge-mention-function forge '("zed" "@bob" nil "zed"))))
     ;; before the background fetch lands, only the participants
     (should (equal (funcall fn) '("zed" "bob")))
     (with-timeout (5 (error "users never arrived"))
       (while (eq (gethash (ez-review-forge--users-key forge) ez-review-forge--users 'unset) 'unset)
         (accept-process-output nil 0.05)))
     ;; afterwards: participants first, then the rest, no duplicates
     (should (equal (funcall fn) '("zed" "bob" "alice")))
     ;; a second request does not fetch again
     (let ((before (ez-review-test--log)))
       (ez-review-forge-mention-function forge nil)
       (sleep-for 0.2)
       (should (equal before (ez-review-test--log)))))))

(ert-deftest ez-review-test-mention-fetch-error-is-remembered-not-repeated ()
  (let ((ez-review-gh-program "ez-review-no-such-program"))
    (clrhash ez-review-forge--users)
    (clrhash ez-review-forge--users-pending)
    (let ((forge (ez-review-test--gh)))
      (ez-review-forge-prefetch-users forge)
      (sleep-for 0.1)
      (should (null (gethash (ez-review-forge--users-key forge) ez-review-forge--users 'unset)))
      (should (equal (funcall (ez-review-forge-mention-function forge '("me"))) '("me"))))))

(defun ez-review-test--compose-with (text names)
  "A compose buffer holding TEXT with point at its end, offering NAMES."
  (let ((buf (generate-new-buffer " *compose test*")))
    (with-current-buffer buf
      (ez-review-compose-mode)
      (setq ez-review-compose--mentions (lambda () names))
      (insert text))
    buf))

(ert-deftest ez-review-test-mention-capf-completes-after-at ()
  (with-current-buffer (ez-review-test--compose-with "thanks @al" '("alice" "bob" "alan"))
    (let ((r (ez-review-compose-mention-capf)))
      (should r)
      (should (equal (buffer-substring (nth 0 r) (nth 1 r)) "al"))
      (should (equal (sort (all-completions "al" (nth 2 r)) #'string<) '("alan" "alice")))
      ;; the caller's order is kept, not re-sorted
      (should (eq 'identity (cdr (assq 'display-sort-function (cdr (funcall (nth 2 r) "" nil 'metadata)))))))))

(ert-deftest ez-review-test-mention-capf-ignores-emails-and-plain-text ()
  (with-current-buffer (ez-review-test--compose-with "mail me at joe@exam" '("alice"))
    (should-not (ez-review-compose-mention-capf)))
  (with-current-buffer (ez-review-test--compose-with "no mention here" '("alice"))
    (should-not (ez-review-compose-mention-capf)))
  ;; at the start of a line and after an open paren both count
  (with-current-buffer (ez-review-test--compose-with "(cc @b" '("bob"))
    (should (ez-review-compose-mention-capf)))
  (with-current-buffer (ez-review-test--compose-with "first\n@b" '("bob"))
    (should (ez-review-compose-mention-capf)))
  ;; without a candidate source the buffer completes nothing
  (with-current-buffer (ez-review-test--compose-with "hi @a" nil)
    (setq ez-review-compose--mentions nil)
    (should-not (ez-review-compose-mention-capf))))

(ert-deftest ez-review-test-mention-exit-function-adds-a-space ()
  (with-current-buffer (ez-review-test--compose-with "hi @al" '("alice"))
    (let* ((r (ez-review-compose-mention-capf))
           (exit (plist-get (nthcdr 3 r) :exit-function)))
      (delete-region (nth 0 r) (nth 1 r))
      (insert "alice")
      (funcall exit "alice" 'finished)
      (should (equal (buffer-string) "hi @alice "))
      ;; not twice when a space already follows
      (goto-char (point-min))
      (search-forward "@alice")
      (funcall exit "alice" 'finished)
      (should (equal (buffer-string) "hi @alice "))
      ;; and nothing when completion did not finish
      (erase-buffer) (insert "@al")
      (funcall exit "al" 'unknown)
      (should (equal (buffer-string) "@al")))))

(ert-deftest ez-review-test-typing-at-opens-completion ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'completion-at-point) (lambda () (cl-incf calls))))
      (with-current-buffer (ez-review-test--compose-with "" '("alice" "bob"))
        (let ((last-command-event ?@))
          (insert "see @")
          (ez-review-compose--maybe-complete))
        (should (= calls 1))
        ;; an e-mail address does not
        (erase-buffer)
        (let ((last-command-event ?@))
          (insert "joe@")
          (ez-review-compose--maybe-complete))
        (should (= calls 1))
        ;; not for other characters, and not when switched off
        (let ((last-command-event ?a)) (insert "x") (ez-review-compose--maybe-complete))
        (should (= calls 1))
        (let ((ez-review-mention-auto-complete nil) (last-command-event ?@))
          (erase-buffer) (insert "@") (ez-review-compose--maybe-complete))
        (should (= calls 1))))))

(ert-deftest ez-review-test-compose-mode-wires-mentions ()
  (with-temp-buffer
    (ez-review-compose-mode)
    (should (memq 'ez-review-compose-mention-capf completion-at-point-functions))
    (should (memq 'ez-review-compose--maybe-complete post-self-insert-hook))))

(ert-deftest ez-review-test-mentions-are-highlighted-but-not-emails ()
  (let ((out (ez-review-ui-markdown "ping @alice and (@bob-x), mail joe@example.com or @ alone")))
    (should (eq 'ez-review-mention (get-text-property (string-match "@alice" out) 'face out)))
    (should (eq 'ez-review-mention (get-text-property (string-match "@bob-x" out) 'face out)))
    (should (equal "@alice" (substring-no-properties out (string-match "@alice" out) (+ 6 (string-match "@alice" out)))))
    (should-not (get-text-property (string-match "@example" out) 'face out))
    (should-not (get-text-property (string-match "@ alone" out) 'face out))))

(ert-deftest ez-review-test-comment-compose-gets-participants-and-repo-users ()
  "Commenting from a page offers its participants first, then the repo's users."
  (ez-review-test--with-fakes
   (clrhash ez-review-forge--users)
   (clrhash ez-review-forge--users-pending)
   (let ((forge (ez-review-test--gh)) offered)
     (cl-letf (((symbol-function 'ez-review-compose)
                (lambda (_n _i _cb &rest args) (setq offered (plist-get args :mentions)))))
       (ez-review-actions-comment forge 'pr 7 nil (lambda () '("carol" "dave"))))
     (should (functionp offered))
     (should (equal (funcall offered) '("carol" "dave")))
     (with-timeout (5 (error "users never arrived"))
       (while (eq (gethash (ez-review-forge--users-key forge) ez-review-forge--users 'unset) 'unset)
         (accept-process-output nil 0.05)))
     (should (equal (funcall offered) '("carol" "dave" "alice" "bob" "zed"))))))

(ert-deftest ez-review-test-diff-people-and-view-people ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     ;; author alice, reviewer bob, commenters bob, alice and carol (a general comment)
     (should (equal (sort (copy-sequence (ez-review-diff--people)) #'string<) '("alice" "bob" "carol"))))
   (with-temp-buffer
     (ez-review-view-mode)
     (let ((forge (ez-review-test--gh)))
       (setq ez-review-view--forge forge ez-review-view--what 'pr ez-review-view--number 7
             ez-review-view--item (ez-review-test--await (lambda (cb) (ez-review-forge-view forge 'pr 7 cb)))
             ez-review-view--timeline (ez-review-test--await (lambda (cb) (ez-review-forge-timeline forge 'pr 7 cb)))))
     (should (equal (sort (copy-sequence (ez-review-view--people)) #'string<) '("alice" "bob" "carol"))))))

;;;; Posting one inline comment without a review

(ert-deftest ez-review-test-github-post-inline-is-a-single-comment-not-a-review ()
  (ez-review-test--with-fakes
   (should (eq t (ez-review-test--await
                  (lambda (cb) (ez-review-forge-post-inline (ez-review-test--gh) 7
                                                            (ez-review-test--draft :start-line 1 :line 3 :new-line 3) cb)))))
   (let ((log (ez-review-test--log))
         (payload (json-parse-string (ez-review-test--stdin) :object-type 'plist)))
     ;; looked up the head commit, then POSTed to the comments endpoint, never to /reviews
     (should (string-match-p "pr view 7 --json headRefOid" log))
     (should (string-match-p "--method POST --input - repos/o/r/pulls/7/comments$" log))
     (should-not (string-match-p "/reviews" log))
     (should (equal (plist-get payload :commit_id) "headsha123"))
     (should (equal (plist-get payload :path) "src/a.el"))
     (should (= (plist-get payload :line) 3))
     (should (= (plist-get payload :start_line) 1))
     (should (equal (plist-get payload :side) "RIGHT"))
     (should (equal (plist-get payload :body) "Please rename")))))

(ert-deftest ez-review-test-gitlab-post-inline-posts-one-discussion ()
  (ez-review-test--with-fakes
   (should (eq t (ez-review-test--await
                  (lambda (cb) (ez-review-forge-post-inline (ez-review-test--gl) 3 (ez-review-test--draft :old-line 2) cb)))))
   (let ((log (ez-review-test--log)) (stdin (ez-review-test--stdin)))
     (should (string-match-p "merge_requests/3/discussions" log))
     (should-not (string-match-p "/approve\\|/notes" log))
     (should (string-match-p "\"base_sha\":\"aaa\"" stdin))
     (should (string-match-p "\"body\":\"Please rename\"" stdin)))))

(ert-deftest ez-review-test-post-now-failure-is-reported ()
  (ez-review-test--with-fakes
   (let ((ez-review-gh-program "ez-review-no-such-program"))
     (let ((r (ez-review-test--await
               (lambda (cb) (ez-review-forge-post-inline (ez-review-test--gh) 7 (ez-review-test--draft) cb)))))
       (should (stringp r))
       (should (string-match-p "not found" r))))))

(ert-deftest ez-review-test-compose-second-way-to-finish ()
  (let (kept posted)
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-buffer b))))
      (let ((buf (ez-review-compose "t" "" (lambda (text) (setq kept text))
                                    :alt (cons "post now" (lambda (text) (setq posted text))))))
        (with-current-buffer buf
          (insert "hello")
          (should (string-match-p "C-c C-p" (format "%s" header-line-format)))
          (should (eq (lookup-key ez-review-compose-mode-map (kbd "C-c C-p")) 'ez-review-compose-finish-alt))
          (ez-review-compose-finish-alt))
        (should (equal posted "hello"))
        (should-not kept)
        (should-not (buffer-live-p buf)))))
  ;; a buffer without an alternative refuses C-c C-p instead of doing the wrong thing
  (with-temp-buffer
    (ez-review-compose-mode)
    (should-error (ez-review-compose-finish-alt) :type 'user-error)))

(ert-deftest ez-review-test-diff-comment-offers-post-now-and-it-skips-drafts ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (let (alt)
       (cl-letf (((symbol-function 'ez-review-compose)
                  (lambda (_n _i _cb &rest args) (setq alt (plist-get args :alt))
                    (generate-new-buffer " x"))))
         (goto-char (point-min))
         (search-forward "(defun b () 3)")
         (ez-review-diff-comment))
       (should (equal "post now" (car alt)))
       ;; the post-now path sends the comment and stores no pending draft
       (funcall (cdr alt) "Looks off")
       (with-timeout (5 (error "post never finished"))
         (while (or (not (string-match-p "pulls/7/comments$" (ez-review-test--log)))
                    (string-empty-p (ez-review-test--stdin)))
           (accept-process-output nil 0.05)))
       (should (null (ez-review-drafts-load (ez-review-test--gh) 7)))
       (should (equal "Looks off" (plist-get (json-parse-string (ez-review-test--stdin) :object-type 'plist) :body)))))))

(ert-deftest ez-review-test-post-pending-draft-now-removes-it ()
  (ez-review-test--with-fakes
   (with-temp-buffer
     (ez-review-test--diff-buffer)
     (ez-review-drafts-add (ez-review-test--gh) 7 (ez-review-test--draft :body "Ship this one"))
     (ez-review-diff--render)
     (goto-char (point-min))
     (re-search-forward "^Changes")
     (re-search-forward "Ship this one")
     (cl-letf (((symbol-function 'ez-review-diff-refresh) #'ignore))
       (ez-review-diff-post-draft)
       (with-timeout (5 (error "post never finished"))
         (while (ez-review-drafts-load (ez-review-test--gh) 7) (accept-process-output nil 0.05))))
     (should-not (string-empty-p (ez-review-test--stdin)))
     (should (null (ez-review-drafts-load (ez-review-test--gh) 7)))
     (should (equal "Ship this one" (plist-get (json-parse-string (ez-review-test--stdin) :object-type 'plist) :body))))))

(ert-deftest ez-review-test-post-now-asks-first ()
  (ez-review-test--with-fakes
   (let ((ez-review-confirm-writes t) (asked nil))
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (p) (setq asked p) nil)))
       (ez-review-actions-post-inline (ez-review-test--gh) 7 (ez-review-test--draft) nil))
     (should (string-match-p "without a review" asked))
     (should (string-match-p "src/a.el:2" asked))
     (should (string-match-p "github.com/o/r" asked))
     (should-not (string-match-p "pulls/7/comments" (ez-review-test--log))))))

;;;; A lone @ candidate must not be filled in unasked

(ert-deftest ez-review-test-at-with-one-user-does-not-auto-insert ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'completion-at-point) (lambda () (cl-incf calls))))
      (cl-flet ((type-at (names)
                  (with-current-buffer (ez-review-test--compose-with "" names)
                    (let ((last-command-event ?@))
                      (insert "@")
                      (ez-review-compose--maybe-complete)))))
        ;; plain completion UI: a single name is not forced in (TAB still can)
        (let ((corfu-mode nil) (corfu-auto nil))
          (type-at '("only-user"))
          (should (= calls 0))
          ;; with a real choice it is offered
          (type-at '("alice" "bob"))
          (should (= calls 1)))
        ;; Corfu with auto-completion handles @ itself, so we stay out of its way
        (let ((corfu-mode t) (corfu-auto t))
          (type-at '("alice" "bob"))
          (type-at '("only-user"))
          (should (= calls 1)))
        ;; Corfu without auto: same rule as a plain UI
        (let ((corfu-mode t) (corfu-auto nil))
          (type-at '("only-user"))
          (should (= calls 1))
          (type-at '("alice" "bob"))
          (should (= calls 2)))))))

(ert-deftest ez-review-test-mention-capf-tells-corfu-to-open-at-empty-prefix ()
  (with-current-buffer (ez-review-test--compose-with "hi @" '("only-user"))
    (let ((r (ez-review-compose-mention-capf)))
      (should r)
      (should (eq t (plist-get (nthcdr 3 r) :company-prefix-length)))
      ;; nothing typed after the @, and the text is left alone
      (should (equal (buffer-substring (nth 0 r) (nth 1 r)) ""))
      (should (equal (buffer-string) "hi @")))))

;;;; Packaging

(ert-deftest ez-review-test-entry-points-exist ()
  (dolist (f '(ez-review-dispatch ez-review-list ez-review-list-issues ez-review-view ez-review-diff
               ez-review-checkout ez-review-create-pr ez-review-create-issue ez-review-list-mine
               ez-review-list-requested ez-review-auth-status ez-review-auth-login
               ez-review-auth-logout ez-review-diff-menu ez-review-list-menu ez-review-view-menu))
    (should (commandp f)))
  (should (keymapp ez-review-map)))

(provide 'ez-review-test)
;;; ez-review-test.el ends here
