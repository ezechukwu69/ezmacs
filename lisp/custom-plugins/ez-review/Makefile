EMACS ?= emacs
ELPA  ?= $(HOME)/.emacs.d/elpa
# Extra -L flags, e.g. LOADPATH="-L /path/to/magit-section -L /path/to/compat"
LOADPATH ?=

SRC = ez-review-process.el \
      ez-review-forge.el \
      ez-review-github.el \
      ez-review-gitlab.el \
      ez-review-ui.el \
      ez-review-compose.el \
      ez-review-drafts.el \
      ez-review-actions.el \
      ez-review-diff.el \
      ez-review-list.el \
      ez-review-view.el \
      ez-review-create.el \
      ez-review-auth.el \
      ez-review-magit.el \
      ez-review.el

.PHONY: all compile test lint clean

all: compile test

compile:
	$(EMACS) -Q --batch -L . $(LOADPATH) \
	  --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $(SRC)

test:
	$(EMACS) -Q --batch -L . $(LOADPATH) -l test/ez-review-test.el \
	  -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q --batch -L . $(LOADPATH) \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  --eval "(require 'package-lint)" -f package-lint-batch-and-exit $(SRC)

clean:
	rm -f *.elc test/*.elc
