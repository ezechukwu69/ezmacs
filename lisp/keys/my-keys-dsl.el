;;; my-keys-dsl.el --- One declaration for the Evil key, the Emacs key and the leader key  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;; Commentary:
;;
;; A command's keys used to live in three places: a `general-define-key' for
;; Evil, a table for the Emacs-mode twin, and a `my/leader' entry.  `my/bind'
;; declares them together, once, next to the code that owns the command:
;;
;;   (my/bind
;;     (xref-find-definitions  :g "d"  :doc "definition")
;;     (my/eldoc-show          :evil "K"  :emacs "C-c g k"  :doc "docs at point")
;;     (my/select-font         :leader "t F"  :doc "font")
;;     (flymake-goto-next-error :evil "] e" :evil-map flymake-mode-map :after flymake
;;                              :emacs "C-c g e"))
;;
;; Each entry is (COMMAND OPTION VALUE ...).  Options:
;;
;;   :g KEY...       the "g" family: Evil `g KEY', Emacs mode `C-c g KEY'
;;   :evil KEY...    Evil key(s) only            :emacs KEY...   Emacs-mode key(s) only
;;   :both KEY...    the same key in both worlds (global, plus the Evil states)
;;   :leader KEY...  under SPC (and M-SPC with Evil off)
;;   :states LIST    Evil states for the Evil keys; default (normal)
;;   :evil-map MAP   bind the Evil keys in MAP (a keymap variable) instead of globally
;;   :emacs-map MAP  bind the Emacs keys in MAP instead of globally
;;   :after FEATURE  wait for FEATURE before touching MAP (needed for lazily loaded maps)
;;   :doc TEXT       what it does: the leader menu label, and `M-x my/bind-describe'
;;
;; KEY is a `kbd' string ("gd", "] e", "C-c g d").  Leading option pairs before
;; the first entry are defaults for every entry after them:
;;
;;   (my/bind :states (normal visual)
;;     (eglot-rename :g "r n") ...)
;;
;; Two entries claiming the same key (in the same Evil state or keymap) are
;; reported with a warning at load time instead of one silently winning.
;; `M-x my/bind-describe' lists everything declared, Evil key next to Emacs key.

(require 'cl-lib)
(require 'subr-x)
(require 'evil)

(declare-function my/leader "my-keys-leader")
(declare-function evil-define-key* "evil-core")
(declare-function evil-global-set-key "evil-core")

(defvar my/bind--table nil
  "Declarations, newest first, as plists.
Keys: :command :evil :emacs :leader :states :doc :source.")

(defvar my/bind--claims (make-hash-table :test #'equal)
  "(WORLD MAP KEY) -> the command that first claimed that key.")

(defconst my/bind--options
  '(:g :evil :emacs :both :leader :states :evil-map :emacs-map :after :doc)
  "Options an entry may carry.")

;;;; Parsing

(defun my/bind--keys (x)
  "X (nil, a key string or a list of them) as a list of key strings."
  (cond ((null x) nil) ((stringp x) (list x)) ((listp x) x)
        (t (error "Bad key list %S in my/bind" x))))

(defun my/bind--check-key (key)
  "Signal a clear error if KEY is not a valid `kbd' string."
  (unless (and (stringp key) (condition-case nil (and (key-parse key) t) (error nil)))
    (error "Not a valid key in my/bind: %S" key))
  key)

(defun my/bind--split (spec)
  "SPEC as (DEFAULTS . ENTRIES): leading option pairs, then the entry lists."
  (let (defaults)
    (while (keywordp (car spec))
      (push (pop spec) defaults)
      (push (pop spec) defaults))
    (cons (nreverse defaults) spec)))

