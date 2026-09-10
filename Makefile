EMACS ?= emacs
TIMEOUT ?= timeout
TEST_TIMEOUT ?= 60
SMOKE_TIMEOUT ?= 15

.PHONY: test compile check smoke clean

test:
	$(TIMEOUT) -k 5s $(TEST_TIMEOUT)s $(EMACS) --batch -Q -L . -L test -l test/dwindle-tests.el -l test/dwindle-tree-tests.el -l test/dwindle-ownership-tree-tests.el -l test/dwindle-terminal-tests.el -l test/dwindle-evil-tests.el -l test/dwindle-doom-tests.el -l test/dwindle-all-windows-tests.el -l test/dwindle-display-tests.el -l test/dwindle-popup-adoption-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(TIMEOUT) -k 5s $(TEST_TIMEOUT)s $(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile dwindle.el dwindle-resize.el dwindle-doom.el dwindle-tree.el dwindle-terminal.el dwindle-display.el

check: compile test

smoke:
	EMACS="$(EMACS)" TIMEOUT="$(TIMEOUT)" SMOKE_TIMEOUT="$(SMOKE_TIMEOUT)" sh test/run-redisplay-smoke.sh

clean:
	rm -f dwindle.elc dwindle-resize.elc dwindle-doom.elc dwindle-tree.elc dwindle-terminal.elc dwindle-display.elc
