;;; my-keys-table.el --- Every Evil / Emacs-mode key, side by side  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; THE place to change a key that has an Evil form and an Emacs-mode form.  One
;; line per command:
;;
;;   (COMMAND               :evil "<evil key>"        :emacs "<emacs key>"        :doc "what")
;;
;; :evil keys apply in the :states of their group (default normal); :emacs keys
;; apply with Evil off (and are plain global keys, so they also work with it on).
;; Either side may hold a list of keys, or be left out.  Other options (see
;; my-keys-dsl.el): :both, :g, :leader, :evil-map + :after for lazily loaded maps.
;;
;; The rule the table follows: Evil's  g<keys>  is Emacs mode's  C-c g <keys>.
;; `M-x my/bind-describe' prints this table as it is live.  SPC leader entries
;; (SPC = M-SPC with Evil off) are in my-keys-leader.el and next to their modules.
;;
;; Not here because they need Evil: gz multiple cursors, surround, text objects.

(require 'my-keys-dsl)

(declare-function which-key-add-key-based-replacements "which-key")

;;;; Go to / look up                  Evil                     Emacs mode
(my/bind
  (xref-find-definitions   :evil "g d"               :emacs "C-c g d"      :doc "definition (also M-.)")
  (eglot-find-declaration  :evil "g D"               :emacs "C-c g D"      :doc "declaration")
  (my/eldoc-show           :evil "K"                 :emacs "C-c g k"      :doc "docs at point"))

;;;; LSP actions (gr, as in Neovim), in normal and visual
(my/bind :states (normal visual)
  (eglot-code-actions        :evil "g r a"           :emacs "C-c g r a"    :doc "code actions")
  (eglot-rename              :evil "g r n"           :emacs "C-c g r n"    :doc "rename")
  (xref-find-references      :evil "g r r"           :emacs "C-c g r r"    :doc "references")
  (eglot-find-implementation :evil "g r i"           :emacs "C-c g r i"    :doc "implementation")
  (eglot-find-typeDefinition :evil "g r t"           :emacs "C-c g r t"    :doc "type definition")
  (my/symbols-buffer         :evil ("g 0" "g O")     :emacs ("C-c g 0" "C-c g O")
                             :doc "symbols of the buffer"))

;;;; Jump with avy
(my/bind :states (normal visual motion)
  (avy-goto-char-timer     :evil "g s"               :emacs "C-c g s"      :doc "avy: a character")
  (avy-goto-line           :evil "g l"               :emacs "C-c g l"      :doc "avy: a line"))

;;;; Errors and hunks
(my/bind
  (flymake-goto-next-error :evil "] e" :after flymake :evil-map flymake-mode-map
                           :emacs "C-c g e"                                :doc "next error")
  (flymake-goto-prev-error :evil "[ e" :after flymake :evil-map flymake-mode-map
                           :emacs "C-c g E"                                :doc "previous error")
  (diff-hl-next-hunk       :evil "] h"               :emacs "C-c g h"      :doc "next hunk")
  (diff-hl-previous-hunk   :evil "[ h"               :emacs "C-c g H"      :doc "previous hunk"))

;;;; The jump list (Evil's own, shared by both modes).  C-o / C-i are not used in
;;;; Emacs mode: they are open-line and TAB.  M-, and C-M-, (xref) also exist.
(my/bind
  (evil-jump-backward      :emacs "C-c o"                                  :doc "back through jumps")
  (evil-jump-forward       :emacs "C-c i"                                  :doc "forward through jumps"))

;;;; Editing: Evil gets these from packages, Emacs mode needs a key
(my/bind
  (comment-dwim            :emacs "C-c g c"                                :doc "comment (Evil: gc)")
  (iedit-mode              :emacs "C-c g m"                                :doc "edit all occurrences (Evil: M-d, R)")
  (evil-numbers/inc-at-pt  :both "C-c +"                                   :doc "increment number")
  (evil-numbers/dec-at-pt  :both "C-c -"                                   :doc "decrement number"))

(with-eval-after-load 'which-key
  (which-key-add-key-based-replacements
    "C-c g"   "go (Evil g-keys)"
    "C-c g r" "LSP actions"))

(provide 'my-keys-table)