(defun my/bind--plan (command props)
  "Expand PROPS for COMMAND into a plist (:evil :emacs :leader :states ...)."
  (let ((rest props))
    (while rest
      (unless (memq (car rest) my/bind--options)
        (error "Unknown my/bind option %S for `%s' (known: %S)" (car rest) command my/bind--options))
      (setq rest (cddr rest))))
  (let* ((g (my/bind--keys (plist-get props :g)))
         (both (my/bind--keys (plist-get props :both)))
         (evil (append (mapcar (lambda (k) (concat "g " k)) g)
                       (my/bind--keys (plist-get props :evil)) both))
         (emacs (append (mapcar (lambda (k) (concat "C-c g " k)) g)
                        (my/bind--keys (plist-get props :emacs)) both)))
    (mapc #'my/bind--check-key evil)
    (mapc #'my/bind--check-key emacs)
    (list :command command :evil evil :emacs emacs
          :leader (my/bind--keys (plist-get props :leader))
          :states (let ((s (plist-get props :states))) (cond ((null s) '(normal)) ((listp s) s) (t (list s))))
          :evil-map (plist-get props :evil-map) :emacs-map (plist-get props :emacs-map)
          :after (plist-get props :after) :doc (plist-get props :doc))))

;;;; Claims: catch two declarations on one key

(defun my/bind--claim (world map key command)
  "Record that COMMAND owns KEY in WORLD and MAP; warn if another command already did."
  (let* ((id (list world map (key-description (kbd key))))
         (old (gethash id my/bind--claims)))
    (when (and old (not (eq old command)))
      (display-warning
       'my-bind
       (format "%s key %s%s is claimed by both `%s' and `%s'; the later one wins"
               world (key-description (kbd key)) (if map (format " in %s" map) "") old command)
       :warning))
    (puthash id command my/bind--claims)))

;;;; Binding

(defun my/bind--evil (states map key command)
  "Bind KEY to COMMAND in the Evil STATES, in keymap variable MAP or globally."
  (dolist (s states) (my/bind--claim (format "Evil %s" s) map key command))
  (if map
      (evil-define-key* states (symbol-value map) (kbd key) command)
    (dolist (s states) (evil-global-set-key s (kbd key) command))))

(defun my/bind--emacs (map key command)
  "Bind KEY to COMMAND for Emacs mode, in keymap variable MAP or globally."
  (my/bind--claim "Emacs" map key command)
  (keymap-set (if map (symbol-value map) global-map) key command))

(defun my/bind--leader (key command doc)
  "Put COMMAND on the leader menu at KEY with label DOC."
  (my/bind--claim "leader" nil key command)
  (my/leader key (list command :wk (or doc (symbol-name command)))))

(defun my/bind--run (plan)
  "Make the bindings of PLAN, waiting for its :after feature where it needs a keymap."
  (let* ((command (plist-get plan :command))
         (states (plist-get plan :states))
         (evil-map (plist-get plan :evil-map))
         (emacs-map (plist-get plan :emacs-map))
         (after (plist-get plan :after))
         (evil-keys (plist-get plan :evil))
         (emacs-keys (plist-get plan :emacs))
         (defer (lambda (map thunk)
                  (if (and map after) (eval-after-load after thunk) (funcall thunk)))))
    (funcall defer evil-map
             (lambda () (dolist (k evil-keys) (my/bind--evil states evil-map k command))))
    (funcall defer emacs-map
             (lambda () (dolist (k emacs-keys) (my/bind--emacs emacs-map k command))))
    (dolist (k (plist-get plan :leader))
      (my/bind--leader k command (plist-get plan :doc)))))

(defun my/bind--register (plan source)
  "Add PLAN (from file SOURCE) to the table, replacing an older entry of the same command."
  (let ((entry (append plan (list :source (and source (file-name-nondirectory source))))))
    (setq my/bind--table
          (cons entry (cl-remove-if (lambda (e) (and (eq (plist-get e :command) (plist-get plan :command))
                                                     (equal (plist-get e :source) (plist-get entry :source))
                                                     (equal (plist-get e :evil) (plist-get plan :evil))
                                                     (equal (plist-get e :emacs) (plist-get plan :emacs))))
                                    my/bind--table)))))

(defun my/bind--apply (spec source)
  "Declare the keys in SPEC (see the commentary); SOURCE is the file it comes from."
  (pcase-let ((`(,defaults . ,entries) (my/bind--split spec)))
    (dolist (entry entries)
      (unless (and (consp entry) (symbolp (car entry)))
        (error "A my/bind entry must look like (COMMAND :option value ...), got %S" entry))
      (let ((plan (my/bind--plan (car entry) (append (cdr entry) defaults))))
        (my/bind--register plan source)
        (my/bind--run plan)))))

(defmacro my/bind (&rest spec)
  "Declare keys for commands, once, for Evil and Emacs mode (see my-keys-dsl.el).
SPEC is leading default options followed by entries (COMMAND :option value ...);
nothing in it is evaluated."
  (declare (indent 0))
  `(my/bind--apply ',spec load-file-name))

;;;; Looking things up

(defun my/bind-emacs-keys (command)
  "The Emacs-mode keys declared for COMMAND, as strings."
  (cl-loop for e in my/bind--table
           when (eq (plist-get e :command) command)
           append (mapcar (lambda (k) (key-description (kbd k))) (plist-get e :emacs))))

(defun my/bind-evil-keys (command)
  "The Evil keys declared for COMMAND, as strings."
  (cl-loop for e in my/bind--table
           when (eq (plist-get e :command) command)
           append (mapcar (lambda (k) (key-description (kbd k))) (plist-get e :evil))))

(defun my/bind--rows ()
  "One row (COMMAND EVIL EMACS LEADER DOC SOURCE) per declaration, sorted by Evil key."
  (let ((fmt (lambda (keys) (mapconcat (lambda (k) (key-description (kbd k))) keys " "))))
    (sort (mapcar (lambda (e)
                    (list (symbol-name (plist-get e :command))
                          (funcall fmt (plist-get e :evil))
                          (funcall fmt (plist-get e :emacs))
                          (mapconcat (lambda (k) (concat "SPC " k)) (plist-get e :leader) " ")
                          (or (plist-get e :doc) "")
                          (or (plist-get e :source) "")))
                  (reverse my/bind--table))
          (lambda (a b) (string< (concat (nth 1 a) (nth 0 a)) (concat (nth 1 b) (nth 0 b)))))))

;;;###autoload
(defun my/bind-describe ()
  "Show every key declared with `my/bind': Evil key next to its Emacs-mode key."
  (interactive)
  (let ((rows (my/bind--rows)))
    (with-current-buffer (get-buffer-create "*Key bindings*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Evil / Emacs-mode keys declared with my/bind\n" 'face 'bold)
                (propertize "(Emacs-mode: leader menu is M-SPC; the g family is C-c g)\n\n" 'face 'shadow))
        (insert (format "%-14s %-16s %-22s %-14s %s\n" "Evil" "Emacs mode" "Command" "Leader" "What"))
        (insert (make-string 96 ?─) "\n")
        (dolist (r rows)
          (insert (format "%-14s %-16s %-22s %-14s %s  %s\n"
                          (nth 1 r) (nth 2 r) (nth 0 r) (nth 3 r) (nth 4 r)
                          (propertize (nth 5 r) 'face 'shadow))))
        (goto-char (point-min)))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(provide 'my-keys-dsl)
;;; my-keys-dsl.el ends here
