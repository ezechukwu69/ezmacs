;;; ez-review-forge.el --- Platform detection and backend interface -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A "forge" here is one hosted repository: platform (GitHub or GitLab), host,
;; and the owner/repo path, resolved from a git remote.  The generic functions
;; below are the whole backend interface; `ez-review-github.el' and
;; `ez-review-gitlab.el' implement them on top of `gh' and `glab'.  Both
;; return the same `ez-review-pr' record so the UI is platform-blind.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)

(defcustom ez-review-remote "origin"
  "Git remote whose URL decides the repository to review."
  :type 'string
  :group 'ez-review)

(defcustom ez-review-list-limit 100
  "How many PRs/MRs or issues one list fetches.
The list buffer's \"load more\" key raises it by this much each time."
  :type 'integer
  :group 'ez-review)

(defcustom ez-review-host-alist '(("github.com" . github)
                                  ("gitlab.com" . gitlab))
  "Map from host name to platform, `github' or `gitlab'.
Hosts missing here (self-hosted GitLab, GitHub Enterprise) are detected from
which CLI is logged in to them, and the answer is remembered for the session."
  :type '(alist :key-type string :value-type (choice (const github) (const gitlab)))
  :group 'ez-review)

;;;; Records

(cl-defstruct (ez-review-forge (:constructor nil)) host path dir)
(cl-defstruct (ez-review-github (:include ez-review-forge) (:constructor ez-review-github--create)))
(cl-defstruct (ez-review-gitlab (:include ez-review-forge) (:constructor ez-review-gitlab--create)))

;; Labels are (NAME . HEX-COLOR-OR-NIL).  Checks are (NAME . STATE) with STATE one of
;; `success', `failure', `pending', `skipped'.
(cl-defstruct ez-review-pr
  "A pull request (GitHub) or merge request (GitLab)."
  number title author head base draft state url updated created decision body
  labels checks additions deletions files mergeable reviewers refs)

(cl-defstruct ez-review-issue
  "An issue."
  number title author state url updated created body labels assignees)

(cl-defstruct ez-review-commit
  "One commit of a PR/MR."
  sha subject body author date)

(cl-defstruct ez-review-comment
  "One comment, review or discussion note.
KIND is `general', `inline' or `review'.  For inline comments PATH, SIDE
(`left' or `right') and LINE locate it in the diff; THREAD groups replies.
LINE is nil for an outdated comment (its code changed in a later commit);
ORIGINAL-LINE is then where it was when written, in that older commit."
  id thread author body created kind path side line original-line state reply-to resolved)

;; A pending inline comment, not yet sent.  SIDE is `left' (a removed line, LINE
;; counts in the old file) or `right' (added or unchanged, LINE counts in the new
;; file).  OLD-LINE / NEW-LINE are both kept because GitLab wants both for
;; unchanged lines.  START-LINE (same side) makes it a range.
(cl-defstruct ez-review-draft
  path old-path side line old-line new-line start-line body)

