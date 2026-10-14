;;; ez-flutter.el --- Interactive Flutter commands with dape integration -*- lexical-binding: t; -*-

;; Author: Your Name
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1") (dape "0.1"))
;; Keywords: flutter, dart, mobile, development
;; URL: https://github.com/yourusername/ez-flutter

;;; Commentary:

;; This package provides interactive Flutter development commands integrated
;; with dape (Debug Adapter Protocol for Emacs). It includes commands for
;; starting/stopping Flutter apps, hot reload/restart functionality, device
;; management, and automatic hot reload on save.

;;; Code:

(require 'dape)
(require 'project)
(require 'persp-mode nil t)
(require 'browse-url)
(require 'json)
(require 'url-util)
(require 'dart-mode nil t)
(require 'apheleia nil t)

(defvar ez/flutter--sessions (make-hash-table :test 'equal)
  "Dape connections keyed by perspective and project root.")

(defvar ez/flutter--vm-service-uris (make-hash-table :test 'equal)
  "Flutter VM service URIs keyed by perspective and project root.")

(defvar ez/flutter-devtools-hide-options "debugger"
  "DevTools tabs to hide when opening Flutter DevTools.")

(defvar ez/flutter-devtools-theme "dark"
  "Theme to use when opening Flutter DevTools.")

(defvar ez/flutter--devtools-process nil
  "Process for the local Dart DevTools server.")

(defvar ez/flutter--devtools-uri nil
  "Base URI for the local Dart DevTools server.")

(defconst ez/flutter--devtools-buffer-name " *ez-flutter-devtools*"
  "Buffer used to capture local Dart DevTools machine output.")

(defun ez/flutter--project-root ()
  "Return the current project root as an absolute, tilde-free local path.
`default-directory' is often abbreviated (\"~/dev/app/\"); the Flutter debug
adapter does not expand \"~\" and fails with PathNotFoundException."
  (let* ((project (project-current nil))
         (root (when project (project-root project))))
    (file-local-name (expand-file-name (or root default-directory)))))

(declare-function safe-persp-name "persp-mode")
(declare-function get-current-persp "persp-mode")
(declare-function tabspaces--current-tab-name "tabspaces")

(defun ez/flutter--current-perspective-name ()
  "Return the active workspace name (persp-mode or tabspaces), or nil."
  (cond ((featurep 'persp-mode)
         (safe-persp-name (get-current-persp)))
        ((featurep 'tabspaces)
         (tabspaces--current-tab-name))))

(defun ez/flutter--session-key (&optional root)
  "Return the cache key for ROOT in the current perspective."
  (let* ((project-root (or root (ez/flutter--project-root)))
         (perspective (ez/flutter--current-perspective-name)))
    (cons perspective project-root)))

(defun ez/flutter--current-session (&optional root)
  "Return the Flutter debug session for ROOT."
  (gethash (ez/flutter--session-key root) ez/flutter--sessions))

(defun ez/flutter--live-session (&optional root)
  "Return a live Flutter debug session for ROOT.
Clear any cached stale session before returning nil."
  (let ((connection (ez/flutter--current-session root)))
    (if (and (eieio-object-p connection)
             (object-of-class-p connection 'dape-connection)
             (jsonrpc-running-p connection))
        connection
      (when connection
        (ez/flutter--set-current-session nil root))
      nil)))

(defun ez/flutter--set-current-session (connection &optional root)
  "Store CONNECTION for ROOT and return it."
  (let ((key (ez/flutter--session-key root)))
    (if connection
        (puthash key connection ez/flutter--sessions)
      (progn
        (remhash key ez/flutter--sessions)
        (remhash key ez/flutter--vm-service-uris)))
    connection))

(defun ez/flutter--set-vm-service-uri (uri &optional root)
  "Store Flutter VM service URI for ROOT."
  (puthash (ez/flutter--session-key root) uri ez/flutter--vm-service-uris))

(defun ez/flutter--vm-service-uri (&optional root)
  "Return the stored Flutter VM service URI for ROOT."
  (when (ez/flutter--live-session root)
    (gethash (ez/flutter--session-key root) ez/flutter--vm-service-uris)))

(defun ez/flutter--open-devtools-for-uri (devtools-uri vm-service-uri)
  "Open local DEVTOOLS-URI for VM-SERVICE-URI in a browser."
  (let* ((params (url-build-query-string
                  `((ide "Emacs")
                    (uri ,vm-service-uri)
                    (hide ,ez/flutter-devtools-hide-options)
                    (theme ,ez/flutter-devtools-theme))))
         (separator (if (string-match-p "[?]" devtools-uri) "&" "?"))
         (url (concat devtools-uri separator params)))
    (browse-url url)))

(defun ez/flutter--devtools-running-p ()
  "Return non-nil when the local Dart DevTools process is running."
  (and ez/flutter--devtools-process
       (process-live-p ez/flutter--devtools-process)
       ez/flutter--devtools-uri))

(defun ez/flutter--devtools-process-filter (_process output)
  "Parse machine OUTPUT from the local Dart DevTools process."
  (with-current-buffer (get-buffer-create ez/flutter--devtools-buffer-name)
    (goto-char (point-max))
    (insert output)
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (let* ((line-end (1- (point)))
             (line (buffer-substring-no-properties (point-min) line-end)))
        (delete-region (point-min) (point))
        (when (and (not (string-empty-p line))
                   (not ez/flutter--devtools-uri))
          (condition-case nil
              (let* ((json-object-type 'plist)
                     (json-array-type 'list)
                     (payload (json-read-from-string line))
                     (host (plist-get (plist-get payload :params) :host))
                     (port (plist-get (plist-get payload :params) :port)))
                (when (and host port)
                  (setq ez/flutter--devtools-uri
                        (format "http://%s:%s" host port))))
            (json-parse-error nil)))))))

(defun ez/flutter--devtools-process-sentinel (process _event)
  "Reset local DevTools state when PROCESS exits."
  (unless (process-live-p process)
    (setq ez/flutter--devtools-process nil
          ez/flutter--devtools-uri nil)))

(defun ez/flutter--ensure-local-devtools ()
  "Start the local Dart DevTools server when needed."
  (unless (ez/flutter--devtools-running-p)
    (setq ez/flutter--devtools-uri nil)
    (setq ez/flutter--devtools-process
          (make-process
           :name "ez-flutter-devtools"
           :buffer (get-buffer-create ez/flutter--devtools-buffer-name)
           :command '("dart" "devtools" "--machine" "--port" "0")
           :noquery t
           :filter #'ez/flutter--devtools-process-filter
           :sentinel #'ez/flutter--devtools-process-sentinel))))

(defun ez/flutter--with-local-devtools (callback)
  "Run CALLBACK with the local Dart DevTools URI once available."
  (ez/flutter--ensure-local-devtools)
  (if ez/flutter--devtools-uri
      (funcall callback ez/flutter--devtools-uri)
    (run-with-timer 0.1 nil #'ez/flutter--with-local-devtools callback)))

(defun ez/flutter--active-connection ()
  "Return the active Flutter debug connection for the current project."
  (ez/flutter--live-session))

(defun ez/flutter--remember-session (connection)
  "Cache CONNECTION for its project root."
  (when-let* ((root (plist-get (dape--config connection) :cwd)))
    (ez/flutter--set-current-session (dape--root-of connection) root)))

(defvar ez/flutter--last-device (make-hash-table :test 'equal)
  "Last device chosen per project root, offered first in the prompt.")

(defun ez/flutter--devices (root)
  "Return the devices `flutter devices --machine' reports for ROOT.
Each device is a plist with :name :id :targetPlatform :emulator."
  (let ((default-directory root))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (call-process "flutter" nil '(t nil) nil "devices" "--machine")))
        (goto-char (point-min))
        ;; The tool may print progress lines before the JSON array.
        (when (re-search-forward "^\\[" nil t)
          (goto-char (match-beginning 0))
          (ignore-errors
            (seq-filter (lambda (d) (not (eq (plist-get d :isSupported) :false)))
                        (json-parse-string (buffer-substring (point) (point-max))
                                           :object-type 'plist
                                           :array-type 'list))))))))

(defun ez/flutter--pick-device (root &optional force-prompt)
  "Return the device plist to run on, prompting when several are available.
With FORCE-PROMPT always ask.  Return nil when no device is reported, so the
debug adapter falls back to its own default."
  (message "Looking for Flutter devices...")
  (let* ((devices (ez/flutter--devices root))
         (last-id (gethash root ez/flutter--last-device))
         (label (lambda (d)
                  (format "%s  (%s%s)  [%s]"
                          (plist-get d :name)
                          (plist-get d :targetPlatform)
                          (if (eq (plist-get d :emulator) t) ", emulator" "")
                          (plist-get d :id))))
         (choice
          (cond
           ((null devices) nil)
           ((and (null (cdr devices)) (not force-prompt)) (car devices))
           (t
            (let* ((sorted (sort (copy-sequence devices)
                                 (lambda (a b)
                                   (and (equal (plist-get a :id) last-id)
                                        (not (equal (plist-get b :id) last-id))))))
                   (table (mapcar (lambda (d) (cons (funcall label d) d)) sorted))
                   (pick (completing-read
                          "Flutter device: "
                          (lambda (str pred action)
                            (if (eq action 'metadata)
                                '(metadata (display-sort-function . identity))
                              (complete-with-action action table str pred)))
                          nil t)))
              (cdr (assoc pick table)))))))
    (when choice
      (puthash root (plist-get choice :id) ez/flutter--last-device))
    choice))

(defun ez/flutter-start (&optional prompt-device)
  "Run and debug the current project with Flutter.
Prompts for a device when more than one is available; with a prefix argument
PROMPT-DEVICE always prompts.  If a session already exists for this
workspace and project, select it instead."
  (interactive "P")
  (let* ((root (ez/flutter--project-root))
         (existing (ez/flutter--live-session root)))
    (if existing
        (dape-select-session existing)
      (let* ((device (ez/flutter--pick-device root prompt-device))
             (project-name (file-name-nondirectory (directory-file-name root))))
        (dape `(
                modes (dart-mode dart-ts-mode)
                command "flutter"
                command-args ("debug_adapter")
                :type "dart"
                :name ,(if device
                           (format "Flutter %s (%s)" project-name (plist-get device :name))
                         (format "Flutter %s" project-name))
                :args ["-v"]
                ,@(when device `(:toolArgs ["-d" ,(plist-get device :id)]))
                :request "launch"
                :program "lib/main.dart"
                :cwd ,root
                ))))))

(defun ez/flutter-switch-session ()
  "Switch to another running Flutter session, and to its workspace.
Selecting a session makes `dape' commands, hot reload/restart and the REPL
act on it; if its workspace tab exists, that tab is selected too."
  (interactive)
  (let (entries)
    (maphash
     (lambda (key conn)
       (when (and (eieio-object-p conn)
                  (object-of-class-p conn 'dape-connection)
                  (jsonrpc-running-p conn))
         (push (cons (format "%s  —  %s"
                             (or (car key) "no workspace")
                             (abbreviate-file-name (cdr key)))
                     (cons key conn))
               entries)))
     ez/flutter--sessions)
    (unless entries (user-error "No running Flutter sessions"))
    (let* ((pick (if (cdr entries)
                     (completing-read "Flutter session: " (mapcar #'car entries) nil t)
                   (caar entries)))
           (entry (cdr (assoc pick entries)))
           (workspace (car (car entry)))
           (conn (cdr entry)))
      (when (and workspace (fboundp 'tab-bar-select-tab-by-name)
                 (member workspace (mapcar (lambda (tab) (alist-get 'name tab))
                                           (funcall tab-bar-tabs-function))))
        (tab-bar-select-tab-by-name workspace))
      (ignore-errors (dape-select-session conn))
      (message "Flutter session: %s" pick))))

(defun ez/flutter-stop ()
  (interactive)
  (let ((connection (ez/flutter--active-connection)))
    (when connection
      (dape-kill connection)
      (ez/flutter--set-current-session nil))))

(defun ez/flutter-devices ()
  (interactive)
  (let* ((command "flutter emulators | awk '/^Id\s+•/{p=1; next} /^To run an emulator/{p=0} p' | grep -v '^\s*$' | awk '{print $1}'")
         (result (split-string (shell-command-to-string command) "\n" t))
         (picked (completing-read "Pick emulator" result)))
    (shell-command (format "flutter emulators --launch %s" picked))))

(defun ez/send-flutter-command (command)
  "Send a COMMAND to the Flutter application via DAP."
  (let ((connection (ez/flutter--active-connection)))
    (unless connection
      (user-error "No running Flutter debug session for this project"))
    (dape-request connection command nil)))

(defun ez/flutter-reload ()
  "Perform a hot reload of the Flutter application."
  (interactive)
  (ez/send-flutter-command "hotReload"))

(defun ez/flutter-restart ()
  "Restart the Flutter application."
  (interactive)
  (ez/send-flutter-command "hotRestart"))

(defun ez/open-devtools ()
  "Open the flutter devtools."
  (interactive)
  (if-let* ((vm-service-uri (ez/flutter--vm-service-uri)))
      (ez/flutter--with-local-devtools
       (lambda (devtools-uri)
         (ez/flutter--open-devtools-for-uri devtools-uri vm-service-uri)))
    (user-error "No Flutter VM service URI for this perspective session yet")))

(defun ez/reload-on-save ()
  "Run after Apheleia finishes formatting in Dart mode."
  (when (and (or (derived-mode-p 'dart-mode) (derived-mode-p 'dart-ts-mode))
             (ez/flutter--active-connection))
    (ez/flutter-reload)))

(add-hook 'apheleia-post-format-hook #'ez/reload-on-save)

(cl-defmethod dape-handle-event (conn (_event (eql dart.debuggerUris)) body)
  "Store Flutter debugger URIs from BODY for CONN."
  (when-let* ((vm-service-uri (plist-get body :vmServiceUri)))
    (cl-loop for key being the hash-keys of ez/flutter--sessions
             using (hash-values connection)
             when (eq connection conn)
             do (puthash key vm-service-uri ez/flutter--vm-service-uris))))

(cl-defmethod dape-handle-event :after (conn (_event (eql initialized)) _body)
  "Cache initialized Flutter sessions so reload-on-save can find them."
  (ez/flutter--remember-session conn))

(provide 'ez-flutter)

;;; ez-flutter.el ends here
