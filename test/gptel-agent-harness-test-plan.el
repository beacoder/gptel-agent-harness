;;; gptel-agent-harness-test-plan.el --- Build/plan mode tests -*- lexical-binding: t -*-
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
;; ERT tests for build/plan mode: mode toggling and prompt queues,
;; pending-prompt injection (top-level, sub-agent, mid-flight), the
;; mode indicator, `--request-injection-position', and plan-file temp
;; directory selection.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Build/Plan Mode Tests

(ert-deftest gptel-agent-harness-test-mode-switch-queues-prompts ()
  "Switching modes queues the correct prompts for the next request."
  (gptel-agent-harness-test--with-temp-dir proj-dir
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--project-dir proj-dir)
        ;; Default is build mode with an empty queue.
        (should (eq gptel-agent-harness--mode 'build))
        (should (null gptel-agent-harness--pending-prompts))
        ;; Switch to plan → plan.md + plan-mode.md queued.
        (gptel-agent-harness-toggle-mode)
        (should (eq gptel-agent-harness--mode 'plan))
        (should (= 2 (length gptel-agent-harness--pending-prompts)))
        (should (string-match-p "Plan Mode"
                                (car gptel-agent-harness--pending-prompts)))
        (should (string-match-p "Plan mode is active"
                                (nth 1 gptel-agent-harness--pending-prompts)))
        ;; Plan file created and ${planInfo} replaced with its path.
        (let ((plan-file gptel-agent-harness--plan-file))
          (should (file-exists-p plan-file))
          (should (string-prefix-p (gptel-agent-harness--plan-temp-dir)
                                   plan-file))
          (should-not (file-exists-p (expand-file-name "PLAN.md" proj-dir)))
          (should (equal gptel-agent-harness--plan-file plan-file))
          (should (string-match-p (regexp-quote plan-file)
                                  (nth 1 gptel-agent-harness--pending-prompts)))
          (should-not (string-match-p "\\${planInfo}"
                                      (nth 1 gptel-agent-harness--pending-prompts))))
        ;; Switch back to build → only build-switch.md queued.
        (gptel-agent-harness-toggle-mode)
        (should (eq gptel-agent-harness--mode 'build))
        (should (= 1 (length gptel-agent-harness--pending-prompts)))
        (should (string-match-p "operational mode has changed"
                                (car gptel-agent-harness--pending-prompts)))))))

(ert-deftest gptel-agent-harness-test-inject-pending-prompts ()
  "Pending mode prompts are injected before the user request, once."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((user-msg (list :role "user" :content "my request"))
               (messages (vector (list :role "user" :content "history")
                                 user-msg))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-send--handlers
                     :messages messages)))
          ;; Mirror `gptel--realize-query', which sets :backend in the FSM info.
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          (gptel-agent-harness--inject-pending-prompts fsm)
          (let ((final (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                  :messages)))
            (should (= 4 (length final)))
            ;; Injected prompts precede the user's request, which stays last.
            (should (equal (aref final 3) user-msg))
            (should (string-match-p "Plan Mode"
                                    (plist-get (aref final 1) :content)))
            (should (string-match-p "Plan mode is active"
                                    (plist-get (aref final 2) :content))))
          ;; Queue consumed; a second call injects nothing.
          (with-current-buffer buf
            (should (null gptel-agent-harness--pending-prompts)))
          (gptel-agent-harness--inject-pending-prompts fsm)
          (should (= 4 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages)))))))))

