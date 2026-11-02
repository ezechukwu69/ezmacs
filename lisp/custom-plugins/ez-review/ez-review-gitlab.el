;;; ez-review-gitlab.el --- GitLab backend using glab -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Implements the `ez-review-forge' interface with the GitLab CLI.  Nearly
;; everything goes through `glab api' (REST), which behaves the same on
;; gitlab.com and self-hosted instances: the host is passed in GITLAB_HOST, so
;; the CLI's own stored login for that host is used.  Only the diff and the
;; checkout use porcelain commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'ez-review-process)
(require 'ez-review-forge)

;;;; Running glab

(cl-defmethod ez-review-forge-env ((forge ez-review-gitlab))
  `(("GITLAB_HOST" . ,(ez-review-forge-host forge))
    ("NO_PROMPT" . "1")
    ("NO_COLOR" . "1")))

(cl-defun ez-review-gitlab--run (forge args callback &key input)
  "Run `glab' with ARGS for FORGE; CALLBACK gets (OK STDOUT-OR-ERROR)."
  (condition-case err
      (ez-review-process-run
       ez-review-glab-program args
       (lambda (code out stderr)
         (funcall callback (eql code 0)
                  (if (eql code 0) out (ez-review-process-error-text code out stderr "glab"))))
       :dir (ez-review-forge-dir forge) :env (ez-review-forge-env forge) :input input)
    (ez-review-error (funcall callback nil (cadr err)))))

(defun ez-review-gitlab--then (callback parse)
  "A `--run' callback that hands PARSE of the output (or the error) to CALLBACK."
  (lambda (ok out)
    (funcall callback
             (if ok
                 (condition-case err (funcall parse out)
                   (error (format "Unexpected glab output: %s" (error-message-string err))))
               out))))

(defun ez-review-gitlab--project (forge)
  "FORGE's project path URL-encoded for use in API paths."
  (url-hexify-string (ez-review-forge-path forge)))

(defun ez-review-gitlab--api (forge method path callback &optional body)
  "Call the REST API.  CALLBACK gets parsed JSON or an error string.
PATH is relative to the API root.  BODY, a plist, is sent as JSON."
  (ez-review-gitlab--run
   forge
   (append (list "api" "--method" method)
           (when (and (equal method "GET") (string-match-p "per_page=" path)
                      ;; an explicit page= means the caller pages by hand
                      (not (string-match-p "[?&]page=" path)))
             '("--paginate"))
           (when body '("--input" "-" "-H" "Content-Type: application/json"))
           (list path))
   (ez-review-gitlab--then callback #'ez-review-process-parse-json)
   :input (and body (ez-review-process-json body))))

(defvar ez-review-gitlab--users (make-hash-table :test #'equal)
  "Host -> username of the logged in user.")

(defun ez-review-gitlab--me (forge)
  "Username FORGE's CLI is logged in as (cached)."
  (let ((host (ez-review-forge-host forge)))
    (or (gethash host ez-review-gitlab--users)
        (let* ((out (ez-review-process-check
                     (ez-review-process-sync ez-review-glab-program '("api" "user")
                                             :dir (ez-review-forge-dir forge)
                                             :env (ez-review-forge-env forge))
                     "glab api user")))
          (puthash host (plist-get (ez-review-process-parse-json out) :username)
                   ez-review-gitlab--users)))))

;;;; Converting JSON

(defun ez-review-gitlab--state (s)
  (pcase s ("opened" "open") (_ (or s "open"))))

(defun ez-review-gitlab--labels (labels)
  (mapcar (lambda (l) (if (stringp l) (cons l nil) (cons (plist-get l :name) (plist-get l :color))))
          labels))

(defun ez-review-gitlab--pipeline (pipeline)
  "Checks list from a head PIPELINE plist."
  (when pipeline
    (list (cons "pipeline"
                (pcase (plist-get pipeline :status)
                  ((or "success" "passed") 'success)
                  ((or "failed") 'failure)
                  ((or "canceled" "skipped" "manual") 'skipped)
                  (_ 'pending))))))

(defun ez-review-gitlab--pr (j)
  "Build an `ez-review-pr' from API JSON plist J."
  (let ((refs (plist-get j :diff_refs)))
    (make-ez-review-pr
     :number (plist-get j :iid)
     :title (plist-get j :title)
     :author (plist-get (plist-get j :author) :username)
     :head (plist-get j :source_branch)
     :base (plist-get j :target_branch)
     :draft (or (plist-get j :draft) (plist-get j :work_in_progress))
     :state (ez-review-gitlab--state (plist-get j :state))
     :url (plist-get j :web_url)
     :updated (plist-get j :updated_at)
     :created (plist-get j :created_at)
     :body (plist-get j :description)
     :labels (ez-review-gitlab--labels (plist-get j :labels))
     :checks (ez-review-gitlab--pipeline (plist-get j :head_pipeline))
     :files (when-let* ((c (plist-get j :changes_count))) (if (stringp c) (string-to-number c) c))
     :mergeable (plist-get j :detailed_merge_status)
     :reviewers (mapcar (lambda (u) (plist-get u :username)) (plist-get j :reviewers))
     :refs (when refs (list :base (plist-get refs :base_sha)
                            :start (plist-get refs :start_sha)
                            :head (plist-get refs :head_sha))))))

(defun ez-review-gitlab--issue (j)
  (make-ez-review-issue
   :number (plist-get j :iid)
   :title (plist-get j :title)
   :author (plist-get (plist-get j :author) :username)
   :state (ez-review-gitlab--state (plist-get j :state))
   :url (plist-get j :web_url)
   :updated (plist-get j :updated_at)
   :created (plist-get j :created_at)
   :body (plist-get j :description)
   :labels (ez-review-gitlab--labels (plist-get j :labels))
   :assignees (mapcar (lambda (u) (plist-get u :username)) (plist-get j :assignees))))

(defun ez-review-gitlab--notes (discussion)
  "Comments from one DISCUSSION plist, skipping system notes."
  (let ((thread (plist-get discussion :id))
        first)
    (cl-loop
     for note in (plist-get discussion :notes)
     unless (plist-get note :system)
     collect (let* ((pos (plist-get note :position))
                    (new (plist-get pos :new_line))
                    (old (plist-get pos :old_line))
                    (c (make-ez-review-comment
                        :id (plist-get note :id)
                        :thread thread
                        :author (plist-get (plist-get note :author) :username)
                        :body (plist-get note :body)
                        :created (plist-get note :created_at)
                        :kind (if pos 'inline 'general)
                        :path (and pos (or (plist-get pos :new_path) (plist-get pos :old_path)))
                        :side (if new 'right 'left)
                        :line (or new old)
                        :reply-to (and first (plist-get first :id))
                        :resolved (plist-get note :resolved))))
               (unless first (setq first note))
               c))))

(defun ez-review-gitlab--sort (comments)
  (sort comments (lambda (a b) (string< (or (ez-review-comment-created a) "")
                                        (or (ez-review-comment-created b) "")))))

(defun ez-review-gitlab--item-path (forge what number &optional suffix)
  "API path of item NUMBER of kind WHAT."
  (format "projects/%s/%s/%d%s" (ez-review-gitlab--project forge)
          (if (eq what 'pr) "merge_requests" "issues") number (or suffix "")))

;;;; Interface

(defun ez-review-gitlab--list-state (forge what filter who state limit callback)
  "List up to LIMIT items for FORGE with API STATE; WHO is the user for FILTER.
Pages of 100 are requested one by one, so a big project is never read in full."
  (let* ((pr (eq what 'pr))
         (pages (max 1 (ceiling limit 100.0)))
         (query (lambda (page)
                  (format "projects/%s/%s?%s" (ez-review-gitlab--project forge)
                          (if pr "merge_requests" "issues")
                          (concat (format "state=%s&per_page=%d&page=%d&order_by=updated_at"
                                          state (min limit 100) page)
                                  (pcase filter
                                    ('mine (format "&author_username=%s" who))
                                    ('review (format (if pr "&reviewer_username=%s" "&assignee_username=%s")
                                                     who))))))))
    (ez-review-process-gather
     (cl-loop for page from 1 to pages
              collect (let ((page page))
                        (lambda (cb)
                          (ez-review-gitlab--api forge "GET" (funcall query page)
                                                 (lambda (r) (funcall cb (if (stringp r) r (or r '(:none)))))))))
     (lambda (results)
       (funcall callback
                (if (stringp results) results
                  (seq-take
                   (mapcar (if pr #'ez-review-gitlab--pr #'ez-review-gitlab--issue)
                           (cl-remove '(:none) (apply #'append results) :test #'equal))
                   limit)))))))

(cl-defmethod ez-review-forge-list ((forge ez-review-gitlab) what opts callback)
  (let* ((pr (eq what 'pr))
         (filter (plist-get opts :filter))
         (state (plist-get opts :state))
         (limit (or (plist-get opts :limit) ez-review-list-limit))
         (who (when (memq filter '(mine review))
                (condition-case err (ez-review-gitlab--me forge)
                  (ez-review-error (cadr err))))))
    (if (and (memq filter '(mine review)) (not (and who (not (string-match-p " " who)))))
        (funcall callback (or who "Cannot determine your GitLab username"))
      (if (and pr (eq state 'closed))
          ;; GitLab keeps merged MRs apart from closed ones; the web "Closed" has both.
          (ez-review-process-gather
           (mapcar (lambda (st) (lambda (cb) (ez-review-gitlab--list-state forge what filter who st limit cb)))
                   '("closed" "merged"))
           (lambda (results)
             (funcall callback (if (stringp results) results
                                 (seq-take (ez-review-forge-merge-lists results) limit)))))
        (ez-review-gitlab--list-state
         forge what filter who
         (pcase state
           ('closed "closed")
           ('merged (if pr "merged" "closed"))
           ('all "all")
           (_ "opened"))
         limit callback)))))

(cl-defmethod ez-review-forge-view ((forge ez-review-gitlab) what number callback)
  (if (eq what 'issue)
      (ez-review-gitlab--api forge "GET" (ez-review-gitlab--item-path forge what number)
                             (lambda (r) (funcall callback (if (stringp r) r (ez-review-gitlab--issue r)))))
    (ez-review-process-gather
     (list (lambda (cb) (ez-review-gitlab--api forge "GET" (ez-review-gitlab--item-path forge 'pr number) cb))
           ;; approvals are a paid-tier API on some hosts; their absence is not an error
           (lambda (cb) (ez-review-gitlab--api
                         forge "GET" (ez-review-gitlab--item-path forge 'pr number "/approvals")
                         (lambda (r) (funcall cb (if (stringp r) nil r))))))
     (lambda (results)
       (if (stringp results)
           (funcall callback results)
         (let ((pr (ez-review-gitlab--pr (car results)))
               (approvals (cadr results)))
           (when (and approvals (or (plist-get approvals :approved) (plist-get approvals :approved_by)))
             (setf (ez-review-pr-decision pr) "approved"))
           (funcall callback pr)))))))

(cl-defmethod ez-review-forge-timeline ((forge ez-review-gitlab) what number callback)
  (ez-review-gitlab--api
   forge "GET" (ez-review-gitlab--item-path forge what number "/discussions?per_page=100")
   (lambda (r)
     (funcall callback (if (stringp r) r
                         (ez-review-gitlab--sort (apply #'append (mapcar #'ez-review-gitlab--notes r))))))))

(cl-defmethod ez-review-forge-diff ((forge ez-review-gitlab) number callback)
  (ez-review-gitlab--run
   forge (list "mr" "diff" (number-to-string number) "--raw" "--color" "never"
               "-R" (ez-review-forge-path forge))
   (ez-review-gitlab--then callback (lambda (out) (list :diff out)))))

(cl-defmethod ez-review-forge-users ((forge ez-review-gitlab) callback)
  ;; page=1 makes `--api' ask for just this page instead of every page
  (ez-review-gitlab--api
   forge "GET" (format "projects/%s/members/all?per_page=100&page=1" (ez-review-gitlab--project forge))
   (lambda (r)
     (funcall callback (if (stringp r) r (mapcar (lambda (u) (plist-get u :username)) r))))))

(defun ez-review-gitlab--commit (j)
  (make-ez-review-commit
   :sha (plist-get j :id) :subject (plist-get j :title) :body (plist-get j :message)
   :author (plist-get j :author_name) :date (plist-get j :authored_date)))

(cl-defmethod ez-review-forge-commits ((forge ez-review-gitlab) number callback)
  (ez-review-gitlab--api
   forge "GET" (ez-review-gitlab--item-path forge 'pr number "/commits?per_page=100")
   (lambda (r)
     ;; the API lists newest first
     (funcall callback (if (stringp r) r (nreverse (mapcar #'ez-review-gitlab--commit r)))))))

(defun ez-review-gitlab--changes-to-diff (changes)
  "Rebuild a git-style unified diff from the API's per-file CHANGES."
  (mapconcat
   (lambda (c)
     (let ((old (plist-get c :old_path)) (new (plist-get c :new_path))
           (added (plist-get c :new_file)) (deleted (plist-get c :deleted_file)))
       (concat (format "diff --git a/%s b/%s\n" old new)
               (cond (added "new file mode 100644\n")
                     (deleted "deleted file mode 100644\n")
                     ((plist-get c :renamed_file) (format "rename from %s\nrename to %s\n" old new))
                     (t ""))
               (format "--- %s\n+++ %s\n" (if added "/dev/null" (concat "a/" old))
                       (if deleted "/dev/null" (concat "b/" new)))
               (or (plist-get c :diff) ""))))
   changes ""))

(cl-defmethod ez-review-forge-commit-diff ((forge ez-review-gitlab) sha callback)
  (ez-review-gitlab--api
   forge "GET" (format "projects/%s/repository/commits/%s/diff?per_page=100"
                       (ez-review-gitlab--project forge) sha)
   (lambda (r)
     (funcall callback (if (stringp r) r (list :diff (ez-review-gitlab--changes-to-diff r)))))))

(cl-defmethod ez-review-forge-checkout ((forge ez-review-gitlab) number callback)
  (ez-review-gitlab--run
   forge (list "mr" "checkout" (number-to-string number) "-R" (ez-review-forge-path forge))
   (ez-review-gitlab--then callback (lambda (_) t))))

(cl-defmethod ez-review-forge-create ((forge ez-review-gitlab) what fields callback)
  (let* ((pr (eq what 'pr))
         (title (plist-get fields :title))
         (labels (string-join (plist-get fields :labels) ",")))
    (ez-review-gitlab--api
     forge "POST" (format "projects/%s/%s" (ez-review-gitlab--project forge)
                          (if pr "merge_requests" "issues"))
     (lambda (r) (funcall callback (if (stringp r) r (plist-get r :web_url))))
     (append (list :title (if (and pr (plist-get fields :draft)) (concat "Draft: " title) title)
                   :description (or (plist-get fields :body) ""))
             (unless (string-empty-p labels) (list :labels labels))
             (when pr (list :source_branch (plist-get fields :head)
                            :target_branch (plist-get fields :base)))))))

(cl-defmethod ez-review-forge-comment ((forge ez-review-gitlab) what number body callback)
  (ez-review-gitlab--api
   forge "POST" (ez-review-gitlab--item-path forge what number "/notes")
   (lambda (r) (funcall callback (if (stringp r) r t)))
   (list :body body)))

(cl-defmethod ez-review-forge-reply ((forge ez-review-gitlab) number comment body callback)
  (ez-review-gitlab--api
   forge "POST"
   (ez-review-gitlab--item-path forge 'pr number
                                (format "/discussions/%s/notes" (ez-review-comment-thread comment)))
   (lambda (r) (funcall callback (if (stringp r) r t)))
   (list :body body)))

(defun ez-review-gitlab--position (refs d)
  "The discussion POSITION plist for draft D given diff REFS."
  (append (list :position_type "text"
                :base_sha (plist-get refs :base)
                :start_sha (plist-get refs :start)
                :head_sha (plist-get refs :head)
                :old_path (or (ez-review-draft-old-path d) (ez-review-draft-path d))
                :new_path (ez-review-draft-path d))
          (pcase (ez-review-draft-side d)
            ('left (list :old_line (ez-review-draft-line d)))
            (_ (append (list :new_line (ez-review-draft-line d))
                       (when (ez-review-draft-old-line d)
                         (list :old_line (ez-review-draft-old-line d))))))))

(cl-defmethod ez-review-forge-submit-review ((forge ez-review-gitlab) number event body drafts callback)
  ;; GitLab has no atomic "review" over the API: post each comment as its own
  ;; discussion, then the summary, then the approval.
  (let ((total (length drafts)) (done 0))
    (cl-labels
        ((fail (err) (funcall callback
                              (if (> total 0)
                                  (format "%s (%d of %d comments were posted)" err done total)
                                err)))
         (finish ()
           (pcase event
             ('approve
              (ez-review-gitlab--api
               forge "POST" (ez-review-gitlab--item-path forge 'pr number "/approve")
               (lambda (r) (if (stringp r) (fail r) (funcall callback t)))))
             (_ (funcall callback t))))
         (summary ()
           (if (and body (not (string-empty-p (string-trim body))))
               (ez-review-gitlab--api
                forge "POST" (ez-review-gitlab--item-path forge 'pr number "/notes")
                (lambda (r) (if (stringp r) (fail r) (finish)))
                (list :body body))
             (finish)))
         (post (remaining refs)
           (if (null remaining)
               (summary)
             (let ((d (car remaining)))
               (ez-review-gitlab--api
                forge "POST" (ez-review-gitlab--item-path forge 'pr number "/discussions")
                (lambda (r)
                  (if (stringp r)
                      (fail r)
                    (cl-incf done)
                    (run-hook-with-args 'ez-review-forge-draft-posted-hook d)
                    (post (cdr remaining) refs)))
                (list :body (ez-review-draft-body d)
                      :position (ez-review-gitlab--position refs d)))))))
      (cond
       ((eq event 'request-changes)
        (funcall callback "GitLab has no \"request changes\" review state; leave a comment instead"))
       ((null drafts) (summary))
       (t (ez-review-gitlab--api
           forge "GET" (ez-review-gitlab--item-path forge 'pr number)
           (lambda (r)
             (if (stringp r)
                 (fail r)
               (post drafts (ez-review-pr-refs (ez-review-gitlab--pr r)))))))))))

(cl-defmethod ez-review-forge-post-inline ((forge ez-review-gitlab) number draft callback)
  ;; a discussion anchored with the MR's current diff refs; no review involved
  (ez-review-gitlab--api
   forge "GET" (ez-review-gitlab--item-path forge 'pr number)
   (lambda (r)
     (if (stringp r)
         (funcall callback r)
       (ez-review-gitlab--api
        forge "POST" (ez-review-gitlab--item-path forge 'pr number "/discussions")
        (lambda (r2) (funcall callback (if (stringp r2) r2 t)))
        (list :body (ez-review-draft-body draft)
              :position (ez-review-gitlab--position (ez-review-pr-refs (ez-review-gitlab--pr r)) draft)))))))

(cl-defmethod ez-review-forge-merge ((forge ez-review-gitlab) number method delete-branch callback)
  (if (eq method 'rebase)
      (funcall callback "GitLab rebase-merge is a project setting; use merge or squash")
    (ez-review-gitlab--api
     forge "PUT" (ez-review-gitlab--item-path forge 'pr number "/merge")
     (lambda (r) (funcall callback (if (stringp r) r t)))
     (list :squash (if (eq method 'squash) t :false)
           :should_remove_source_branch (if delete-branch t :false)))))

(cl-defmethod ez-review-forge-set-state ((forge ez-review-gitlab) what number state callback)
  (ez-review-gitlab--api
   forge "PUT" (ez-review-gitlab--item-path forge what number)
   (lambda (r) (funcall callback (if (stringp r) r t)))
   (list :state_event (if (eq state 'closed) "close" "reopen"))))

(cl-defmethod ez-review-forge-browse ((forge ez-review-gitlab) what number)
  (browse-url (format "https://%s/%s/-/%s/%d" (ez-review-forge-host forge) (ez-review-forge-path forge)
                      (if (eq what 'pr) "merge_requests" "issues") number)))

(provide 'ez-review-gitlab)
;;; ez-review-gitlab.el ends here
