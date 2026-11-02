;;; my-lang-markdown.el --- Markdown editing and live preview  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-

;; Editing is `markdown-mode' (gfm-mode for .md).  The preview is the
;; `markdown-preview-mode' package: it serves a page that re-renders as you type
;; and is shown beside the source in an xwidget WebKit window (or in your
;; browser when this Emacs has no xwidgets).  It needs a Markdown converter on
;; PATH; the first one found of cmark-gfm, comrak and pandoc is used.
;;   brew install cmark-gfm      (smallest)    or    brew install pandoc

(declare-function my/local-leader "my-keys-leader")
(declare-function xwidget-webkit-browse-url "xwidget")
(defvar markdown-command)

(defconst my/markdown-converters
  '(("cmark-gfm" . "cmark-gfm --unsafe -e table -e strikethrough -e tasklist -e autolink")
    ("comrak"    . "comrak --gfm --unsafe")
    ("pandoc"    . "pandoc -f gfm -t html5"))
  "Converter executables and the command that turns Markdown on stdin into HTML.")

(defun my/markdown-converter ()
  "Command of the first available converter in `my/markdown-converters', or nil."
  (cl-loop for (exe . command) in my/markdown-converters
           when (executable-find exe) return command))

(defun my/markdown-preview-browse (url &rest _)
  "Show URL in a WebKit window beside the current one."
  (let ((display-buffer-overriding-action
         '((display-buffer-in-direction) (direction . right) (window-width . 0.5))))
    (save-selected-window
      (xwidget-webkit-browse-url url t))))

(defun my/markdown-preview-in-emacs-p ()
  (and (display-graphic-p) (featurep 'xwidget-internal)))

(use-package markdown-mode
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . gfm-mode))
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-enable-math t)
  (markdown-asymmetric-header t)
  (markdown-make-gfm-checkboxes-buttons t)
  (markdown-list-item-bullets '("•" "◦" "▪" "▫")) ; org-modern's list bullets
  (markdown-hr-display-char ?─)
  :config
  (when-let* ((command (my/markdown-converter)))
    (setq markdown-command command))
  (my/local-leader :keymaps '(markdown-mode-map gfm-mode-map)
    "p" '(markdown-preview-mode :wk "live preview")
    "t" '(markdown-toggle-markup-hiding :wk "hide markup")
    "u" '(markdown-toggle-url-hiding :wk "hide URLs")))

(defvar-local my/markdown-preview--tick nil
  "Modification tick of the buffer when the preview was last rendered.")

(use-package markdown-preview-mode
  :commands (markdown-preview-mode markdown-preview-open-browser markdown-preview-cleanup)
  :custom
  (markdown-preview-delay-time 0.3)     ; default 2s: seconds of idle before each update
  :config
  ;; With a short delay the timer would run the converter on every pause even
  ;; when nothing changed; only render after an edit (or on the first send).
  (advice-add 'markdown-preview--send-preview :around
              (lambda (orig &rest args)
                (unless (eq my/markdown-preview--tick (buffer-chars-modified-tick))
                  (setq my/markdown-preview--tick (buffer-chars-modified-tick))
                  (apply orig args))))
  ;; The package opens its page with `browse-url'; keep that inside Emacs.
  (advice-add 'markdown-preview--open-browser-preview :around
              (lambda (orig &rest args)
                (if (my/markdown-preview-in-emacs-p)
                    (let ((browse-url-browser-function #'my/markdown-preview-browse))
                      (apply orig args))
                  (apply orig args))))
  ;; Fail with a clear message instead of an empty page.
  (advice-add 'markdown-preview-mode :before
              (lambda (&rest _)
                (unless (or (bound-and-true-p markdown-preview-mode) ; turning it off
                            (my/markdown-converter))
                  (user-error "No Markdown converter found: brew install cmark-gfm (or pandoc)")))))

(provide 'my-lang-markdown)
