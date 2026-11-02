;;; ez-review-github.el --- GitHub backend using gh -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Implements the `ez-review-forge' interface with the GitHub CLI.  Plain
;; commands use `gh pr' / `gh issue'; review threads and batched reviews use
;; `gh api', since the porcelain cannot attach inline comments.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)

(defconst ez-review-github--pr-fields
  "number,title,author,headRefName,baseRefName,isDraft,state,url,updatedAt,createdAt,reviewDecision,labels")

(defconst ez-review-github--pr-view-fields
  (concat ez-review-github--pr-fields
          ",body,additions,deletions,changedFiles,mergeable,statusCheckRollup,reviewRequests"))

(defconst ez-review-github--issue-fields
  "number,title,author,labels,state,url,updatedAt,createdAt,assignees")

;;;; Running gh

(cl-defmethod ez-review-forge-env ((forge ez-review-github))
  `(("GH_HOST" . ,(ez-review-forge-host forge))
    ("GH_PROMPT_DISABLED" . "1")
    ("NO_COLOR" . "1")))

(cl-defun ez-review-github--run (forge args callback &key input)
  "Run `gh' with ARGS for FORGE; CALLBACK gets (OK STDOUT-OR-ERROR)."
  (condition-case err
      (ez-review-process-run
       ez-review-gh-program args
       (lambda (code out stderr)
         (funcall callback (eql code 0)
                  (if (eql code 0) out (ez-review-process-error-text code out stderr "gh"))))
       :dir (ez-review-forge-dir forge) :env (ez-review-forge-env forge) :input input)
    (ez-review-error (funcall callback nil (cadr err)))))

(defun ez-review-github--repo (forge)
  "FORGE as the HOST/OWNER/REPO string gh expects after -R."
  (format "%s/%s" (ez-review-forge-host forge) (ez-review-forge-path forge)))

(defun ez-review-github--then (callback parse)
  "A `--run' callback that hands PARSE of the output (or the error) to CALLBACK."
  (lambda (ok out)
    (funcall callback
             (if ok
                 (condition-case err (funcall parse out)
                   (error (format "Unexpected gh output: %s" (error-message-string err))))
               out))))

