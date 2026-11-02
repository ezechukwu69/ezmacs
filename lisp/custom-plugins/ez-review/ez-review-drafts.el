;;; ez-review-drafts.el --- Pending review comments, kept on disk -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Inline comments you have written but not sent yet.  They are stored one
;; file per PR/MR under `ez-review-data-directory', so closing Emacs (or a
;; crash) never loses a review in progress.  Sending them is done by the
;; backend's `ez-review-forge-submit-review'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ez-review-process)
(require 'ez-review-forge)

(defcustom ez-review-data-directory (locate-user-emacs-file "ez-review/")
  "Where pending review comments are stored."
  :type 'directory
  :group 'ez-review)

(defun ez-review-drafts--file (forge number)
  "File holding the drafts for PR NUMBER of FORGE."
  (expand-file-name
   (format "%s!%s!%d.eld" (ez-review-forge-host forge)
           (replace-regexp-in-string "/" "!" (ez-review-forge-path forge)) number)
   (expand-file-name "drafts" ez-review-data-directory)))

(defun ez-review-drafts--to-plist (d)
  (list :path (ez-review-draft-path d) :old-path (ez-review-draft-old-path d)
        :side (ez-review-draft-side d) :line (ez-review-draft-line d)
        :old-line (ez-review-draft-old-line d) :new-line (ez-review-draft-new-line d)
        :start-line (ez-review-draft-start-line d) :body (ez-review-draft-body d)))

(defun ez-review-drafts--from-plist (p)
  (make-ez-review-draft
   :path (plist-get p :path) :old-path (plist-get p :old-path)
   :side (plist-get p :side) :line (plist-get p :line)
   :old-line (plist-get p :old-line) :new-line (plist-get p :new-line)
   :start-line (plist-get p :start-line) :body (plist-get p :body)))

(defun ez-review-drafts-load (forge number)
  "The pending drafts of PR NUMBER, a list of `ez-review-draft'."
  (let ((file (ez-review-drafts--file forge number)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (mapcar #'ez-review-drafts--from-plist (read (current-buffer))))
        (error nil)))))

(defun ez-review-drafts-save (forge number drafts)
  "Write DRAFTS for PR NUMBER; delete the file when there are none."
  (let ((file (ez-review-drafts--file forge number)))
    (if (null drafts)
        (when (file-exists-p file) (delete-file file))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (let ((print-length nil) (print-level nil))
          (prin1 (mapcar #'ez-review-drafts--to-plist drafts) (current-buffer)))))))

(defun ez-review-drafts-count (forge number)
  "How many drafts are pending for PR NUMBER."
  (length (ez-review-drafts-load forge number)))

(defun ez-review-drafts-add (forge number draft)
  "Append DRAFT to the stored drafts of PR NUMBER."
  (ez-review-drafts-save forge number (append (ez-review-drafts-load forge number) (list draft))))

(defun ez-review-drafts-remove (forge number draft)
  "Remove the draft equal to DRAFT from the stored drafts of PR NUMBER."
  (ez-review-drafts-save forge number
                         (cl-remove draft (ez-review-drafts-load forge number) :test #'equal)))

(defun ez-review-drafts-replace (forge number old new)
  "Replace draft OLD with NEW in the stored drafts of PR NUMBER."
  (ez-review-drafts-save forge number
                         (mapcar (lambda (d) (if (equal d old) new d))
                                 (ez-review-drafts-load forge number))))

(provide 'ez-review-drafts)
;;; ez-review-drafts.el ends here
