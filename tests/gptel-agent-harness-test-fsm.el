;;; gptel-agent-harness-test-fsm.el --- FSM hardening module tests -*- lexical-binding: t -*-
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
;; ERT tests for the FSM hardening module (gptel-agent-harness-fsm):
;; tool-arg normalization, tool-use error handling, idempotent
;; tool-call processing, result sanitization, and enable/disable.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-fsm)
(require 'gptel-agent-harness-test-utils)

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

(ert-deftest gptel-agent-harness-test-fsm-process-tool-call-verbose-duplicate ()
  "`--process-tool-call-advice' logs the duplicate skip when verbose."
  (let ((gptel-agent-harness-verbose t)
        (orig-calls 0))
    (let ((tool-call (list :name "tool1" :result "done")))
      (gptel-agent-harness-fsm--process-tool-call-advice
       (lambda (&rest _) (cl-incf orig-calls))
       'fsm 'tool-spec tool-call "late")
      (should (= orig-calls 0)))))

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

(provide 'gptel-agent-harness-test-fsm)

;; Local Variables:
;; package-lint-main-file: "tests/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-fsm.el ends here
