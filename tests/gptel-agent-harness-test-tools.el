;;; gptel-agent-harness-test-tools.el --- Tools module tests -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: Kiro-cli:claude-opus-4-8, gptel-agent-harness:deepseek-v4-flash
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
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
;; ERT tests for the tools module (gptel-agent-harness-tools): the
;; enhanced glob/grep overrides, the Question tool, and the PlanExit
;; tool.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Tool Override Tests (gptel-agent-harness-tools)

(ert-deftest gptel-agent-harness-test-tools-enable-disable-idempotent ()
  "Test tools enable/disable: overrides, restores, and idempotency."
  (let ((orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep))
        (orig-bash (symbol-function 'gptel-agent--execute-bash)))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          ;; After enable, glob/grep/bash should NOT be the originals
          (should-not (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should-not (eq (symbol-function 'gptel-agent--grep) orig-grep))
          (should-not (eq (symbol-function 'gptel-agent--execute-bash) orig-bash))
          ;; The harness overrides are installed as advice
          (should (advice-member-p #'gptel-agent-harness-tools--glob
                                  'gptel-agent--glob))
          (should (advice-member-p #'gptel-agent-harness-tools--grep
                                  'gptel-agent--grep))
          (should (advice-member-p #'gptel-agent-harness-tools--execute-bash
                                  'gptel-agent--execute-bash))
          ;; Second enable is a no-op: advice-add does not double-install,
          ;; so a single disable still fully restores the originals.
          (gptel-agent-harness-tools-enable)
          ;; Disable should restore
          (gptel-agent-harness-tools-disable)
          (should (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should (eq (symbol-function 'gptel-agent--grep) orig-grep))
          (should (eq (symbol-function 'gptel-agent--execute-bash) orig-bash))
          (should-not (advice-member-p #'gptel-agent-harness-tools--glob
                                      'gptel-agent--glob))
          (should-not (advice-member-p #'gptel-agent-harness-tools--grep
                                      'gptel-agent--grep))
          (should-not (advice-member-p #'gptel-agent-harness-tools--execute-bash
                                      'gptel-agent--execute-bash)))
      ;; Safety restore
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep)
      (fset 'gptel-agent--execute-bash orig-bash))))

;;;; Question Tool Tests

(ert-deftest gptel-agent-harness-test-question-ask-one-single-select ()
  "Test single-select question via `completing-read'."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _) (car choices))))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Pick one:" ["alpha" "beta" "gamma"] nil t)))
      (should (equal result '("alpha"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-multi-select ()
  "Test multi-select question via `completing-read-multiple'."
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (_prompt choices &rest _)
               (list (nth 0 choices) (nth 1 choices)))))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Pick many:" ["alpha" "beta" "gamma"] t t)))
      (should (equal result '("alpha" "beta"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-free-text ()
  "Test free-text fallback when no options provided."
  (cl-letf (((symbol-function 'read-string)
             (lambda (_prompt &rest _) "my custom answer")))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "What do you think?" nil nil nil)))
      (should (equal result '("my custom answer"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-custom-option ()
  "Test selecting the custom free-text option triggers `read-string'."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _)
               ;; Simulate user selecting the custom option (last item)
               (car (last choices))))
            ((symbol-function 'read-string)
             (lambda (_prompt &rest _) "typed answer")))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Choose:" ["opt1" "opt2"] nil t)))
      (should (equal result '("typed answer"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-no-custom ()
  "Test that custom=nil does not append the free-text option."
  (let ((offered-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq offered-choices choices)
                 (car choices))))
      (gptel-agent-harness-tools--ask-one
       "Choose:" ["opt1" "opt2"] nil nil)
      (should (equal offered-choices '("opt1" "opt2")))
      (should-not (member gptel-agent-harness-tools--custom-option
                          offered-choices)))))

(ert-deftest gptel-agent-harness-test-question-ask-questions-multiple ()
  "Test processing multiple questions returns formatted output."
  (let ((call-count 0))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (cl-incf call-count)
                 (car choices)))
              ((symbol-function 'read-string)
               (lambda (_prompt &rest _) "free text")))
      (let* ((questions (vector
                         (list :question "Q1?" :options ["a" "b"])
                         (list :question "Q2?")))  ; no options → free text
             (result (gptel-agent-harness-tools--ask-questions questions)))
        (should (string-match-p "\"Q1\\?\" = \"a\"" result))
        (should (string-match-p "\"Q2\\?\" = \"free text\"" result))))))

(ert-deftest gptel-agent-harness-test-question-custom-json-false ()
  "Test that :custom :json-false disables the custom option."
  (let ((offered-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq offered-choices choices)
                 (car choices))))
      (let* ((questions (vector
                         (list :question "Pick:" :options ["x" "y"]
                               :custom :json-false)))
             (result (gptel-agent-harness-tools--ask-questions questions)))
        (should (string-match-p "\"Pick:\" = \"x\"" result))
        (should-not (member gptel-agent-harness-tools--custom-option
                            offered-choices))))))

(ert-deftest gptel-agent-harness-test-question-ask-questions-list-input ()
  "Test `--ask-questions' accepts a plain list of question plists."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _) (car choices))))
    (let ((result (gptel-agent-harness-tools--ask-questions
                   (list (list :question "L1?" :options ["a" "b"])
                         (list :question "L2?" :options ["c"])))))
      (should (string-match-p "\"L1\\?\" = \"a\"" result))
      (should (string-match-p "\"L2\\?\" = \"c\"" result)))))

(ert-deftest gptel-agent-harness-test-question-register-unregister ()
  "Test Question tool registration and unregistration."
  (let ((gptel-agent-harness-tools--question-tool nil)
        (gptel--known-tools nil))
    ;; Register
    (gptel-agent-harness-tools--register-question)
    (should gptel-agent-harness-tools--question-tool)
    (should (assoc "gptel-agent" gptel--known-tools #'equal))
    ;; Unregister
    (gptel-agent-harness-tools--unregister-question)
    (should-not gptel-agent-harness-tools--question-tool)))

;;;; PlanExit Tool Tests

(ert-deftest gptel-agent-harness-test-plan-exit-noop-in-build-mode ()
  "`PlanExit' is a no-op outside plan mode: no approval, no mode change."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--mode 'build)
      (setq-local gptel-agent-harness--pending-prompts nil)
      (cl-letf (((symbol-function 'gptel-agent-harness-tools--plan-exit-approved-p)
                 (lambda (&rest _) (error "Should not prompt outside plan mode"))))
        (let ((result (gptel-agent-harness-tools--plan-exit)))
          (should (string-match-p "no effect" result))
          (should (eq gptel-agent-harness--mode 'build))
          (should (null gptel-agent-harness--pending-prompts)))))))

(ert-deftest gptel-agent-harness-test-plan-exit-approve-switches-to-build ()
  "Approving `PlanExit' switches to build mode and queues build-switch + execute-plan prompts."
  (gptel-agent-harness-test--with-temp-dir proj-dir
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--project-dir proj-dir)
        (setq-local gptel-agent-harness--mode 'plan)
        (setq-local gptel-agent-harness--plan-file
                    (expand-file-name "PLAN.md" proj-dir))
        (setq-local gptel-agent-harness--pending-prompts nil)
        (cl-letf (((symbol-function 'gptel-agent-harness-tools--plan-exit-approved-p)
                   (lambda (&rest _) t)))
          (let ((result (gptel-agent-harness-tools--plan-exit)))
            (should (string-match-p "approved" result))
            ;; Result instructs the agent to proceed, not to wait.
            (should (string-match-p "proceed" result))
            (should-not (string-match-p "Wait for further" result))
            (should (eq gptel-agent-harness--mode 'build))
            ;; Two queued user prompts: build-switch first, execute-plan second.
            (should (= 2 (length gptel-agent-harness--pending-prompts)))
            ;; The execute-plan message is last and names the plan file.
            (let ((last (car (last gptel-agent-harness--pending-prompts))))
              (should (string-match-p "Execute the plan" last))
              (should (string-match-p "PLAN.md" last)))))))))

(ert-deftest gptel-agent-harness-test-plan-exit-reject-stays-in-plan ()
  "Rejecting `PlanExit' leaves the buffer in plan mode with nothing queued."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--mode 'plan)
      (setq-local gptel-agent-harness--pending-prompts nil)
      (cl-letf (((symbol-function 'gptel-agent-harness-tools--plan-exit-approved-p)
                 (lambda (&rest _) nil)))
        (let ((result (gptel-agent-harness-tools--plan-exit)))
          (should (string-match-p "Remain in plan mode" result))
          (should (eq gptel-agent-harness--mode 'plan))
          (should (null gptel-agent-harness--pending-prompts)))))))

(ert-deftest gptel-agent-harness-test-plan-exit-approved-p-batch ()
  "`--plan-exit-approved-p' uses `yes-or-no-p' in batch mode."
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
    (should (gptel-agent-harness-tools--plan-exit-approved-p "Approve?")))
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
    (should-not (gptel-agent-harness-tools--plan-exit-approved-p "Approve?"))))

(ert-deftest gptel-agent-harness-test-plan-exit-approved-p-interactive ()
  "`--plan-exit-approved-p' uses `read-multiple-choice' interactively."
  (let ((noninteractive nil))
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (_prompt _choices) (cons ?y "yes"))))
      (should (gptel-agent-harness-tools--plan-exit-approved-p "Approve?")))
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (_prompt _choices) (cons ?n "no"))))
      (should-not (gptel-agent-harness-tools--plan-exit-approved-p "Approve?")))))

(ert-deftest gptel-agent-harness-test-plan-exit-register-unregister ()
  "Test PlanExit tool registration and unregistration."
  (let ((gptel-agent-harness-tools--plan-exit-tool nil)
        (gptel--known-tools nil))
    ;; Register
    (gptel-agent-harness-tools--register-plan-exit)
    (should gptel-agent-harness-tools--plan-exit-tool)
    (should (assoc "gptel-agent" gptel--known-tools #'equal))
    ;; Unregister
    (gptel-agent-harness-tools--unregister-plan-exit)
    (should-not gptel-agent-harness-tools--plan-exit-tool)))

;;;; Glob Tool Tests

(ert-deftest gptel-agent-harness-test-glob-error-cases ()
  "Test glob signals errors for empty pattern and non-readable path."
  (should-error (gptel-agent-harness-tools--glob "")
                :type 'error)
  (should-error (gptel-agent-harness-tools--glob "*.txt" "/nonexistent/path/xyz")
                :type 'error))

(ert-deftest gptel-agent-harness-test-glob-respects-gitignore ()
  "Test glob respects .gitignore patterns."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name ".gitignore" temp-dir)
        (insert "ignored.txt\n"))
      (with-temp-file (expand-file-name "tracked.txt" temp-dir)
        (insert "tracked"))
      (with-temp-file (expand-file-name "ignored.txt" temp-dir)
        (insert "ignored"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      (let ((result (gptel-agent-harness-tools--glob "*.txt" temp-dir)))
        (should (string-match-p "tracked\\.txt" result))
        (should-not (string-match-p "ignored\\.txt" result))))))

(ert-deftest gptel-agent-harness-test-glob-git-path-needs-no-tree ()
  "Inside a git repo, glob works even when `tree' is not installed.

The git strategy never invokes `tree', so requiring it up front made the
tool unusable on machines without it."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (with-temp-file (expand-file-name "hit.txt" temp-dir) (insert "x"))
      (cl-letf* ((orig-find (symbol-function 'executable-find))
                 ((symbol-function 'executable-find)
                  (lambda (cmd &rest args)
                    (unless (equal cmd "tree")
                      (apply orig-find cmd args)))))
        (should-not (executable-find "tree"))
        (let ((result (gptel-agent-harness-tools--glob "*.txt" temp-dir)))
          (should (string-match-p "hit\\.txt" result))))
      ;; Outside git, `tree' is still required and its absence is reported.
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
        (should-error (gptel-agent-harness-tools--glob "*.txt" temp-dir)
                      :type 'error)))))

(ert-deftest gptel-agent-harness-test-glob-defaults-to-current-directory ()
  "Test glob defaults to the current directory when PATH is nil."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (with-temp-file (expand-file-name "hit.txt" temp-dir) (insert "x"))
      (with-temp-file (expand-file-name "miss.log" temp-dir) (insert "x"))
      (let ((result (gptel-agent-harness-tools--glob "*.txt")))
        (should (string-match-p "hit\\.txt" result))
        (should-not (string-match-p "miss\\.log" result))))))

;;;; Grep Tool Tests

(ert-deftest gptel-agent-harness-test-grep-nonexistent-path-errors ()
  "Test grep with non-readable path signals an error."
  (should-error (gptel-agent-harness-tools--grep "pattern" "/nonexistent/xyz")
                :type 'error))

(ert-deftest gptel-agent-harness-test-grep-in-git-repo ()
  "Test grep finds matches using git-grep in a git repo."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "foo.txt" temp-dir)
        (insert "line one\nfoo bar baz\nline three\n"))
      (with-temp-file (expand-file-name "bar.txt" temp-dir)
        (insert "nothing here\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Search for "foo" in the whole directory
      (let ((result (gptel-agent-harness-tools--grep "foo" temp-dir)))
        (should (string-match-p "foo bar baz" result))
        (should-not (string-match-p "nothing here" result)))
      ;; Search in a specific file
      (let ((result (gptel-agent-harness-tools--grep
                     "line" (expand-file-name "foo.txt" temp-dir))))
        (should (string-match-p "line one" result))
        (should (string-match-p "line three" result))))))

(ert-deftest gptel-agent-harness-test-grep-with-glob-filter ()
  "Test grep respects the glob filter parameter."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "match.el" temp-dir)
        (insert "target-pattern-here\n"))
      (with-temp-file (expand-file-name "match.txt" temp-dir)
        (insert "target-pattern-here\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Search with glob restricting to .el files only
      (let ((result (gptel-agent-harness-tools--grep
                     "target-pattern" temp-dir "*.el")))
        (should (string-match-p "match\\.el" result))
        (should-not (string-match-p "match\\.txt" result))))))

(ert-deftest gptel-agent-harness-test-grep-dash-pattern ()
  "Test grep handles patterns starting with a dash via -e flag."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "test.txt" temp-dir)
        (insert "normal line\n--flag-like-pattern\nanother line\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Pattern starting with dash should not be misinterpreted as a flag
      (let ((result (gptel-agent-harness-tools--grep
                     "--flag-like" (expand-file-name "test.txt" temp-dir))))
        (should (string-match-p "flag-like-pattern" result))))))

(ert-deftest gptel-agent-harness-test-grep-fallback-rg ()
  "Outside git, grep falls back to ripgrep when available."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (with-temp-file (expand-file-name "file.txt" temp-dir)
        (insert "alpha beta\n"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd &optional _remote)
                   (pcase cmd
                     ("git" nil)
                     ("rg" t)
                     ("grep" t))))
                ((symbol-function 'process-file)
                 (lambda (_program &optional _infile _destination _display &rest _args)
                   (insert "file.txt:1:alpha beta\n")
                   0)))
        (let ((result (gptel-agent-harness-tools--grep "alpha" temp-dir)))
          (should (string-match-p "alpha beta" result)))))))

(ert-deftest gptel-agent-harness-test-grep-fallback-plain-grep ()
  "Outside git, grep falls back to plain grep when ripgrep is missing."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (with-temp-file (expand-file-name "file.txt" temp-dir)
        (insert "alpha beta\n"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd &optional _remote)
                   (pcase cmd
                     ("git" nil)
                     ("rg" nil)
                     ("grep" t))))
                ((symbol-function 'process-file)
                 (lambda (_program &optional _infile _destination _display &rest _args)
                   (insert "file.txt:1:alpha beta\n")
                   0)))
        (let ((result (gptel-agent-harness-tools--grep "alpha" temp-dir)))
          (should (string-match-p "alpha beta" result)))))))

(ert-deftest gptel-agent-harness-test-grep-no-tool-available ()
  "Outside git with no rg/grep available, grep signals an error."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (should-error (gptel-agent-harness-tools--grep "alpha" temp-dir)
                    :type 'error))))

;;;; Bash Tool Tests (gptel-agent-harness-tools--execute-bash / --truncate-bash)

(defun gptel-agent-harness-test--run-bash (command &optional timeout)
  "Run COMMAND via the harness Bash tool synchronously; return its output.

Drives the asynchronous `gptel-agent-harness-tools--execute-bash' to
completion by pumping the event loop until the callback fires, waiting
at most TIMEOUT seconds (default 30).  Signals an error on timeout."
  (let ((result nil)
        (done nil)
        (deadline (+ (float-time) (or timeout 30))))
    (gptel-agent-harness-tools--execute-bash
     (lambda (out) (setq result out done t))
     command)
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless done
      (error "Bash test timed out waiting for callback"))
    result))

;;; Pure truncation helper

(ert-deftest gptel-agent-harness-test-bash-truncate-short-unchanged ()
  "Output within the char budget is returned unchanged."
  (let ((gptel-agent-harness-bash-max-output-chars 1000)
        (gptel-agent-harness-bash-tail-lines 50))
    (should (equal (gptel-agent-harness-tools--truncate-bash "hello\nworld")
                   "hello\nworld"))
    ;; Exactly at the budget is still unchanged.
    (let ((text (make-string 1000 ?x)))
      (should (equal (gptel-agent-harness-tools--truncate-bash text) text)))))

(ert-deftest gptel-agent-harness-test-bash-truncate-head-tail ()
  "Oversized output keeps the head, a truncation notice, and the tail."
  (let* ((gptel-agent-harness-bash-max-output-chars 200)
         (gptel-agent-harness-bash-tail-lines 3)
         ;; 100 numbered lines, well over the 200-char budget.
         (lines (cl-loop for i from 1 to 100
                         collect (format "line-%03d-padding-padding" i)))
         (text (string-join lines "\n"))
         (out (gptel-agent-harness-tools--truncate-bash text)))
    ;; A truncation notice is inserted.
    (should (string-match-p "truncated: output exceeded 200 chars" out))
    ;; The head is preserved (first line present).
    (should (string-match-p "line-001" out))
    ;; The last 3 lines are preserved as the tail.
    (should (string-match-p "line-098" out))
    (should (string-match-p "line-099" out))
    (should (string-match-p "line-100" out))
    ;; A line from the discarded middle is gone.
    (should-not (string-match-p "line-050" out))))

;;; Async execution — success and failure

(ert-deftest gptel-agent-harness-test-bash-success-appends-exit-code ()
  "A successful command returns its output with `Exit code: 0' appended."
  (let ((out (gptel-agent-harness-test--run-bash "echo hello")))
    (should (equal out "hello\nExit code: 0"))))

(ert-deftest gptel-agent-harness-test-bash-empty-output-success ()
  "A successful command with no output returns just the exit-code line."
  (let ((out (gptel-agent-harness-test--run-bash "true")))
    (should (equal out "Exit code: 0"))))

(ert-deftest gptel-agent-harness-test-bash-failure-reports-exit-code ()
  "A failing command reports the non-zero exit code and its output."
  (let ((out (gptel-agent-harness-test--run-bash "echo oops >&2; exit 7")))
    (should (string-match-p "Command failed with exit code 7" out))
    (should (string-match-p "oops" out))
    (should (string-match-p "Exit code: 7" out))))

(ert-deftest gptel-agent-harness-test-bash-merges-stderr ()
  "Both stdout and stderr are captured (process merges them via the buffer)."
  (let ((out (gptel-agent-harness-test--run-bash
              "echo to-out; echo to-err >&2")))
    (should (string-match-p "to-out" out))
    (should (string-match-p "to-err" out))))

;;; Async execution — truncation applies to real output

(ert-deftest gptel-agent-harness-test-bash-truncates-large-output ()
  "Oversized command output is truncated, with the exit code preserved."
  (let ((gptel-agent-harness-bash-max-output-chars 500)
        (gptel-agent-harness-bash-tail-lines 5))
    (let ((out (gptel-agent-harness-test--run-bash
                "for i in $(seq 1 500); do echo padded-line-$i; done")))
      (should (string-match-p "truncated: output exceeded 500 chars" out))
      ;; Exit-code marker still present despite truncation.
      (should (string-match-p "Exit code: 0" out))
      ;; The final line survives in the tail.
      (should (string-match-p "padded-line-500" out)))))

;;; Async execution — timeouts

(ert-deftest gptel-agent-harness-test-bash-silence-timeout ()
  "A command that produces no output past the silence window is killed."
  (let ((gptel-agent-harness-bash-timeout-silence 1)
        (gptel-agent-harness-bash-timeout-max nil)
        (gptel-agent-harness-bash-poll-interval 0.05)
        (gptel-agent-harness-bash-kill-grace 1))
    (let ((out (gptel-agent-harness-test--run-bash "sleep 30" 15)))
      (should (string-match-p "timed out" out))
      (should (string-match-p "no output for 1s" out)))))

(ert-deftest gptel-agent-harness-test-bash-max-timeout ()
  "A command exceeding the max runtime is killed even while producing output."
  (let ((gptel-agent-harness-bash-timeout-silence nil)
        (gptel-agent-harness-bash-timeout-max 1)
        (gptel-agent-harness-bash-poll-interval 0.05)
        (gptel-agent-harness-bash-kill-grace 1))
    (let ((out (gptel-agent-harness-test--run-bash
                ;; Keeps emitting output so only the max timeout can fire.
                "while true; do echo tick; sleep 0.2; done" 15)))
      (should (string-match-p "timed out" out))
      (should (string-match-p "exceeded the 1s maximum" out)))))

(ert-deftest gptel-agent-harness-test-bash-no-timeout-when-disabled ()
  "With both timeouts disabled, a quick command completes normally."
  (let ((gptel-agent-harness-bash-timeout-silence nil)
        (gptel-agent-harness-bash-timeout-max nil))
    (let ((out (gptel-agent-harness-test--run-bash "echo ok")))
      (should (equal out "ok\nExit code: 0")))))

(ert-deftest gptel-agent-harness-test-bash-silence-timeout-is-prompt ()
  "The silence timeout fires promptly via continuous polling.
It must not wait on a fixed multi-second interval: with a 1s window
and sub-second polling, a silent command is reported well under 3s of
wall-clock time."
  (let ((gptel-agent-harness-bash-timeout-silence 1)
        (gptel-agent-harness-bash-timeout-max nil)
        (gptel-agent-harness-bash-poll-interval 0.05)
        (gptel-agent-harness-bash-kill-grace 1))
    (let* ((t0 (float-time))
           (out (gptel-agent-harness-test--run-bash "sleep 30" 10))
           (elapsed (- (float-time) t0)))
      (should (string-match-p "no output for 1s" out))
      ;; 1s window + a little slack for graceful-kill/poll; the old
      ;; single-shot 5s timer would blow past this.
      (should (< elapsed 3.0)))))

(ert-deftest gptel-agent-harness-test-bash-empty-timeout-no-leading-blank ()
  "A silent (no-output) timeout returns just the error, no leading blanks.
This matches the Python harness `_timeout_message', which omits the
`\\n\\n' separator when there is no output."
  (let ((gptel-agent-harness-bash-timeout-silence 1)
        (gptel-agent-harness-bash-timeout-max nil)
        (gptel-agent-harness-bash-poll-interval 0.05)
        (gptel-agent-harness-bash-kill-grace 1))
    (let ((out (gptel-agent-harness-test--run-bash "sleep 30" 10)))
      (should (equal out "Error: Bash command timed out (no output for 1s)."))
      (should-not (string-prefix-p "\n" out)))))

(provide 'gptel-agent-harness-test-tools)

;; Local Variables:
;; package-lint-main-file: "tests/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-tools.el ends here
