;;; my-editing-multiple-cursors.el --- Multiple cursors (evil-multiedit + evil-mc)  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Two tools, two jobs (the Doom setup):
;;
;;   evil-multiedit   "edit every occurrence of this thing": highlights matches
;;                    (iedit) and everything you type happens at all of them.
;;                    Fast, no real cursors.
;;   evil-mc          real, independent cursors anywhere; each one runs every
;;                    command you run (motions, operators, macros, ...).
;;
;; evil-multiedit (normal and visual state)
;;   M-d        normal: select the symbol at point; again: next occurrence
;;              visual: use the selection, then the next occurrence
;;   M-D        the same, going backwards
;;   R          visual: select ALL occurrences of the selection
;;   C-M-d      bring back the last selection (also after leaving)
;;   In the multiedit state:
;;   M-d / C-n  next occurrence       M-D / C-p  previous occurrence
;;   RET        skip (toggle) the occurrence at point; with a region, restrict
;;              the matches to that region
;;   i a c s .. edit as usual; ESC leaves.
;;
;; evil-mc (normal and visual state), prefix `gz'
;;   gzd / gzD  cursor on the symbol at point + jump to the next / previous match
;;   gzs / gzS  skip this match, go to the next / previous
;;   gzj / gzk  add a cursor and move one line down / up
;;   gzz        add a cursor right here (a "set point" cursor)
;;   gzm        cursors on ALL matches
;;   gzI / gzA  visual: a cursor at the start / end of every selected line
;;   gzp / gzr  pause / resume the extra cursors (move the real one freely)
;;   gzu        remove the last added cursor
;;   gzq        remove all cursors (ESC in normal state does this too)
;;
;; evil-collection also binds `gz' (go to the REPL: ielm, python shell, ...) in
;; many modes, which would beat the prefix there; that jump is moved to `gZ' in
;; keys/my-keys-evil.el.
;;
;; evil-mc's own default prefix is `gr', which this config uses for the LSP
;; actions (grn rename, gra code action, ...), so its keymap is emptied below
;; before the package loads and everything is bound under `gz' instead.

(declare-function general-define-key "general")
(declare-function which-key-add-key-based-replacements "which-key")

(use-package evil-multiedit
  :after evil
  :commands (evil-multiedit-match-all evil-multiedit-restore
             evil-multiedit-match-symbol-and-next evil-multiedit-match-symbol-and-prev
             evil-multiedit-match-and-next evil-multiedit-match-and-prev)
  :init
  (general-define-key :states 'normal
                      "M-d" #'evil-multiedit-match-symbol-and-next
                      "M-D" #'evil-multiedit-match-symbol-and-prev)
  (general-define-key :states 'visual
                      "R"   #'evil-multiedit-match-all
                      "M-d" #'evil-multiedit-match-and-next
                      "M-D" #'evil-multiedit-match-and-prev)
  (general-define-key :states '(normal visual)
                      "C-M-d" #'evil-multiedit-restore)
  :config
  ;; Inside an active multiedit.
  (general-define-key :keymaps '(evil-multiedit-state-map evil-multiedit-insert-state-map)
                      "M-d" #'evil-multiedit-next
                      "M-D" #'evil-multiedit-prev
                      "C-n" #'evil-multiedit-next
                      "C-p" #'evil-multiedit-prev)
  (general-define-key :keymaps 'evil-multiedit-state-map
                      "RET" #'evil-multiedit-toggle-or-restrict-region))

;; Must exist before evil-mc loads, so its `defvar' keeps our empty map and the
;; default `gr' prefix is never installed.
(defvar evil-mc-key-map (make-sparse-keymap))

(use-package evil-mc
  :after evil
  :commands (evil-mc-make-cursor-here evil-mc-make-all-cursors
             evil-mc-make-and-goto-next-match evil-mc-make-and-goto-prev-match
             evil-mc-skip-and-goto-next-match evil-mc-skip-and-goto-prev-match
             evil-mc-make-cursor-move-next-line evil-mc-make-cursor-move-prev-line
             evil-mc-make-cursor-in-visual-selection-beg
             evil-mc-make-cursor-in-visual-selection-end
             evil-mc-pause-cursors evil-mc-resume-cursors
             evil-mc-undo-last-added-cursor evil-mc-undo-all-cursors)
  :init
  (general-define-key :states '(normal visual) :prefix "gz"
                      "d" #'evil-mc-make-and-goto-next-match
                      "D" #'evil-mc-make-and-goto-prev-match
                      "s" #'evil-mc-skip-and-goto-next-match
                      "S" #'evil-mc-skip-and-goto-prev-match
                      "j" #'evil-mc-make-cursor-move-next-line
                      "k" #'evil-mc-make-cursor-move-prev-line
                      "z" #'evil-mc-make-cursor-here
                      "m" #'evil-mc-make-all-cursors
                      "p" #'evil-mc-pause-cursors
                      "r" #'evil-mc-resume-cursors
                      "u" #'evil-mc-undo-last-added-cursor
                      "q" #'evil-mc-undo-all-cursors)
  (general-define-key :states 'visual :prefix "gz"
                      "I" #'evil-mc-make-cursor-in-visual-selection-beg
                      "A" #'evil-mc-make-cursor-in-visual-selection-end)
  (with-eval-after-load 'which-key
    (which-key-add-key-based-replacements "gz" "multiple cursors"))
  :config
  ;; Cursors only work in buffers where the mode is on; turn it on everywhere
  ;; the first time any command above is used (this autoload brings us here).
  (global-evil-mc-mode 1))

(provide 'my-editing-multiple-cursors)
