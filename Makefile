EMACS ?= emacs

.PHONY: test lint

test:
	$(EMACS) --batch -Q -L . -l test/straight-overview-tests.el \
	  -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) --batch -Q --eval '(with-temp-buffer (insert-file-contents "straight-overview.el") (emacs-lisp-mode) (check-parens) (message "check-parens: OK"))'
	$(EMACS) --batch -Q --eval '(progn (require (quote checkdoc)) (checkdoc-file "straight-overview.el"))'
