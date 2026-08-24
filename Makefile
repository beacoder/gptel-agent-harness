EMACS ?= emacs

# A space-separated list of required package names
DEPS = gptel-agent

# All harness source files (compile, lint, and checkdoc targets)
FILES = gptel-agent-harness.el \
	gptel-agent-harness-agent.el \
	gptel-agent-harness-fsm.el \
	gptel-agent-harness-commands.el \
	gptel-agent-harness-session.el \
	gptel-agent-harness-tools.el \
	test/gptel-agent-harness-test.el \
	test/gptel-agent-harness-test-utils.el \
	test/gptel-agent-harness-test-tokens.el \
	test/gptel-agent-harness-test-context.el \
	test/gptel-agent-harness-test-supervision.el \
	test/gptel-agent-harness-test-session.el \
	test/gptel-agent-harness-test-compaction.el \
	test/gptel-agent-harness-test-plan.el \
	test/gptel-agent-harness-test-commands.el \
	test/gptel-agent-harness-test-agent.el \
	test/gptel-agent-harness-test-tools.el \
	test/gptel-agent-harness-test-fsm.el \

INIT_PACKAGES="(progn \
  (require 'package) \
  (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) \
  (package-initialize) \
  (dolist (pkg '(PACKAGES)) \
    (unless (package-installed-p pkg) \
      (unless (assoc pkg package-archive-contents) \
	(package-refresh-contents)) \
      (package-install pkg))) \
  )"

all: compile package-lint test clean-elc

package-lint:
	${EMACS} -Q --eval $(subst PACKAGES,package-lint,${INIT_PACKAGES}) -L . -L test -batch -f package-lint-batch-and-exit $(FILES)

checkdoc:
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L test -batch -l checkdoc --eval '(progn (setq checkdoc-package-keywords-flag nil) (dolist (f command-line-args-left) (checkdoc-file f)))' $(FILES)

compile: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L test -batch -f batch-byte-compile $(FILES)

test: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L test -batch -l gptel-agent-harness-test --eval '(ert-run-tests-batch-and-exit "^gptel-agent-harness")'

clean-elc:
	rm -f *.elc test/*.elc

.PHONY:	all compile test checkdoc clean-elc package-lint
