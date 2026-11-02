;;; my-tools-media.el --- YouTube and music in Emacs: empv (mpv)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; empv drives an external mpv through its IPC socket; mpv uses yt-dlp to play
;; YouTube.  Emacs only shows the UI (search results, playlist, controls), so
;; install the two programs first:   brew install mpv yt-dlp
;;
;; Audio only by default (music / podcasts); `SPC y _' toggles video, which
;; opens in mpv's own window.  Search (`SPC y y') goes through an Invidious API
;; (`empv-invidious-instance'): empv's bundled local server `ivjs' when deno is
;; installed (nothing third-party, no public instance to go down), otherwise a
;; public instance.  Public instances come and go and most have the API turned
;; off; the one below was the only of nine that answered when it was chosen.
;; The first ivjs start downloads YouTube.js and can outlast empv's 6s wait:
;; if it says "Failed to start ivjs", just run the command again.
;; Playing a URL you already have (`SPC y p', `SPC y u' on a link) needs only
;; mpv + yt-dlp.  All external programs: see INSTALL.md.

(declare-function my/leader "my-keys-leader")

(use-package empv
  :commands (empv-youtube empv-youtube-last-results empv-youtube-playlist
             empv-play empv-play-audio empv-play-video empv-play-file
             empv-play-thing-at-point empv-play-or-enqueue empv-enqueue
             empv-toggle empv-toggle-video empv-pause empv-resume empv-exit
             empv-playlist-next empv-playlist-prev empv-playlist-select
             empv-playlist-shuffle empv-playlist-clear
             empv-volume-up empv-volume-down empv-display-current empv-play-radio)
  :custom
  (empv-invidious-instance (if (executable-find "deno")
                               'ivjs
                             "https://yt.chocolatemoo53.com/api/v1"))
  (empv-volume-step 5)
  (empv-reset-playback-speed-on-quit t)
  :config
  ;; Fail with an actionable message instead of a cryptic process error.
  (define-advice empv-start (:before (&rest _) my/check-binaries)
    (dolist (bin (list empv-mpv-binary empv-ytdl-binary))
      (unless (executable-find bin)
        (user-error "The empv package needs `%s' on PATH (brew install mpv yt-dlp)" bin)))))

;; The results list has its own single-key commands: Emacs state, like the
;; other read-mostly buffers in this config.
(with-eval-after-load 'evil
  (evil-set-initial-state 'empv-youtube-results-mode 'emacs))

(my/leader
  "y"  '(:ignore t :wk "media")
  "yy" '(empv-youtube :wk "search YouTube")
  "yY" '(empv-youtube-last-results :wk "last results")
  "yP" '(empv-youtube-playlist :wk "YouTube playlist")
  "yp" '(empv-play :wk "play URL/file")
  "yv" '(empv-play-video :wk "play video")
  "ya" '(empv-play-audio :wk "play audio")
  "yu" '(empv-play-thing-at-point :wk "play link at point")
  "ye" '(empv-enqueue :wk "enqueue")
  "yt" '(empv-toggle :wk "pause/resume")
  "y_" '(empv-toggle-video :wk "toggle video")
  "yn" '(empv-playlist-next :wk "next")
  "yN" '(empv-playlist-prev :wk "previous")
  "yl" '(empv-playlist-select :wk "playlist")
  "ys" '(empv-playlist-shuffle :wk "shuffle")
  "y+" '(empv-volume-up :wk "volume up")
  "y-" '(empv-volume-down :wk "volume down")
  "yi" '(empv-display-current :wk "now playing")
  "yr" '(empv-play-radio :wk "radio")
  "yq" '(empv-exit :wk "quit player"))

(provide 'my-tools-media)
