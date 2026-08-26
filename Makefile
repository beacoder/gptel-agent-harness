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
	gptel-agent-harness-config.el \
	gptel-agent-harness-fsm.el \
	gptel-agent-harness-display.el \
	gptel-agent-harness-supervisor.el \
	gptel-agent-harness-compact.el \
	tests/gptel-agent-harness-test.el \
	tests/gptel-agent-harness-test-utils.el \
	tests/gptel-agent-harness-test-tokens.el \
	tests/gptel-agent-harness-test-context.el \
	tests/gptel-agent-harness-test-supervision.el \
	tests/gptel-agent-harness-test-session.el \
	tests/gptel-agent-harness-test-compaction.el \
	tests/gptel-agent-harness-test-plan.el \
	tests/gptel-agent-harness-test-commands.el \
	tests/gptel-agent-harness-test-agent.el \
	tests/gptel-agent-harness-test-tools.el \
	tests/gptel-agent-harness-test-fsm.el \
	tests/gptel-agent-harness-coverage.el \

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
	${EMACS} -Q --eval $(subst PACKAGES,package-lint,${INIT_PACKAGES}) -L . -L tests -batch -f package-lint-batch-and-exit $(FILES)

checkdoc:
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L tests -batch -l checkdoc --eval '(progn (setq checkdoc-package-keywords-flag nil) (dolist (f command-line-args-left) (checkdoc-file f)))' $(FILES)

compile: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L tests -batch -f batch-byte-compile $(FILES)

test: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L tests -batch -l gptel-agent-harness-test --eval '(ert-run-tests-batch-and-exit "^gptel-agent-harness")'

test-coverage: clean-elc
	${EMACS} -Q --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES}) -L . -L tests -batch \
	  -l gptel-agent-harness-coverage \
	  --eval '(gptel-agent-harness-coverage--start)' \
	  -l gptel-agent-harness-test \
	  --eval '(gptel-agent-harness-coverage--run-with-report "coverage.txt")'

clean-elc:
	rm -f *.elc tests/*.elc

.PHONY:	all compile test test-coverage checkdoc clean-elc package-lint