(defun ez-review-github--api (forge method path callback &optional body)
  "Call the REST API at PATH with METHOD.
CALLBACK gets parsed JSON (pages flattened) or an error string.  BODY, a
plist, is sent as the JSON request body."
  (ez-review-github--run
   forge
   (append (list "api" "--method" method)
           (when (equal method "GET") '("--paginate" "--slurp"))
           (when body '("--input" "-"))
           (list path))
   (ez-review-github--then
    callback
    (lambda (out)
      (let ((data (ez-review-process-parse-json out)))
        (if (equal method "GET") (apply #'append data) data))))
   :input (and body (ez-review-process-json body))))

;;;; Converting JSON

(defun ez-review-github--labels (labels)
  (mapcar (lambda (l) (cons (plist-get l :name) (plist-get l :color))) labels))

(defun ez-review-github--check (c)
  "Normalize a status-check rollup entry C to (NAME . STATE)."
  (let ((name (or (plist-get c :name) (plist-get c :context)))
        (status (plist-get c :status))
        (concl (plist-get c :conclusion))
        (state (plist-get c :state)))
    (cons name
          (cond (state (pcase state
                         ("SUCCESS" 'success)
                         ((or "FAILURE" "ERROR") 'failure)
                         (_ 'pending)))
                ((not (equal status "COMPLETED")) 'pending)
                (t (pcase concl
                     ("SUCCESS" 'success)
                     ((or "SKIPPED" "NEUTRAL") 'skipped)
                     (_ 'failure)))))))

(defun ez-review-github--pr (j)
  "Build an `ez-review-pr' from gh JSON plist J."
  (make-ez-review-pr
   :number (plist-get j :number)
   :title (plist-get j :title)
   :author (plist-get (plist-get j :author) :login)
   :head (plist-get j :headRefName)
   :base (plist-get j :baseRefName)
   :draft (plist-get j :isDraft)
   :state (downcase (or (plist-get j :state) "open"))
   :url (plist-get j :url)
   :updated (plist-get j :updatedAt)
   :created (plist-get j :createdAt)
   :decision (when-let* ((d (plist-get j :reviewDecision)))
               (and (not (string-empty-p d)) (downcase d)))
   :body (plist-get j :body)
   :labels (ez-review-github--labels (plist-get j :labels))
   :checks (mapcar #'ez-review-github--check (plist-get j :statusCheckRollup))
   :additions (plist-get j :additions)
   :deletions (plist-get j :deletions)
   :files (plist-get j :changedFiles)
   :mergeable (when-let* ((m (plist-get j :mergeable))) (downcase m))
   :reviewers (mapcar (lambda (r) (or (plist-get r :login) (plist-get r :name)))
                      (plist-get j :reviewRequests))))

(defun ez-review-github--issue (j)
  (make-ez-review-issue
   :number (plist-get j :number)
   :title (plist-get j :title)
   :author (plist-get (plist-get j :author) :login)
   :state (downcase (or (plist-get j :state) "open"))
   :url (plist-get j :url)
   :updated (plist-get j :updatedAt)
   :created (plist-get j :createdAt)
   :body (plist-get j :body)
   :labels (ez-review-github--labels (plist-get j :labels))
   :assignees (mapcar (lambda (a) (plist-get a :login)) (plist-get j :assignees))))

(defun ez-review-github--comment (j kind)
  "Build an `ez-review-comment' of KIND from REST JSON J."
  (make-ez-review-comment
   :id (plist-get j :id)
   :thread (or (plist-get j :in_reply_to_id) (plist-get j :id))
   :author (plist-get (plist-get j :user) :login)
   :body (plist-get j :body)
   :created (or (plist-get j :created_at) (plist-get j :submitted_at))
   :kind kind
   :path (plist-get j :path)
   :side (if (equal (plist-get j :side) "LEFT") 'left 'right)
   :line (plist-get j :line)
   :original-line (plist-get j :original_line)
   :reply-to (plist-get j :in_reply_to_id)
   :state (when-let* ((s (plist-get j :state))) (downcase s))))

(defun ez-review-github--review-p (j)
  "Non-nil if review JSON J is worth showing."
  (let ((state (plist-get j :state))
        (body (string-trim (or (plist-get j :body) ""))))
    (and (not (equal state "PENDING"))
         (or (not (string-empty-p body))
             (member state '("APPROVED" "CHANGES_REQUESTED"))))))

(defun ez-review-github--sort (comments)
  (sort comments (lambda (a b) (string< (or (ez-review-comment-created a) "")
                                        (or (ez-review-comment-created b) "")))))

;;;; Interface

(defun ez-review-github--list-state (forge what filter state-arg limit callback)
  "One `gh ... list' for FORGE with --state STATE-ARG, at most LIMIT items."
  (let ((pr (eq what 'pr)))
    (ez-review-github--run
     forge
     (append (list (if pr "pr" "issue") "list" "--limit" (number-to-string limit) "--state" state-arg
                   "--json" (if pr ez-review-github--pr-fields ez-review-github--issue-fields)
                   "-R" (ez-review-github--repo forge))
             (pcase filter
               ('mine '("--author" "@me"))
               ('review (if pr '("--search" "review-requested:@me") '("--assignee" "@me")))))
     (ez-review-github--then
      callback
      (lambda (out)
        (mapcar (if pr #'ez-review-github--pr #'ez-review-github--issue)
                (ez-review-process-parse-json out)))))))

(cl-defmethod ez-review-forge-list ((forge ez-review-github) what opts callback)
  (let ((filter (plist-get opts :filter))
        (state (plist-get opts :state))
        (limit (or (plist-get opts :limit) ez-review-list-limit))
        (pr (eq what 'pr)))
    (if (and pr (eq state 'closed))
        ;; `gh --state closed' leaves out merged PRs; the web UI's "Closed" has both.
        (ez-review-process-gather
         (mapcar (lambda (arg) (lambda (cb) (ez-review-github--list-state forge what filter arg limit cb)))
                 '("closed" "merged"))
         (lambda (results)
           (funcall callback
                    (if (stringp results) results
                      (seq-take (ez-review-forge-merge-lists results) limit)))))
      (ez-review-github--list-state
       forge what filter
       (pcase state
         ('closed "closed")
         ('merged (if pr "merged" "closed"))
         ('all "all")
         (_ "open"))
       limit callback))))

(cl-defmethod ez-review-forge-view ((forge ez-review-github) what number callback)
  (let ((pr (eq what 'pr)))
    (ez-review-github--run
     forge
     (list (if pr "pr" "issue") "view" (number-to-string number)
           "--json" (if pr ez-review-github--pr-view-fields
                      (concat ez-review-github--issue-fields ",body"))
           "-R" (ez-review-github--repo forge))
     (ez-review-github--then
      callback
      (lambda (out)
        (funcall (if pr #'ez-review-github--pr #'ez-review-github--issue)
                 (ez-review-process-parse-json out)))))))

(cl-defmethod ez-review-forge-timeline ((forge ez-review-github) what number callback)
  (let* ((repo (ez-review-forge-path forge))
         (n number)
         (general (lambda (cb)
                    (ez-review-github--api
                     forge "GET" (format "repos/%s/issues/%d/comments" repo n)
                     (lambda (r) (funcall cb (if (stringp r) r
                                               (mapcar (lambda (j) (ez-review-github--comment j 'general)) r)))))))
         (inline (lambda (cb)
                   (ez-review-github--api
                    forge "GET" (format "repos/%s/pulls/%d/comments" repo n)
                    (lambda (r) (funcall cb (if (stringp r) r
                                              (mapcar (lambda (j) (ez-review-github--comment j 'inline)) r)))))))
         (reviews (lambda (cb)
                    (ez-review-github--api
                     forge "GET" (format "repos/%s/pulls/%d/reviews" repo n)
                     (lambda (r) (funcall cb (if (stringp r) r
                                               (mapcar (lambda (j) (ez-review-github--comment j 'review))
                                                       (seq-filter #'ez-review-github--review-p r)))))))))
    (ez-review-process-gather
     (if (eq what 'pr) (list general inline reviews) (list general))
     (lambda (results)
       (funcall callback (if (stringp results) results
                           (ez-review-github--sort (apply #'append results))))))))

(cl-defmethod ez-review-forge-diff ((forge ez-review-github) number callback)
  (ez-review-github--run
   forge (list "pr" "diff" (number-to-string number) "--color" "never"
               "-R" (ez-review-github--repo forge))
   (ez-review-github--then callback (lambda (out) (list :diff out)))))

(cl-defmethod ez-review-forge-users ((forge ez-review-github) callback)
  ;; first page only: a big organisation can have thousands of assignable users
  (ez-review-github--run
   forge (list "api" (format "repos/%s/assignees?per_page=100" (ez-review-forge-path forge)))
   (ez-review-github--then
    callback
    (lambda (out) (mapcar (lambda (u) (plist-get u :login)) (ez-review-process-parse-json out))))))

(defun ez-review-github--commit (j)
  (make-ez-review-commit
   :sha (plist-get j :oid)
   :subject (plist-get j :messageHeadline)
   :body (plist-get j :messageBody)
   :author (let ((a (car (plist-get j :authors)))) (or (plist-get a :login) (plist-get a :name)))
   :date (plist-get j :authoredDate)))

(cl-defmethod ez-review-forge-commits ((forge ez-review-github) number callback)
  (ez-review-github--run
   forge (list "pr" "view" (number-to-string number) "--json" "commits" "-R" (ez-review-github--repo forge))
   (ez-review-github--then
    callback
    (lambda (out) (mapcar #'ez-review-github--commit (plist-get (ez-review-process-parse-json out) :commits))))))

(cl-defmethod ez-review-forge-commit-diff ((forge ez-review-github) sha callback)
  (ez-review-github--run
   forge (list "api" "-H" "Accept: application/vnd.github.diff"
               (format "repos/%s/commits/%s" (ez-review-forge-path forge) sha))
   (ez-review-github--then callback (lambda (out) (list :diff out)))))

(cl-defmethod ez-review-forge-checkout ((forge ez-review-github) number callback)
  (ez-review-github--run
   forge (list "pr" "checkout" (number-to-string number) "-R" (ez-review-github--repo forge))
   (ez-review-github--then callback (lambda (_) t))))

(cl-defmethod ez-review-forge-create ((forge ez-review-github) what fields callback)
  (let ((pr (eq what 'pr)))
    (ez-review-github--run
     forge
     (append (list (if pr "pr" "issue") "create"
                   "--title" (plist-get fields :title)
                   "--body-file" "-"
                   "-R" (ez-review-github--repo forge))
             (when pr (list "--base" (plist-get fields :base) "--head" (plist-get fields :head)))
             (when (and pr (plist-get fields :draft)) '("--draft"))
             (cl-loop for l in (plist-get fields :labels) append (list "--label" l)))
     (ez-review-github--then callback (lambda (out) (car (last (split-string (string-trim out) "\n")))))
     :input (or (plist-get fields :body) ""))))

(cl-defmethod ez-review-forge-comment ((forge ez-review-github) what number body callback)
  (ez-review-github--run
   forge (list (if (eq what 'pr) "pr" "issue") "comment" (number-to-string number)
               "--body-file" "-" "-R" (ez-review-github--repo forge))
   (ez-review-github--then callback (lambda (_) t))
   :input body))

(cl-defmethod ez-review-forge-reply ((forge ez-review-github) number comment body callback)
  (ez-review-github--api
   forge "POST"
   (format "repos/%s/pulls/%d/comments/%d/replies"
           (ez-review-forge-path forge) number (ez-review-comment-id comment))
   (lambda (r) (funcall callback (if (stringp r) r t)))
   (list :body body)))

(cl-defmethod ez-review-forge-submit-review ((forge ez-review-github) number event body drafts callback)
  (ez-review-github--api
   forge "POST" (format "repos/%s/pulls/%d/reviews" (ez-review-forge-path forge) number)
   (lambda (r) (funcall callback (if (stringp r) r t)))
   (list :event (pcase event
                  ('approve "APPROVE")
                  ('request-changes "REQUEST_CHANGES")
                  (_ "COMMENT"))
         :body (or body "")
         :comments
         (vconcat
          (mapcar
           (lambda (d)
             (let ((side (if (eq (ez-review-draft-side d) 'left) "LEFT" "RIGHT")))
               (append (list :path (ez-review-draft-path d)
                             :line (ez-review-draft-line d)
                             :side side
                             :body (ez-review-draft-body d))
                       (when (ez-review-draft-start-line d)
                         (list :start_line (ez-review-draft-start-line d)
                               :start_side side)))))
           drafts)))))

(cl-defmethod ez-review-forge-post-inline ((forge ez-review-github) number draft callback)
  ;; A single review comment must name the commit it is about: the PR's head.
  (ez-review-github--run
   forge (list "pr" "view" (number-to-string number) "--json" "headRefOid" "-R" (ez-review-github--repo forge))
   (lambda (ok out)
     (if (not ok)
         (funcall callback out)
       (let ((sha (condition-case nil (plist-get (ez-review-process-parse-json out) :headRefOid) (error nil)))
             (side (if (eq (ez-review-draft-side draft) 'left) "LEFT" "RIGHT")))
         (if (not sha)
             (funcall callback "Could not read the PR's head commit")
           (ez-review-github--api
            forge "POST" (format "repos/%s/pulls/%d/comments" (ez-review-forge-path forge) number)
            (lambda (r) (funcall callback (if (stringp r) r t)))
            (append (list :body (ez-review-draft-body draft) :commit_id sha
                          :path (ez-review-draft-path draft) :line (ez-review-draft-line draft) :side side)
                    (when (ez-review-draft-start-line draft)
                      (list :start_line (ez-review-draft-start-line draft) :start_side side))))))))))

(cl-defmethod ez-review-forge-merge ((forge ez-review-github) number method delete-branch callback)
  (ez-review-github--run
   forge (append (list "pr" "merge" (number-to-string number)
                       (pcase method ('squash "--squash") ('rebase "--rebase") (_ "--merge"))
                       "-R" (ez-review-github--repo forge))
                 (when delete-branch '("--delete-branch")))
   (ez-review-github--then callback (lambda (_) t))))

(cl-defmethod ez-review-forge-set-state ((forge ez-review-github) what number state callback)
  (ez-review-github--run
   forge (list (if (eq what 'pr) "pr" "issue") (if (eq state 'closed) "close" "reopen")
               (number-to-string number) "-R" (ez-review-github--repo forge))
   (ez-review-github--then callback (lambda (_) t))))

(cl-defmethod ez-review-forge-browse ((forge ez-review-github) what number)
  (browse-url (format "https://%s/%s/%s/%d" (ez-review-forge-host forge) (ez-review-forge-path forge)
                      (if (eq what 'pr) "pull" "issues") number)))

(provide 'ez-review-github)
;;; ez-review-github.el ends here
