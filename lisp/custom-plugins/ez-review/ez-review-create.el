;;; ez-review-create.el --- Open new PRs, MRs and issues -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `ez-review-create-pr' pre-fills a compose buffer from your branch (title
;; from the last commit, body from the commit list or the repository's PR
;; template).  The first lines are `Title:', `Base:', `Draft:' and `Labels:';
;; after the blank line comes the description.  If the branch is not on the
;; remote yet you are asked to push it first.  Nothing is created until you
;; confirm.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)
(require 'ez-review-compose)
(require 'ez-review-actions)

(declare-function ez-review-view "ez-review-view")

(defun ez-review-create--git (forge &rest args)
  "Run git with ARGS in FORGE's work tree; return trimmed stdout or nil on failure."
  (pcase-let ((`(,code ,out ,_) (ez-review-process-sync "git" args :dir (ez-review-forge-dir forge))))
    (and (eql code 0) (string-trim out))))

(defun ez-review-create--default-base (forge)
  "The remote's default branch."
  (or (when-let* ((ref (ez-review-create--git forge "symbolic-ref" "--short"
                                              (format "refs/remotes/%s/HEAD" ez-review-remote))))
        (string-remove-prefix (concat ez-review-remote "/") ref))
      (cl-find-if (lambda (b) (ez-review-create--git forge "rev-parse" "--verify" "--quiet" b))
                  '("main" "master"))
      "main"))

(defun ez-review-create--template (forge)
  "Contents of the repository's PR/MR template, or nil."
  (cl-some (lambda (rel)
             (let ((f (expand-file-name rel (ez-review-forge-dir forge))))
               (when (file-readable-p f)
                 (with-temp-buffer (insert-file-contents f) (buffer-string)))))
           '(".github/pull_request_template.md" ".github/PULL_REQUEST_TEMPLATE.md"
             "pull_request_template.md" ".gitlab/merge_request_templates/Default.md")))

(defun ez-review-create--body-from-commits (forge base)
  (let ((subjects (ez-review-create--git forge "log" "--reverse" "--format=- %s"
                                         (format "%s/%s..HEAD" ez-review-remote base))))
    (if (and subjects (> (length (split-string subjects "\n" t)) 1)) subjects "")))

(defun ez-review-create--parse-labels (s)
  (split-string (or s "") "[, ]+" t))

(defun ez-review-create--url-number (url)
  "The trailing item number of URL, or nil."
  (when (and url (string-match "/\\([0-9]+\\)/?\\'" url))
    (string-to-number (match-string 1 url))))

(defun ez-review-create--finish (forge what fields)
  "Create the item from FIELDS and open it."
  (message "Creating…")
  (ez-review-forge-create
   forge what fields
   (lambda (result)
     (if (not (and (stringp result) (string-match-p "\\`https?://" result)))
         (message "ez-review: %s" (or result "creation failed"))
       (message "Created %s" result)
       (when-let* ((n (ez-review-create--url-number result)))
         (ez-review-view forge what n))))))

(defun ez-review-create--push-if-needed (forge branch then)
  "Make sure BRANCH is on the remote, asking before pushing; then call THEN."
  (let ((ahead (ez-review-create--git forge "rev-list" "--count" "@{u}..HEAD")))
    (if (and ahead (equal ahead "0"))
        (funcall then)
      (if (not (y-or-n-p (format "Branch `%s' is not fully pushed to %s; push it now? "
                                 branch ez-review-remote)))
          (user-error "Push the branch first, then create the %s" (ez-review-forge-noun forge))
        (message "Pushing %s…" branch)
        (ez-review-process-run
         "git" (list "push" "--set-upstream" ez-review-remote branch)
         (lambda (code _out err)
           (if (eql code 0)
               (funcall then)
             (message "ez-review: push failed: %s" err)))
         :dir (ez-review-forge-dir forge))))))

;;;###autoload
(defun ez-review-create-pr (&optional forge)
  "Open a PR (GitHub) or MR (GitLab) from the current branch of FORGE's repo."
  (interactive)
  (let* ((forge (or forge (ez-review-forge-current)))
         (branch (or (ez-review-create--git forge "rev-parse" "--abbrev-ref" "HEAD")
                     (user-error "Cannot read the current branch")))
         (base (ez-review-create--default-base forge))
         (noun (ez-review-forge-noun forge)))
    (when (member branch (list base "HEAD"))
      (user-error "Check out a feature branch first (on `%s' now)" branch))
    (ez-review-compose
     (format "new %s from %s" noun branch)
     (format "Title: %s\nBase: %s\nDraft: no\nLabels: \n\n%s"
             (or (ez-review-create--git forge "log" "-1" "--format=%s") branch)
             base
             (or (ez-review-create--template forge)
                 (ez-review-create--body-from-commits forge base)))
     (lambda (text)
       (pcase-let* ((`(,headers . ,body) (ez-review-compose-parse text))
                    (title (cdr (assoc "Title" headers)))
                    (base (or (cdr (assoc "Base" headers)) base))
                    (draft (string-match-p "\\`\\(yes\\|y\\|true\\)\\'" (downcase (or (cdr (assoc "Draft" headers)) "")))))
         (when (or (null title) (string-empty-p title)) (user-error "A title is required"))
         (ez-review-create--push-if-needed
          forge branch
          (lambda ()
            (when (ez-review-actions--confirm
                   (format "Create %s%s \"%s\" (%s → %s) in %s/%s? " (if draft "draft " "") noun title branch base
                           (ez-review-forge-host forge) (ez-review-forge-path forge)))
              (ez-review-create--finish
               forge 'pr
               (list :title title :body body :base base :head branch :draft draft
                     :labels (ez-review-create--parse-labels (cdr (assoc "Labels" headers))))))))))
     :header (format "%s %s → %s —" noun branch base))))

;;;###autoload
(defun ez-review-create-issue (&optional forge)
  "Open a new issue in FORGE's repository."
  (interactive)
  (let ((forge (or forge (ez-review-forge-current))))
    (ez-review-compose
     "new issue" "Title: \nLabels: \n\n"
     (lambda (text)
       (pcase-let* ((`(,headers . ,body) (ez-review-compose-parse text))
                    (title (cdr (assoc "Title" headers))))
         (when (or (null title) (string-empty-p title)) (user-error "A title is required"))
         (when (ez-review-actions--confirm
                (format "Create issue \"%s\" in %s/%s? " title
                        (ez-review-forge-host forge) (ez-review-forge-path forge)))
           (ez-review-create--finish
            forge 'issue
            (list :title title :body body
                  :labels (ez-review-create--parse-labels (cdr (assoc "Labels" headers))))))))
     :header "New issue —")))

(provide 'ez-review-create)
;;; ez-review-create.el ends here
