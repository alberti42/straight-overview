EMACS ?= emacs

.PHONY: test lint

test:
	$(EMACS) --batch -Q -L . -l test/straight-overview-tests.el \
	  -f ert-run-tests-batch-and-exit

# checkdoc exits 0 even when it warns, so any warning line fails the target.
lint:
	$(EMACS) --batch -Q --eval '(with-temp-buffer (insert-file-contents "straight-overview.el") (emacs-lisp-mode) (check-parens) (message "check-parens: OK"))'
	@out=$$($(EMACS) --batch -Q --eval '(progn (require (quote checkdoc)) (checkdoc-file "straight-overview.el"))' 2>&1); \
	  echo "$$out"; \
	  ! echo "$$out" | grep -q '^straight-overview\.el:'