(ert-deftest gptel-agent-harness-test-set-mode-accepts-string ()
  "`gptel-agent-harness-set-mode' accepts interactive string input."
  (gptel-agent-harness-test--with-temp-dir proj-dir
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--project-dir proj-dir)
        ;; Interactive `S' prompts yield strings, not symbols.
        (gptel-agent-harness-set-mode "plan")
        (should (eq gptel-agent-harness--mode 'plan))
        (should (= 2 (length gptel-agent-harness--pending-prompts)))
        ;; Case-insensitive: "BUILD"/"PLAN" also work.
        (gptel-agent-harness-set-mode "BUILD")
        (should (eq gptel-agent-harness--mode 'build))
        (should (= 1 (length gptel-agent-harness--pending-prompts)))
        (gptel-agent-harness-set-mode "Plan")
        (should (eq gptel-agent-harness--mode 'plan))
        (gptel-agent-harness-set-mode 'build)
        (should (eq gptel-agent-harness--mode 'build))
        (should-error (gptel-agent-harness-set-mode "nonsense"))))))

(ert-deftest gptel-agent-harness-test-inject-skipped-without-backend ()
  "Nothing is injected while the request has no backend yet.
The prompt is still being assembled, so the queue must be preserved for
the top-level request that follows."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((messages (vector (list :role "user" :content "hi")))
               (fsm (gptel-agent-harness-test--make-fsm buf
                      :messages messages)))
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          (gptel-agent-harness--inject-pending-prompts fsm)
          ;; No backend in FSM info yet: no injection, queue preserved
          ;; for the next top-level request.
          (should (= 1 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages))))
          (with-current-buffer buf
            (should (= 2 (length gptel-agent-harness--pending-prompts)))))))))

(ert-deftest gptel-agent-harness-test-inject-subagent-plan-reminder ()
  "Sub-agent requests get a read-only reminder in plan mode.
The pending queue is preserved for the next top-level request."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((messages (vector (list :role "user" :content "task")))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-agent-request--handlers
                     :messages messages))
               (plan-file nil))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan)
            (setq plan-file gptel-agent-harness--plan-file))
          (gptel-agent-harness--inject-pending-prompts fsm)
          (let ((final (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                  :messages)))
            (should (= 2 (length final)))
            (let ((reminder (plist-get (aref final 0) :content)))
              (should (string-match-p "READ-ONLY" reminder))
              (should (string-match-p (regexp-quote plan-file)
                                      reminder))))
          ;; Queue preserved for the next top-level request.
          (with-current-buffer buf
            (should (= 2 (length gptel-agent-harness--pending-prompts)))))))))

(ert-deftest gptel-agent-harness-test-inject-subagent-reminder-once ()
  "The plan-mode reminder is injected at most once per sub-agent FSM."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((messages (vector (list :role "user" :content "task")))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-agent-request--handlers
                     :messages messages)))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          ;; Multiple WAIT transitions (tool rounds) must not duplicate.
          (gptel-agent-harness--inject-pending-prompts fsm)
          (gptel-agent-harness--inject-pending-prompts fsm)
          (gptel-agent-harness--inject-pending-prompts fsm)
          (should (= 2 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages)))))))))

(ert-deftest gptel-agent-harness-test-inject-harness-internal-none ()
  "Harness-internal requests (default handlers) get no plan-mode reminder."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((messages (vector (list :role "user" :content "content")))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-request--handlers
                     :messages messages)))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          ;; Compaction/title/summary requests use gptel-request--handlers:
          ;; they must NOT receive the plan-mode reminder.
          (gptel-agent-harness--inject-pending-prompts fsm)
          (should (= 1 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages)))))))))

(ert-deftest gptel-agent-harness-test-inject-subagent-build-mode-none ()
  "Sub-agent requests get no reminder in build mode."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((messages (vector (list :role "user" :content "task")))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-agent-request--handlers
                     :messages messages)))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir))
          ;; Build mode (default): no injection, queue untouched.
          (gptel-agent-harness--inject-pending-prompts fsm)
          (should (= 1 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages))))
          (with-current-buffer buf
            (should (null gptel-agent-harness--pending-prompts))))))))

(ert-deftest gptel-agent-harness-test-inject-pending-midflight-appends ()
  "Mid-flight (tool round) requests get prompts appended at the end.
Inserting between a tool call and its result would break backend
message ordering, so the prompts go after the tool result message."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (let* ((tool-result (list :role "tool" :content "result"))
               (messages (vector (list :role "user" :content "history")
                                 (list :role "assistant" :content "call")
                                 tool-result))
               (fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-send--handlers
                     :messages messages)))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          (gptel-agent-harness--inject-pending-prompts fsm)
          (let ((final (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                  :messages)))
            (should (= 5 (length final)))
            ;; Tool result stays in place; prompts appended at the end.
            (should (equal (aref final 2) tool-result))
            (should (string-match-p "Plan Mode"
                                    (plist-get (aref final 3) :content)))
            (should (string-match-p "Plan mode is active"
                                    (plist-get (aref final 4) :content)))))))))

(ert-deftest gptel-agent-harness-test-request-injection-position ()
  "`--request-injection-position' handles plain requests and tool rounds."
  (gptel-agent-harness-test--with-buffer buf
    (let ((data (list :messages (vector (list :role "user" :content "hi")))))
      ;; Plain user request last → inject before it.
      (should (= 0 (gptel-agent-harness--request-injection-position data))))
    (let ((data (list :messages (vector (list :role "user" :content "a")
                                        (list :role "user" :content "b")))))
      (should (= 1 (gptel-agent-harness--request-injection-position data))))
    ;; Tool result (role tool) last → append.
    (let ((data (list :messages (vector (list :role "user" :content "a")
                                        (list :role "tool" :content "r")))))
      (should (= 2 (gptel-agent-harness--request-injection-position data))))
    ;; Anthropic-style tool result (user role, list content) → append.
    (let ((data (list :messages (vector (list :role "user" :content "a")
                                        (list :role "user"
                                              :content (list (list :tool_result "r")))))))
      (should (= 2 (gptel-agent-harness--request-injection-position data))))
    ;; Empty messages → append (position 0).
    (let ((data (list :messages [])))
      (should (= 0 (gptel-agent-harness--request-injection-position data))))
    ;; OpenAI Responses container (:input) is handled too.
    (let ((data (list :input (vector (list :role "user" :content "a")
                                     (list :role "user" :content "req")))))
      (should (= 1 (gptel-agent-harness--request-injection-position data))))
    ;; Gemini container (:contents) is handled too.
    (let ((data (list :contents (vector (list :role "user" :content "req")))))
      (should (= 0 (gptel-agent-harness--request-injection-position data))))))

