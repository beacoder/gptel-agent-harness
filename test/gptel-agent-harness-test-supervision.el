;;; gptel-agent-harness-test-supervision.el --- Completion supervision tests -*- lexical-binding: t -*-
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
;; ERT tests for the completion supervisor: terminal-state detection,
;; the nudge counter/budget and `--nudge', FSM helpers (`--buffer',
;; `--agentic-p', `--top-level-p', `--with-fsm-buffer'), and the
;; central `--transition-advice' with its terminal/wait-state handlers
;; (fallbacks, once-only ORIG-FN, dead-buffer termination).
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; FSM State Tests

(ert-deftest gptel-agent-harness-test-terminal-p ()
  "Test terminal state detection."
  (should (gptel-agent-harness--terminal-p 'DONE))
  (should (gptel-agent-harness--terminal-p 'ERRS))
  (should-not (gptel-agent-harness--terminal-p 'WAIT))
  (should-not (gptel-agent-harness--terminal-p 'TOOL))
  (should-not (gptel-agent-harness--terminal-p nil)))

;;;; Nudge Counter Tests

(ert-deftest gptel-agent-harness-test-can-nudge-p ()
  "Test nudge budget check, inc, get, and reset."
  (gptel-agent-harness-test--with-buffer buf
    (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
               (lambda (_fsm) buf)))
      (let ((fsm 'ignored)
            (gptel-agent-harness-max-nudges 2))
        (should (= (gptel-agent-harness--get-nudges fsm) 0))
        (gptel-agent-harness--inc-nudges fsm)
        (should (gptel-agent-harness--can-nudge-p fsm))
        (gptel-agent-harness--inc-nudges fsm)
        (should-not (gptel-agent-harness--can-nudge-p fsm))
        (gptel-agent-harness--reset-nudges fsm)
        (should (= (gptel-agent-harness--get-nudges fsm) 0))))))

(ert-deftest gptel-agent-harness-test-can-nudge-p-dead-buffer ()
  "A dead session buffer has no nudge budget.

The counter is buffer-local, so on a dead buffer `--inc-nudges' records
nothing and `--get-nudges' keeps returning 0.  Without this guard every
terminal transition would be redirected to WAIT and fire another
request, forever — `gptel--handle-wait' does not check buffer liveness."
  (let ((buf (generate-new-buffer " *gptel-harness-dead*")))
    (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
               (lambda (_fsm) buf)))
      (let ((fsm 'ignored)
            (gptel-agent-harness-max-nudges 2))
        (should (gptel-agent-harness--can-nudge-p fsm))
        (kill-buffer buf)
        (should-not (gptel-agent-harness--can-nudge-p fsm))
        ;; Budget stays exhausted no matter how often we try.
        (dotimes (_ 5) (gptel-agent-harness--inc-nudges fsm))
        (should-not (gptel-agent-harness--can-nudge-p fsm)))))
  ;; A missing :buffer is treated the same way.
  (cl-letf (((symbol-function 'gptel-agent-harness--buffer)
             (lambda (_fsm) nil)))
    (should-not (gptel-agent-harness--can-nudge-p 'ignored))))

(ert-deftest gptel-agent-harness-test-get-nudges-fallback ()
  "`--get-nudges' returns 0 when the FSM buffer is gone."
  (let* ((buf (generate-new-buffer " *dead-nudge*"))
         (fsm (gptel-agent-harness-test--make-fsm buf :system "sys")))
    (kill-buffer buf)
    (should (= (gptel-agent-harness--get-nudges fsm) 0))))

;;;; Nudge and Compaction Helpers

(ert-deftest gptel-agent-harness-test-nudge ()
  "`--nudge' appends the nudge message as a user turn and bumps the counter.

This is the only test asserting the injected payload; the sibling nudge
tests cover the failure paths (malformed `:data', signalling inject)."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             (lambda (_backend data msg)
               (let* ((msgs (or (plist-get data :messages) []))
                      (new-msgs (vconcat msgs (vector msg))))
                 (plist-put data :messages new-msgs)))))
    (gptel-agent-harness-test--with-buffer buf
      (let* ((messages (vector (list :role "user" :content "hello")))
             (fsm (gptel-agent-harness-test--make-fsm buf
                    :tools (vector (list :type "function"))
                    :messages messages))
             (orig-count (gptel-agent-harness--get-nudges fsm)))
        (should (gptel-agent-harness--nudge fsm))
        (should (= (gptel-agent-harness--get-nudges fsm) (1+ orig-count)))
        ;; The nudge lands as a trailing user message carrying the
        ;; configured text, leaving the original turn untouched.
        (let ((final (plist-get (plist-get (gptel-fsm-info fsm) :data) :messages)))
          (should (= 2 (length final)))
          (should (equal (aref final 0) (list :role "user" :content "hello")))
          (should (equal (plist-get (aref final 1) :role) "user"))
          (should (equal (plist-get (aref final 1) :content)
                         gptel-agent-harness-nudge-message)))))))

(ert-deftest gptel-agent-harness-test-nudge-malformed-data ()
  "`--nudge' never signals on malformed `:data' and returns nil.
A buffer/string `:data' (gptel assembles `:data' lazily) must not
reach `gptel--inject-prompt'; the counter is still bumped and nil is
returned.  A plist `:data' returns t."
  (gptel-agent-harness-test--with-buffer buf
    (let ((inject-called nil))
      (cl-letf (((symbol-function 'gptel--inject-prompt)
                 (lambda (&rest _) (setq inject-called t))))
        ;; Buffer as :data
        (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                      :tools (vector (list :type "function"))
                      :messages (vector (list :role "user" :content "hi"))))
               (info (gptel-fsm-info fsm)))
          (plist-put info :data (current-buffer))
          (let ((orig-count (gptel-agent-harness--get-nudges fsm)))
            (should-not (gptel-agent-harness--nudge fsm))
            (should-not inject-called)
            (should (= (gptel-agent-harness--get-nudges fsm) (1+ orig-count)))))
        ;; String as :data
        (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                      :tools (vector (list :type "function"))
                      :messages (vector (list :role "user" :content "hi"))))
               (info (gptel-fsm-info fsm)))
          (plist-put info :data "not a plist")
          (should-not (gptel-agent-harness--nudge fsm))
          (should-not inject-called))
        ;; Plist :data → injected, returns t
        (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                      :tools (vector (list :type "function"))
                      :messages (vector (list :role "user" :content "hi")))))
          (should (gptel-agent-harness--nudge fsm))
          (should inject-called))))))

