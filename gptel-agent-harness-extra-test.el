;;; gptel-agent-harness-extra-test.el --- Extra tests for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: gptel-agent-harness:deepseek-v4-flash
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
;; ERT tests for gptel-agent-harness modules that do not belong in
;; gptel-agent-harness-test.el: the enhanced tools
;; (gptel-agent-harness-tools.el: glob/grep/Question).  More module
;; tests can be added here as the suite grows.
;;
;; Split from gptel-agent-harness-test.el (which keeps the core
;; supervision/context/session/commands tests) so the suite stays
;; manageable.  Load both files and run with:
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -l gptel-agent-harness-test \
;;     -l gptel-agent-harness-extra-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness")'
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness)
(require 'gptel-agent-harness-fsm)

;; Ensure gptel backends are available (needed for `gptel' function in
;; commands tests when running in batch mode).
(require 'gptel-openai nil t)

;;;; Stubs — minimal gptel API surface needed for testing
;; These provide a minimal gptel API surface when the real packages
;; are not available.  We use `fset' to avoid package-lint prefix errors.
;; Idempotent: if the real package is loaded first, nothing is stubbed.

(eval-and-compile
  (unless (fboundp 'gptel-make-tool)
    (fset 'gptel-make-tool (lambda (&rest args) (apply #'list args))))
  (unless (fboundp 'gptel-tool-name)
    (fset 'gptel-tool-name (lambda (tool) (plist-get tool :name))))
  (unless (boundp 'gptel-tools) (defvar gptel-tools nil))
  (unless (boundp 'gptel-model) (defvar gptel-model nil))
  (unless (boundp 'gptel-mode) (defvar gptel-mode nil))
  (unless (boundp 'gptel-post-response-functions) (defvar gptel-post-response-functions nil))
  (unless (boundp 'gptel--backend-name) (defvar gptel--backend-name nil))
  (unless (boundp 'gptel-system-prompt) (defvar gptel-system-prompt nil))
  (unless (boundp 'gptel-temperature) (defvar gptel-temperature nil))
  (unless (boundp 'gptel-max-tokens) (defvar gptel-max-tokens nil))
  (unless (boundp 'gptel--num-messages-to-send) (defvar gptel--num-messages-to-send nil))
  (unless (boundp 'gptel--token-usage) (defvar gptel--token-usage nil))
  (unless (fboundp 'markdown-mode)
    (fset 'markdown-mode (lambda () (setq major-mode 'markdown-mode))))
  (unless (fboundp 'gptel-mode)
    (fset 'gptel-mode
          (lambda (&optional arg)
            (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t))))))
  (unless (fboundp 'gptel-fsm-info)
    (fset 'gptel-fsm-info (lambda (fsm) (plist-get fsm :info))))
  (unless (fboundp 'gptel--fsm-next)
    (fset 'gptel--fsm-next (lambda (_machine) nil)))
  (unless (fboundp 'gptel-make-fsm)
    (fset 'gptel-make-fsm
          (lambda (&rest args) (list :info (plist-get args :info)))))
  (unless (fboundp 'gptel-fsm-handlers)
    (fset 'gptel-fsm-handlers (lambda (fsm) (plist-get fsm :handlers))))
  (with-no-warnings
    (unless (boundp 'gptel-send--handlers)
      (setq gptel-send--handlers 'gptel-send--handlers)))
  (unless (fboundp 'gptel--inject-prompt)
    (fset 'gptel--inject-prompt
          (lambda (_backend data msg)
            (let* ((msgs (or (plist-get data :messages) []))
                   (new-msgs (vconcat msgs (vector msg))))
              (plist-put data :messages new-msgs)))))
  (unless (fboundp 'gptel-abort)
    (fset 'gptel-abort (lambda (&optional _buf) nil)))
  (unless (fboundp 'gptel-agent-compact)
    (fset 'gptel-agent-compact
          (lambda (_prompt callback)
            (when (functionp callback)
              (funcall callback)))))
  (unless (fboundp 'gptel-send)
    (fset 'gptel-send (lambda () nil)))
  (unless (fboundp 'gptel--fsm-transition)
    (fset 'gptel--fsm-transition (lambda (_machine &optional _new-state) nil)))
  ;; Stubs for gptel-agent-harness-commands module
  (unless (boundp 'gptel-agent-mode) (defvar gptel-agent-mode nil))
  (unless (fboundp 'gptel)
    (fset 'gptel (lambda (buf-name &optional _prompt _initial _interactive)
                   (get-buffer-create buf-name))))
  (unless (fboundp 'gptel-get-tool)
    (fset 'gptel-get-tool (lambda (name) (intern (format "gptel-agent-harness-test--tool-%s" name)))))
  (unless (fboundp 'gptel-agent-update)
    (fset 'gptel-agent-update (lambda () nil)))
  (unless (fboundp 'gptel--update-status)
    (fset 'gptel--update-status (lambda (&rest _) nil))))

;;;; Test Helpers

(defmacro gptel-agent-harness-test--with-buffer (buf-var &rest body)
  "Create a temp buffer bound to BUF-VAR, execute BODY, kill buffer."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,buf-var (generate-new-buffer " *harness-test*")))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,buf-var)
         (kill-buffer ,buf-var)))))

(defmacro gptel-agent-harness-test--with-temp-dir (dir-var &rest body)
  "Create a temp directory bound to DIR-VAR, execute BODY, clean up."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,dir-var (make-temp-file "gptel-sess-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,dir-var)
         (delete-directory ,dir-var t)))))

(defun gptel-agent-harness-test--make-fsm (buf &rest plist)
  "Create a fake FSM with BUF.
PLIST keys `:tools' and `:handlers' are placed in both the FSM info
and the `:data' payload so all functions (token estimation, agentic-p,
top-level-p) see them."
  (let* ((tools (plist-get plist :tools))
         (handlers (plist-get plist :handlers))
         (info-plist `(:buffer ,buf :data ,(copy-sequence plist))))
    (when tools (plist-put info-plist :tools tools))
    (gptel-make-fsm :info info-plist
                    :handlers (or handlers 'test-handlers))))

(defun gptel-agent-harness-test--setup-gptel-buffer (buf &optional proj-dir)
  "Set up BUF as a gptel buffer with optional PROJ-DIR."
  (with-current-buffer buf
    (setq-local gptel-mode t)
    (when proj-dir
      (setq-local gptel-agent-harness--project-dir proj-dir))))

;;;; Tool Override Tests (gptel-agent-harness-tools)

(ert-deftest gptel-agent-harness-test-tools-enable-disable-idempotent ()
  "Test tools enable/disable: overrides, restores, and idempotency."
  (let ((orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep)))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          ;; After enable, glob/grep should NOT be the originals
          (should-not (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should-not (eq (symbol-function 'gptel-agent--grep) orig-grep))
          ;; The harness overrides are installed as advice
          (should (advice-member-p #'gptel-agent-harness-tools--glob
                                  'gptel-agent--glob))
          (should (advice-member-p #'gptel-agent-harness-tools--grep
                                  'gptel-agent--grep))
          ;; Second enable is a no-op: advice-add does not double-install,
          ;; so a single disable still fully restores the originals.
          (gptel-agent-harness-tools-enable)
          ;; Disable should restore
          (gptel-agent-harness-tools-disable)
          (should (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should (eq (symbol-function 'gptel-agent--grep) orig-grep))
          (should-not (advice-member-p #'gptel-agent-harness-tools--glob
                                      'gptel-agent--glob))
          (should-not (advice-member-p #'gptel-agent-harness-tools--grep
                                      'gptel-agent--grep)))
      ;; Safety restore
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep))))

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

;;;; FSM Hardening Module Tests

(ert-deftest gptel-agent-harness-test-fsm-map-tool-args-normalizes ()
  "`--map-tool-args-advice' normalizes non-plist args to nil."
  (let ((orig-called nil))
    (cl-letf (((symbol-function 'gptel--map-tool-args)
               (lambda (&rest _) (setq orig-called t) '(1 2))))
      ;; Non-plist args → nil, orig-fn not called
      (should-not (gptel-agent-harness-fsm--map-tool-args-advice
                   (lambda (&rest _) (setq orig-called t) '(1 2))
                   'tool-spec "oops"))
      (should-not orig-called)
      ;; Plist args → orig-fn called
      (setq orig-called nil)
      (should (equal (gptel-agent-harness-fsm--map-tool-args-advice
                      (lambda (&rest _) (setq orig-called t) '(1 2))
                      'tool-spec '(:a 1))
                     '(1 2)))
      (should orig-called))))

(ert-deftest gptel-agent-harness-test-fsm-tool-use-error-results ()
  "`--handle-tool-use-advice' fails pending tool calls on handler error."
  (gptel-agent-harness-test--with-buffer buf
    (cl-letf (((symbol-function 'gptel--process-tool-call)
               (lambda (_fsm _tool-spec tool-call result)
                 (plist-put tool-call :result result))))
      (let* ((tool-1 (gptel-make-tool :name "tool1"
                                      :function (lambda (&rest _) "x")
                                      :description "d"))
             (tool-2 (gptel-make-tool :name "tool2"
                                      :function (lambda (&rest _) "x")
                                      :description "d"))
             (tool-call-1 (list :name "tool1" :args '(:a 1)))
             (tool-call-2 (list :name "tool2" :args '(:b 2)))
             (info (list :buffer buf
                         :tools (vector tool-1 tool-2)
                         :tool-use (list tool-call-1 tool-call-2)))
             (fsm (gptel-make-fsm :info info)))
        ;; orig-fn throws → both pending calls get error-string results
        (gptel-agent-harness-fsm--handle-tool-use-advice
         (lambda (_fsm) (error "Boom")) fsm)
        (should (string-match-p "Error: tool call failed"
                                (plist-get tool-call-1 :result)))
        (should (string-match-p "Error: tool call failed"
                                (plist-get tool-call-2 :result))))
      ;; Success path leaves results untouched
      (let* ((tool-1 (gptel-make-tool :name "tool1"
                                      :function (lambda (&rest _) "x")
                                      :description "d"))
             (tool-call (list :name "tool1" :args '(:a 1)))
             (info (list :buffer buf
                         :tools (vector tool-1)
                         :tool-use (list tool-call)))
             (fsm (gptel-make-fsm :info info)))
        (gptel-agent-harness-fsm--handle-tool-use-advice
         (lambda (_fsm) (plist-put tool-call :result "ok")) fsm)
        (should (equal (plist-get tool-call :result) "ok"))))))

(ert-deftest gptel-agent-harness-test-fsm-tool-result-advice ()
  "`--handle-tool-result-advice' transitions once and stores a string :error."
  (gptel-agent-harness-test--with-buffer buf
    (let ((transitions 0))
      (cl-letf (((symbol-function 'gptel--fsm-transition)
                 (lambda (&rest _) (cl-incf transitions))))
        ;; orig-fn throws → :error is a string, transition called once
        (let* ((info (list :buffer buf))
               (fsm (gptel-make-fsm :info info)))
          (gptel-agent-harness-fsm--handle-tool-result-advice
           (lambda (_fsm) (error "Boom")) fsm)
          (should (stringp (plist-get info :error)))
          (should (string-match-p "Error: Boom" (plist-get info :error)))
          (should (= transitions 1)))
        ;; Success path → no double transition
        (let* ((info (list :buffer buf))
               (fsm (gptel-make-fsm :info info)))
          (gptel-agent-harness-fsm--handle-tool-result-advice
           (lambda (_fsm) nil) fsm)
          (should (= transitions 1)))))))

(ert-deftest gptel-agent-harness-test-fsm-process-tool-call-idempotent ()
  "`--process-tool-call-advice' skips calls that already have a `:result'.
This prevents a failed-then-resolved async tool call from being
processed twice (which would double-decrement the pending count and
fire a spurious FSM transition)."
  (let ((orig-calls 0))
    (let ((orig-fn (lambda (&rest _) (cl-incf orig-calls))))
      ;; Already has a result → orig-fn NOT called (duplicate is a no-op)
      (let ((tool-call (list :name "tool1" :result "done")))
        (gptel-agent-harness-fsm--process-tool-call-advice
         orig-fn 'fsm 'tool-spec tool-call "late-result")
        (should (= orig-calls 0))
        ;; The original result is preserved, not overwritten
        (should (equal (plist-get tool-call :result) "done")))
      ;; Empty-string result still counts as "already processed"
      (let ((tool-call (list :name "tool2" :result "")))
        (gptel-agent-harness-fsm--process-tool-call-advice
         orig-fn 'fsm 'tool-spec tool-call "late")
        (should (= orig-calls 0)))
      ;; No result yet → orig-fn IS called (first result wins)
      (let ((tool-call (list :name "tool3")))
        (gptel-agent-harness-fsm--process-tool-call-advice
         orig-fn 'fsm 'tool-spec tool-call "result")
        (should (= orig-calls 1))))))

(ert-deftest gptel-agent-harness-test-fsm-sanitize-tool-results ()
  "`--sanitize-tool-results' guarantees a string `:result' for every call.
A nil result becomes a placeholder string, a non-string result is
printed, and an empty string is left untouched.  This prevents
`gptel--parse-tool-results' + `json-serialize' from emitting an invalid
`{}' tool-message content."
  (let* ((tc-nil (list :name "Bash" :id "call_1"))            ; no :result
         (tc-empty (list :name "Grep" :id "call_2" :result "")) ; legit empty
         (tc-num (list :name "X" :id "call_3" :result 42))    ; non-string
         (tc-str (list :name "Y" :id "call_4" :result "ok"))
         (info (list :tool-use (list tc-nil tc-empty tc-num tc-str)))
         (fsm (gptel-make-fsm :info info)))
    (gptel-agent-harness-fsm--sanitize-tool-results fsm)
    ;; nil → placeholder string
    (should (stringp (plist-get tc-nil :result)))
    (should (string-match-p "no result" (plist-get tc-nil :result)))
    ;; empty string preserved exactly
    (should (equal (plist-get tc-empty :result) ""))
    ;; number coerced to its printed form
    (should (equal (plist-get tc-num :result) "42"))
    ;; existing string untouched
    (should (equal (plist-get tc-str :result) "ok"))
    ;; End-to-end: an OpenAI-style tool message built from the sanitized
    ;; result now json-serializes with a string content, never `{}'.
    (when (fboundp 'json-serialize)
      (let ((json (json-serialize
                   (list :role "tool"
                         :tool_call_id (plist-get tc-nil :id)
                         :content (plist-get tc-nil :result)))))
        (should (string-match-p "\"content\":\"" json))
        (should-not (string-match-p "\"content\":{}" json))))))

(ert-deftest gptel-agent-harness-test-fsm-tool-result-advice-sanitizes ()
  "`--handle-tool-result-advice' sanitizes results before running ORIG-FN.
A nil `:result' must be a string by the time ORIG-FN (which builds the
outgoing message) sees it."
  (gptel-agent-harness-test--with-buffer buf
    (let* ((tc (list :name "Bash" :id "call_1"))  ; nil :result
           (info (list :buffer buf :tool-use (list tc)))
           (fsm (gptel-make-fsm :info info))
           (seen-result :unset))
      (cl-letf (((symbol-function 'gptel--fsm-transition) #'ignore))
        (gptel-agent-harness-fsm--handle-tool-result-advice
         (lambda (_fsm)
           (setq seen-result (plist-get tc :result)))
         fsm))
      (should (stringp seen-result))
      (should (string-match-p "no result" seen-result)))))

(ert-deftest gptel-agent-harness-test-fsm-enable-disable ()
  "`gptel-agent-harness-fsm-enable' adds advice, `-disable' removes it."
  (unwind-protect
      (progn
        (gptel-agent-harness-fsm-enable)
        (should (advice-member-p
                 #'gptel-agent-harness-fsm--map-tool-args-advice
                 'gptel--map-tool-args))
        (should (advice-member-p
                 #'gptel-agent-harness-fsm--handle-tool-use-advice
                 'gptel--handle-tool-use))
        (should (advice-member-p
                 #'gptel-agent-harness-fsm--process-tool-call-advice
                 'gptel--process-tool-call))
        (should (advice-member-p
                 #'gptel-agent-harness-fsm--handle-tool-result-advice
                 'gptel--handle-tool-result))
        (gptel-agent-harness-fsm-disable)
        (should-not (advice-member-p
                     #'gptel-agent-harness-fsm--map-tool-args-advice
                     'gptel--map-tool-args))
        (should-not (advice-member-p
                     #'gptel-agent-harness-fsm--handle-tool-use-advice
                     'gptel--handle-tool-use))
        (should-not (advice-member-p
                     #'gptel-agent-harness-fsm--process-tool-call-advice
                     'gptel--process-tool-call))
        (should-not (advice-member-p
                     #'gptel-agent-harness-fsm--handle-tool-result-advice
                     'gptel--handle-tool-result)))
    (gptel-agent-harness-fsm-disable)))

(provide 'gptel-agent-harness-extra-test)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-extra-test.el ends here