(ert-deftest gptel-agent-harness-test-request-injection-position-malformed ()
  "`--request-injection-position' handles non-vector message containers."
  (let ((data (list :messages "not a vector")))
    (should (= 0 (gptel-agent-harness--request-injection-position data))))
  (let ((data (list :messages (list (list :role "user" :content "hi")))))
    (should (= 0 (gptel-agent-harness--request-injection-position data))))
  (let ((data (list :messages (vector "raw" 42))))
    (should (= 2 (gptel-agent-harness--request-injection-position data))))
  (let ((data (list :foo 1)))
    (should (= 0 (gptel-agent-harness--request-injection-position data)))))

(ert-deftest gptel-agent-harness-test-wait-state-injects-pending ()
  "WAIT transition injects pending mode prompts before firing the request."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             #'gptel-agent-harness-test--position-aware-inject-prompt))
    (gptel-agent-harness-test--with-temp-dir proj-dir
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (setq gptel-agent-harness--context-ratio nil)
          (setq-local gptel-agent-harness--project-dir proj-dir)
          (gptel-agent-harness-set-mode 'plan))
        (let* ((fsm (gptel-agent-harness-test--make-fsm
                     buf :backend 'test-backend
                     :handlers gptel-send--handlers
                     :messages (vector (list :role "user" :content "hi"))))
               (orig-called nil)
               (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          ;; Mirror `gptel--realize-query', which sets :backend in the FSM info.
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT)
          (should (eq orig-called 'WAIT))
          (should (= 3 (length (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                          :messages))))
          (with-current-buffer buf
            (should (null gptel-agent-harness--pending-prompts))))))))

(ert-deftest gptel-agent-harness-test-mode-indicator ()
  "Test mode indicator string generation."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--mode 'build)
      (let ((result (gptel-agent-harness--mode-indicator)))
        (should (string-match-p "\\[Build\\]" result))
        (should (eq (get-text-property 0 'face result) 'success)))
      (setq gptel-agent-harness--mode 'plan)
      (let ((result (gptel-agent-harness--mode-indicator)))
        (should (string-match-p "\\[Plan\\]" result))
        (should (eq (get-text-property 0 'face result) 'warning))))))

(ert-deftest gptel-agent-harness-test-set-mode-verbose-message ()
  "`set-mode' logs a message when `gptel-agent-harness-verbose' is set."
  (let ((gptel-agent-harness-verbose t)
        (messages nil))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (gptel-agent-harness-set-mode 'build)
          (should (string-match-p "switched to build mode" (car messages))))))))

;;;; Plan File Location Tests

(ert-deftest gptel-agent-harness-test-plan-temp-dir-remote ()
  "`--plan-temp-dir' uses the remote temp directory for Tramp paths."
  (let ((default-directory "/ssh:host:/path/"))
    (cl-letf (((symbol-function 'temporary-file-directory)
               (lambda () "/remote/tmp/")))
      (should (equal (gptel-agent-harness--plan-temp-dir)
                     "/remote/tmp/")))))

(ert-deftest gptel-agent-harness-test-plan-temp-dir-fallback ()
  "`--plan-temp-dir' falls back to /tmp when every candidate is mounted."
  (let ((mounted-file-systems "\\(?:/tmp/\\|/var/tmp/\\)")
        (default-directory "/tmp/"))
    (cl-letf (((default-value 'temporary-file-directory) "/tmp/")
              ((symbol-function 'getenv) (lambda (&rest _) nil)))
      (should (equal (gptel-agent-harness--plan-temp-dir) "/tmp/")))))

(ert-deftest gptel-agent-harness-test-plan-file-path-project-fallback ()
  "`--plan-file-path' falls back to `default-directory' without a project dir."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--plan-file nil)
      (setq-local gptel-agent-harness--project-dir nil)
      (let ((default-directory "/tmp/projfallback/"))
        (let ((path (gptel-agent-harness--plan-file-path)))
          (should (string-match-p "projfallback" path))
          (should (string-suffix-p "PLAN.md" path)))))))

(provide 'gptel-agent-harness-test-plan)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-plan.el ends here