(ert-deftest gptel-agent-harness-test-nudge-inject-error ()
  "`--nudge' returns nil when `gptel--inject-prompt' signals."
  (gptel-agent-harness-test--with-buffer buf
    (cl-letf (((symbol-function 'gptel--inject-prompt)
               (lambda (&rest _) (error "Boom"))))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :tools (vector (list :type "function"))
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-count (gptel-agent-harness--get-nudges fsm)))
        (should-not (gptel-agent-harness--nudge fsm))
        (should (= (gptel-agent-harness--get-nudges fsm) (1+ orig-count)))))))

;;;; FSM Helper Tests (buffer, agentic-p, top-level-p, with-fsm-buffer)

(ert-deftest gptel-agent-harness-test-fsm-helpers ()
  "Test `--buffer', `--agentic-p', `--top-level-p', `--with-fsm-buffer'."
  (gptel-agent-harness-test--with-buffer buf
    (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools (vector (list :type "function" :function (list :name "test")))
                  :system "sys"
                  :messages (vector))))
      (should (eq (gptel-agent-harness--buffer fsm) buf))
      (should (gptel-agent-harness--agentic-p fsm))
      (should (gptel-agent-harness--top-level-p fsm))
      (let ((result nil))
        (gptel-agent-harness--with-fsm-buffer fsm
          (setq result (current-buffer)))
        (should (eq result buf)))
      ;; Non-agentic (no tools)
      (let ((fsm2 (gptel-agent-harness-test--make-fsm buf :system "sys")))
        (should-not (gptel-agent-harness--agentic-p fsm2)))
      ;; Non-top-level (different handlers)
      (let ((fsm3 (gptel-agent-harness-test--make-fsm buf
                    :handlers 'sub-agent-handlers)))
        (should-not (gptel-agent-harness--top-level-p fsm3))))))

;;;; With-FSM-Buffer Dead Buffer Tests

