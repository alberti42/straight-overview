EMACS ?= emacs

.PHONY: test lint compile

test:
	$(EMACS) --batch -Q -L . -l test/straight-overview-tests.el \
	  -f ert-run-tests-batch-and-exit

# checkdoc exits 0 even when it warns, so any warning line fails the target.
# The verb check is on in Emacs 29 and 30 and off in later versions; it is
# turned on here so that every version runs the same checks.
lint:
	$(EMACS) --batch -Q --eval '(with-temp-buffer (insert-file-contents "straight-overview.el") (emacs-lisp-mode) (check-parens) (message "check-parens: OK"))'
	@out=$$($(EMACS) --batch -Q --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag t) (checkdoc-file "straight-overview.el"))' 2>&1); \
	  echo "$$out"; \
	  ! echo "$$out" | grep -q '^straight-overview\.el:'
	$(EMACS) --batch -Q --eval '(progn (require (quote check-declare)) (when (check-declare-file "straight-overview.el") (kill-emacs 1)) (message "check-declare: OK"))'

# Byte-compiles a copy without straight.el or Magit on the `load-path',
# warnings as errors, so no stale .elc is left next to the source.
compile:
	@dir=$$(mktemp -d); cp straight-overview.el "$$dir/"; \
	  $(EMACS) --batch -Q -L "$$dir" --eval '(setq byte-compile-error-on-warn t)' \
	    -f batch-byte-compile "$$dir/straight-overview.el"; \
	  status=$$?; rm -rf "$$dir"; \
	  if [ $$status -eq 0 ]; then echo "compile: OK"; fi; exit $$status