(defun ez-review-forge-kind (forge)
  "Platform symbol of FORGE."
  (cond ((ez-review-github-p forge) 'github)
        ((ez-review-gitlab-p forge) 'gitlab)))

(defun ez-review-forge-noun (forge &optional plural)
  "\"PR\" or \"MR\" for FORGE; PLURAL appends an s."
  (concat (if (eq (ez-review-forge-kind forge) 'gitlab) "MR" "PR") (and plural "s")))

;;;; Remote URL parsing

(defun ez-review-forge-parse-url (url)
  "Split remote URL into (HOST . PATH), or nil.  Handles https, ssh and scp forms."
  (let ((url (string-trim url)))
    (cond
     ((string-match "\\`[a-z+]+://\\(?:[^@/]+@\\)?\\([^/:]+\\)\\(?::[0-9]+\\)?/\\(.+?\\)\\(?:\\.git\\)?/?\\'" url)
      (cons (match-string 1 url) (match-string 2 url)))
     ((string-match "\\`\\(?:[^@/]+@\\)?\\([^/:]+\\):\\(.+?\\)\\(?:\\.git\\)?/?\\'" url)
      (cons (match-string 1 url) (match-string 2 url))))))

(defun ez-review-forge--git-root (&optional dir)
  "Top level of the git work tree containing DIR."
  (let ((default-directory (or dir default-directory)))
    (when-let* ((root (locate-dominating-file default-directory ".git")))
      (expand-file-name root))))

(defun ez-review-forge--remote-url (root)
  "URL of `ez-review-remote' in ROOT, falling back to the first remote."
  (let ((rem (or (and (zerop (car (ez-review-process-sync
                                   "git" (list "remote" "get-url" ez-review-remote) :dir root)))
                      ez-review-remote)
                 (car (split-string
                       (nth 1 (ez-review-process-sync "git" '("remote") :dir root)) "\n" t)))))
    (unless rem
      (signal 'ez-review-error (list "Repository has no git remotes")))
    (string-trim (ez-review-process-check
                  (ez-review-process-sync "git" (list "remote" "get-url" rem) :dir root)
                  "git remote get-url"))))

;;;; Platform detection

(defun ez-review-forge--logged-in-p (program host)
  "Non-nil if PROGRAM (gh or glab) is authenticated to HOST."
  (condition-case nil
      (eql 0 (car (ez-review-process-sync program (list "auth" "status" "--hostname" host))))
    (ez-review-error nil)))

(defun ez-review-forge--detect-kind (host)
  "Platform symbol for HOST, from the alist or from CLI logins."
  (or (alist-get host ez-review-host-alist nil nil #'equal)
      (let ((kind (cond ((ez-review-forge--logged-in-p ez-review-glab-program host) 'gitlab)
                        ((ez-review-forge--logged-in-p ez-review-gh-program host) 'github)
                        (t (intern (completing-read
                                    (format "Platform of %s: " host) '("github" "gitlab") nil t))))))
        (push (cons host kind) ez-review-host-alist)
        kind)))

;;;###autoload
(defun ez-review-forge-current (&optional dir)
  "The forge for the repository containing DIR (default `default-directory')."
  (let* ((root (or (ez-review-forge--git-root dir)
                   (signal 'ez-review-error (list "Not inside a git repository"))))
         (parsed (or (ez-review-forge-parse-url (ez-review-forge--remote-url root))
                     (signal 'ez-review-error (list "Cannot parse the remote URL"))))
         (host (car parsed))
         (kind (ez-review-forge--detect-kind host)))
    (funcall (if (eq kind 'gitlab) #'ez-review-gitlab--create #'ez-review-github--create)
             :host host :path (cdr parsed) :dir root)))

;;;; Backend interface

(defun ez-review-forge-merge-lists (lists)
  "Join LISTS of items (PRs) into one, newest update first, without duplicates."
  (let (seen out)
    (dolist (item (apply #'append lists))
      (let ((n (ez-review-pr-number item)))
        (unless (memq n seen) (push n seen) (push item out))))
    (sort out (lambda (a b) (string> (or (ez-review-pr-updated a) "") (or (ez-review-pr-updated b) ""))))))

(defvar ez-review-forge-draft-posted-hook nil
  "Abnormal hook run with a draft once a backend has sent it for real.
Backends that cannot post a review atomically (GitLab) call it per comment, so a
failure part-way does not make a retry duplicate what already went out.")

;;
;; WHAT is `pr' or `issue'.  Every function that talks to the network is
;; asynchronous: CALLBACK receives the result, or an error *string*.

(cl-defgeneric ez-review-forge-env (forge)
  "Environment alist that points the CLI at FORGE's host.")

(cl-defgeneric ez-review-forge-list (forge what opts callback)
  "List items of kind WHAT.
OPTS is a plist: :limit (how many to fetch), :filter (`all', `mine', `review'),
:state (`open', `closed',
`merged', `all').  PR state `closed' includes merged ones, as on the web.
CALLBACK gets a list of `ez-review-pr' or `ez-review-issue'.")

(cl-defgeneric ez-review-forge-view (forge what number callback)
  "Fetch item NUMBER in full, with body, labels and checks.")

(cl-defgeneric ez-review-forge-timeline (forge what number callback)
  "Fetch the comments of item NUMBER, oldest first.
CALLBACK gets a list of `ez-review-comment'.")

(cl-defgeneric ez-review-forge-diff (forge number callback)
  "Fetch the unified diff of PR NUMBER.
CALLBACK gets (:diff TEXT), a list rather than the bare string so that a
result can never be mistaken for an error string.")

(cl-defgeneric ez-review-forge-users (forge callback)
  "Fetch usernames that can be @-mentioned in FORGE's repository.
CALLBACK gets a list of strings (at most one page of the project's
assignable users or members), or an error string.")

(cl-defgeneric ez-review-forge-commits (forge number callback)
  "Fetch the commits of PR NUMBER, oldest first, as a list of `ez-review-commit'.")

(cl-defgeneric ez-review-forge-commit-diff (forge sha callback)
  "Fetch the unified diff introduced by commit SHA.
CALLBACK gets (:diff TEXT), or an error string.")

(cl-defgeneric ez-review-forge-checkout (forge number callback)
  "Check out PR NUMBER in the work tree.  CALLBACK gets t.")

(cl-defgeneric ez-review-forge-create (forge what fields callback)
  "Create an item of kind WHAT from FIELDS, a plist.
PR fields: :title :body :base :head :draft :labels.  Issue fields: :title
:body :labels.  CALLBACK gets the new item's URL.")

(cl-defgeneric ez-review-forge-comment (forge what number body callback)
  "Add a general comment BODY to item NUMBER.")

(cl-defgeneric ez-review-forge-reply (forge number comment body callback)
  "Reply BODY to inline COMMENT (an `ez-review-comment') on PR NUMBER.")

(cl-defgeneric ez-review-forge-post-inline (forge number draft callback)
  "Post DRAFT, an `ez-review-draft', as one standalone inline comment on PR NUMBER.
No review is started.  CALLBACK gets t, or an error string.")

(cl-defgeneric ez-review-forge-submit-review (forge number event body drafts callback)
  "Submit a review of PR NUMBER.
EVENT is `comment', `approve' or `request-changes'.  BODY is the summary text
or nil.  DRAFTS is a list of `ez-review-draft'.")

(cl-defgeneric ez-review-forge-merge (forge number method delete-branch callback)
  "Merge PR NUMBER with METHOD (`merge', `squash' or `rebase').")

(cl-defgeneric ez-review-forge-set-state (forge what number state callback)
  "Set item NUMBER to STATE, `closed' or `open'.")

(cl-defgeneric ez-review-forge-browse (forge what number)
  "Open item NUMBER in the web browser.")

;;;; @-mention candidates

(defvar ez-review-forge--users (make-hash-table :test #'equal)
  "(HOST . PATH) -> usernames fetched for @-completion, once per session.")
(defvar ez-review-forge--users-pending (make-hash-table :test #'equal)
  "(HOST . PATH) -> t while a fetch is running.")

(defun ez-review-forge--users-key (forge)
  (cons (ez-review-forge-host forge) (ez-review-forge-path forge)))

(defun ez-review-forge-prefetch-users (forge)
  "Start fetching FORGE's mentionable users in the background, once."
  (let ((key (ez-review-forge--users-key forge)))
    (when (and (eq (gethash key ez-review-forge--users 'unset) 'unset)
               (not (gethash key ez-review-forge--users-pending)))
      (puthash key t ez-review-forge--users-pending)
      (ez-review-forge-users
       forge
       (lambda (result)
         (remhash key ez-review-forge--users-pending)
         ;; an error is remembered as "none" so a flaky or forbidden call is not repeated
         (puthash key (if (stringp result) nil result) ez-review-forge--users))))))

(defun ez-review-forge-mention-function (forge people)
  "A function giving the names to complete after `@' in a comment on FORGE.
PEOPLE is a list of usernames, or a function returning one: the participants
of the item, listed first.  Starts the background fetch of the rest."
  (ez-review-forge-prefetch-users forge)
  (lambda ()
    (let ((known (if (functionp people) (funcall people) people)))
      (cl-delete-duplicates
       (mapcar (lambda (n) (string-remove-prefix "@" n))
               (delq nil (append known (gethash (ez-review-forge--users-key forge)
                                                ez-review-forge--users))))
       :test #'string= :from-end t))))

(provide 'ez-review-forge)
;;; ez-review-forge.el ends here