(ert-deftest gptel-agent-harness-test-with-fsm-buffer-edge-cases ()
  "Test `--with-fsm-buffer' returns nil for dead or nil buffers."
  ;; Dead buffer
  (let* ((buf (generate-new-buffer " *dead-test*"))
         (fsm (gptel-agent-harness-test--make-fsm buf
                :system "sys" :messages (vector))))
    (kill-buffer buf)
    (should-not (gptel-agent-harness--with-fsm-buffer fsm
                  (error "Should not execute"))))
  ;; Nil buffer
  (let ((fsm (gptel-make-fsm
              :info (list :buffer nil :data nil)
              :handlers 'test)))
    (should-not (gptel-agent-harness--with-fsm-buffer fsm
                  (error "Should not execute")))))

;;;; Transition Advice (Central Supervisor)

(ert-deftest gptel-agent-harness-test-transition-advice ()
  "Test `--transition-advice': nudge, compact, tool-reset, and passthrough paths."
  (cl-letf (((symbol-function 'gptel--inject-prompt)
             (lambda (_backend data msg)
               (let* ((msgs (or (plist-get data :messages) []))
                      (new-msgs (vconcat msgs (vector msg))))
                 (plist-put data :messages new-msgs)))))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq gptel-agent-harness--context-ratio 0.50)
        (setq gptel-agent-harness--compacting-p nil)
        (setq gptel-agent-harness--nudge-count 0))
      (let* ((tools (vector (list :type "function" :function (list :name "test"))))
             (fsm (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers
                    :tools tools
                    :system "sys"
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-called nil))
        ;; 1) Terminal state → nudge path → orig-fn called with WAIT
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'DONE)
          (should (eq orig-called 'WAIT))
          (should (= (gptel-agent-harness--get-nudges fsm) 1)))
        ;; 2) WAIT state (no compaction needed) → pass through
        (setq orig-called nil)
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'WAIT)
          (should (eq orig-called 'WAIT)))
        ;; 3) TOOL state (top-level) → pass through + reset nudges
        (with-current-buffer buf (setq gptel-agent-harness--nudge-count 5))
        (setq orig-called nil)
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'TOOL)
          (should (eq orig-called 'TOOL))
          (should (= (gptel-agent-harness--get-nudges fsm) 0)))
        ;; 4) Terminal state → non-agentic → pass through
        (let* ((non-agent-fsm (gptel-agent-harness-test--make-fsm buf
                                :handlers gptel-send--handlers
                                :system "sys"
                                :messages (vector (list :role "user" :content "hi"))))
               (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (setq orig-called nil)
          (gptel-agent-harness--transition-advice orig-fn non-agent-fsm 'DONE)
          (should (eq orig-called 'DONE)))
        ;; 5) Terminal → nudge exhausted → pass through
        (with-current-buffer buf
          (setq gptel-agent-harness--nudge-count gptel-agent-harness-max-nudges))
        (setq orig-called nil)
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'ERRS)
          (should (eq orig-called 'ERRS)))
        ;; 6) Default path (non-terminal, non-TOOL/TPRE) → pass through
        (setq orig-called nil)
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'TYPE)
          (should (eq orig-called 'TYPE)))
        ;; 7) WAIT with compaction needed → compact returns nil → fallback
        (with-current-buffer buf
          (setq gptel-agent-harness--context-ratio 0.80)
          (setq gptel-agent-harness--compacting-p nil)
          (setq gptel-agent-harness--nudge-count 0))
        (cl-letf (((symbol-function 'gptel-agent-harness-commands-compact)
                   (lambda (&rest _) nil)))
          (setq orig-called nil)
          (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
            (gptel-agent-harness--transition-advice orig-fn fsm 'WAIT)
            (should (eq orig-called 'WAIT))))
        ;; 8) Terminal state with compacting-p set → let FSM die, no nudge
        (with-current-buffer buf
          (setq gptel-agent-harness--compacting-p t)
          (setq gptel-agent-harness--nudge-count 0))
        (setq orig-called nil)
        (let ((orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
          (gptel-agent-harness--transition-advice orig-fn fsm 'DONE)
          ;; Should pass through with DONE, not redirect to WAIT
          (should (eq orig-called 'DONE))
          ;; No nudge applied
          (should (= (gptel-agent-harness--get-nudges fsm) 0))
          ;; compacting-p unchanged
          (should (eq (with-current-buffer buf gptel-agent-harness--compacting-p) t)))))))

(ert-deftest gptel-agent-harness-test-transition-advice-nil-state ()
  "`--transition-advice' resolves the next state via `gptel--fsm-next' when nil."
  (gptel-agent-harness-test--with-buffer buf
    (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :system "sys"
                  :messages (vector)))
           (calls 0))
      (cl-letf (((symbol-function 'gptel--fsm-next) (lambda (_m) 'TYPE)))
        (let ((orig-fn (lambda (&optional _m _ns) (cl-incf calls))))
          (gptel-agent-harness--transition-advice orig-fn fsm)
          (should (= calls 1)))))))

(ert-deftest gptel-agent-harness-test-terminal-state-nudge-fallback ()
  "`--handle-terminal-state' falls back to the original state on nudge failure.
Malformed `:data' (nudge returns nil) or a throwing `gptel--inject-prompt'
must call ORIG-FN with the ORIGINAL new-state (DONE), never WAIT, and no
error may escape."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--compacting-p nil)
      (setq gptel-agent-harness--nudge-count 0))
    (let* ((tools (vector (list :type "function" :function (list :name "test"))))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools tools
                  :messages (vector (list :role "user" :content "hi"))))
           (orig-called nil)
           (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
      ;; Malformed :data → nudge returns nil → fallback to DONE
      (plist-put (gptel-fsm-info fsm) :data (current-buffer))
      (gptel-agent-harness--handle-terminal-state orig-fn fsm 'DONE)
      (should (eq orig-called 'DONE)))
    (let* ((tools (vector (list :type "function" :function (list :name "test"))))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools tools
                  :messages (vector (list :role "user" :content "hi"))))
           (orig-called nil)
           (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
      ;; `gptel--inject-prompt' throws → fallback to DONE
      (cl-letf (((symbol-function 'gptel--inject-prompt)
                 (lambda (&rest _) (error "Boom"))))
        (gptel-agent-harness--handle-terminal-state orig-fn fsm 'DONE)
        (should (eq orig-called 'DONE))))))

(ert-deftest gptel-agent-harness-test-terminal-state-dead-buffer-terminates ()
  "A killed session buffer must terminate the FSM, not nudge it forever.

Each redirect to WAIT fires a fresh LLM request, and the nudge counter
lives in the (now dead) buffer, so an unbounded loop of paid requests
would follow a user killing the buffer mid-run."
  (let* ((buf (generate-new-buffer " *gptel-harness-dead-fsm*"))
         (tools (vector (list :type "function" :function (list :name "test"))))
         (fsm (gptel-agent-harness-test--make-fsm buf
                :handlers gptel-send--handlers
                :tools tools
                :messages (vector (list :role "user" :content "hi"))))
         (targets nil)
         (orig-fn (lambda (&optional _m ns) (push ns targets))))
    (kill-buffer buf)
    (dotimes (_ 5)
      (gptel-agent-harness--handle-terminal-state orig-fn fsm 'DONE))
    (should (equal targets '(DONE DONE DONE DONE DONE)))))

(ert-deftest gptel-agent-harness-test-terminal-state-orig-fn-once ()
  "`--handle-terminal-state' calls ORIG-FN exactly once even when it throws.
The error handler must not re-invoke ORIG-FN (which would double-fire
the transition / request)."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--compacting-p nil)
      (setq gptel-agent-harness--nudge-count 0))
    (let* ((tools (vector (list :type "function" :function (list :name "test"))))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools tools
                  :messages (vector (list :role "user" :content "hi"))))
           (calls 0)
           (orig-fn (lambda (&optional _m _ns) (cl-incf calls) (error "Orig-fn boom"))))
      (should-error (gptel-agent-harness--handle-terminal-state orig-fn fsm 'DONE))
      (should (= calls 1)))))

(ert-deftest gptel-agent-harness-test-terminal-state-nudge-throw-verbose ()
  "A throwing nudge with verbose on logs and falls back to the original state."
  (let ((gptel-agent-harness-verbose t))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq gptel-agent-harness--compacting-p nil)
        (setq gptel-agent-harness--nudge-count 0))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers
                    :tools (vector (list :type "function"))
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-called nil)
             (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
        (cl-letf (((symbol-function 'gptel-agent-harness--nudge)
                   (lambda (&rest _) (error "Boom"))))
          (gptel-agent-harness--handle-terminal-state orig-fn fsm 'DONE)
          (should (eq orig-called 'DONE)))))))

(ert-deftest gptel-agent-harness-test-wait-state-compaction-error-fallback ()
  "`--handle-wait-state' falls back to the real transition when compaction errors.
A throwing `--compact' must not skip the transition; ORIG-FN is called
with WAIT and no error escapes."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--context-ratio 0.80)
      (setq gptel-agent-harness--compacting-p nil)
      (setq gptel-agent-harness--nudge-count 0))
    (let* ((tools (vector (list :type "function" :function (list :name "test"))))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools tools
                  :messages (vector (list :role "user" :content "hi"))))
           (orig-called nil)
           (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
      (cl-letf (((symbol-function 'gptel-agent-harness--compact)
                 (lambda (&rest _) (error "Boom"))))
        (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT)
        (should (eq orig-called 'WAIT))))))

(ert-deftest gptel-agent-harness-test-wait-state-orig-fn-once ()
  "`--handle-wait-state' calls ORIG-FN exactly once even when it throws.
The error handler must not re-invoke ORIG-FN (which would double-fire
the transition / request)."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--context-ratio 0.80)
      (setq gptel-agent-harness--compacting-p nil)
      (setq gptel-agent-harness--nudge-count 0))
    (let* ((tools (vector (list :type "function" :function (list :name "test"))))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :handlers gptel-send--handlers
                  :tools tools
                  :messages (vector (list :role "user" :content "hi"))))
           (calls 0)
           (orig-fn (lambda (&optional _m _ns) (cl-incf calls) (error "Orig-fn boom"))))
      (cl-letf (((symbol-function 'gptel-agent-harness--compact)
                 (lambda (&rest _) nil)))
        (should-error (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT))
        (should (= calls 1))))))

(ert-deftest gptel-agent-harness-test-wait-state-compaction-error-verbose ()
  "`--handle-wait-state' logs the compaction error when verbose."
  (let ((gptel-agent-harness-verbose t)
        (gptel-model "unknown-model")
        (messages nil))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq gptel-agent-harness--compacting-p nil))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers
                    :tools (vector (list :type "function"))
                    :system (make-string 100000 ?x)
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-called nil)
             (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages)))
                  ((symbol-function 'gptel-agent-harness--compact)
                   (lambda (&rest _) (error "Boom"))))
          (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT)
          (should (eq orig-called 'WAIT))
          (should (string-match-p "compaction error"
                                  (mapconcat #'identity messages "\n"))))))))

(ert-deftest gptel-agent-harness-test-wait-state-compaction-started ()
  "When compaction starts, `--handle-wait-state' skips the real transition."
  (let ((gptel-model "unknown-model"))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq gptel-agent-harness--compacting-p nil))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers
                    :tools (vector (list :type "function"))
                    :system (make-string 100000 ?x)
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-called nil)
             (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
        (cl-letf (((symbol-function 'gptel-agent-harness--compact)
                   (lambda (&rest _) t)))
          (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT)
          (should-not orig-called))))))

(ert-deftest gptel-agent-harness-test-wait-state-context-ratio-error ()
  "`--handle-wait-state' survives errors in context-ratio computation."
  (let ((gptel-agent-harness-verbose t))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq gptel-agent-harness--context-ratio nil))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers
                    :tools (vector (list :type "function"))
                    :messages (vector (list :role "user" :content "hi"))))
             (orig-called nil)
             (orig-fn (lambda (&optional _m ns) (setq orig-called ns))))
        (cl-letf (((symbol-function 'gptel-agent-harness--update-context-ratio)
                   (lambda (&rest _) (error "Boom"))))
          (gptel-agent-harness--handle-wait-state orig-fn fsm 'WAIT)
          (should (eq orig-called 'WAIT)))))))

(provide 'gptel-agent-harness-test-supervision)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-supervision.el ends here
