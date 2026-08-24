;;; gptel-agent-harness-test.el --- Entry point for the gptel-agent-harness test suite -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: Kiro-cli:claude-opus-4-8, gptel-agent-harness:deepseek-v4-flash
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "29.1"))
;; Keywords: programming, convenience, ai, agent
;;
;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Entry point for the ERT test suite of gptel-agent-harness.  The
;; suite lives in this directory and is split by topic so each file
;; stays small and focused:
;;
;;   gptel-agent-harness-test-utils.el       shared stubs and helpers
;;   gptel-agent-harness-test-tokens.el      token estimation and calibration
;;   gptel-agent-harness-test-context.el     context ratio and mode-line
;;   gptel-agent-harness-test-supervision.el nudge/transition supervisor
;;   gptel-agent-harness-test-session.el     session persistence and preview
;;   gptel-agent-harness-test-compaction.el  compaction flows
;;   gptel-agent-harness-test-plan.el        build/plan mode
;;   gptel-agent-harness-test-commands.el    commands module
;;   gptel-agent-harness-test-agent.el       agent module
;;   gptel-agent-harness-test-tools.el       enhanced glob/grep/Question/PlanExit
;;   gptel-agent-harness-test-fsm.el         FSM hardening module
;;
;; Load this file (or any single topic file) and run with:
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -L /path/to/gptel-agent-harness/tests \
;;     -l gptel-agent-harness-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness")'
;;
;;; Code:

(require 'gptel-agent-harness-test-utils)
(require 'gptel-agent-harness-test-tokens)
(require 'gptel-agent-harness-test-context)
(require 'gptel-agent-harness-test-supervision)
(require 'gptel-agent-harness-test-session)
(require 'gptel-agent-harness-test-compaction)
(require 'gptel-agent-harness-test-plan)
(require 'gptel-agent-harness-test-commands)
(require 'gptel-agent-harness-test-agent)
(require 'gptel-agent-harness-test-tools)
(require 'gptel-agent-harness-test-fsm)

(provide 'gptel-agent-harness-test)

;; No `package-lint-main-file' here on purpose: this file IS the main
;; file of the test suite, so it must carry the Package-Requires header
;; itself (the topic files point their package-lint-main-file at it).
;;; gptel-agent-harness-test.el ends here
