;;; gptel-agent-harness-test-context.el --- Context ratio and mode-line tests -*- lexical-binding: t -*-
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
;; ERT tests for context monitoring: context ratio computation and
;; indicator, `--update-context-ratio', `--need-compaction-p', the
;; mode-line construct, and global mode enable/disable (including the
;; mode-line-misc-info teardown path).
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Context Ratio Tests

(ert-deftest gptel-agent-harness-test-context-ratio-for-fsm ()
  "Test FSM-based context ratio calculation."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
    (gptel-agent-harness-test--with-buffer buf
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :system (make-string 40000 ?x)
                    :messages (vector)))
             (ratio (gptel-agent-harness--context-ratio-for-fsm fsm)))
        ;; 40000/4 = 10000 tokens, 10000/32768 ≈ 0.305
        (should (> ratio 0.3))
        (should (< ratio 0.31))))))

(ert-deftest gptel-agent-harness-test-context-ratio-indicator ()
  "Test context ratio indicator string generation."
  (let ((gptel-agent-harness-show-context-ratio t)
        (gptel-agent-harness-context-trigger 0.70))
    ;; nil ratio → empty string
    (let ((gptel-agent-harness--context-ratio nil))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))
    ;; Low usage → success face
    (let ((gptel-agent-harness--context-ratio 0.25))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:25%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'success))))
    ;; Medium usage → warning face
    (let ((gptel-agent-harness--context-ratio 0.60))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:60%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'warning))))
    ;; High usage → error face
    (let ((gptel-agent-harness--context-ratio 0.85))
      (let ((result (gptel-agent-harness--context-ratio-indicator)))
        (should (string-match-p "\\[Ctx:85%%/70%%\\]" result))
        (should (eq (get-text-property 0 'face result) 'error))))
    ;; Display disabled → empty string
    (let ((gptel-agent-harness-show-context-ratio nil)
          (gptel-agent-harness--context-ratio 0.50))
      (should (equal (gptel-agent-harness--context-ratio-indicator) "")))))

;;;; Update Context Ratio Tests

(ert-deftest gptel-agent-harness-test-update-context-ratio ()
  "Compute and store the ratio for a top-level FSM, and no-op otherwise.
It must be a no-op for non-top-level FSMs or when :data is still a buffer."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
    ;; Top-level FSM with real data → ratio + raw estimate stored
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--token-calibration 1.0)
        (setq-local gptel-agent-harness--context-ratio nil)
        (setq-local gptel-agent-harness--last-raw-estimate nil))
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :handlers gptel-send--handlers
                   :tools (vector (list :type "function"))
                   :system (make-string 4000 ?a)
                   :messages (vector (list :role "user" :content "hello")))))
        (gptel-agent-harness--update-context-ratio fsm)
        (with-current-buffer buf
          (should (numberp gptel-agent-harness--context-ratio))
          (should (> gptel-agent-harness--context-ratio 0))
          (should (numberp gptel-agent-harness--last-raw-estimate))
          (should (> gptel-agent-harness--last-raw-estimate 0)))))
    ;; Non-top-level (sub-agent) FSM → no-op
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--context-ratio nil)
        (setq-local gptel-agent-harness--last-raw-estimate nil))
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :handlers 'sub-agent-handlers
                   :system "sys"
                   :messages (vector (list :role "user" :content "hi")))))
        (gptel-agent-harness--update-context-ratio fsm)
        (with-current-buffer buf
          (should-not gptel-agent-harness--context-ratio)
          (should-not gptel-agent-harness--last-raw-estimate))))
    ;; :data is a buffer (during assembly) → no-op
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--context-ratio nil))
      (let ((fsm (gptel-make-fsm
                  :info (list :buffer buf :data buf)
                  :handlers gptel-send--handlers)))
        (gptel-agent-harness--update-context-ratio fsm)
        (with-current-buffer buf
          (should-not gptel-agent-harness--context-ratio))))))

;;;; Compaction Triggers

(ert-deftest gptel-agent-harness-test-need-compaction-p ()
  "Test `--need-compaction-p' with all combinations."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness--context-ratio 0.80)
      (setq gptel-agent-harness--compacting-p nil))
    (let ((fsm (gptel-agent-harness-test--make-fsm buf
                 :handlers gptel-send--handlers
                 :tools (vector (list :type "function")))))
      ;; All conditions met
      (should (gptel-agent-harness--need-compaction-p fsm))
      ;; No agentic (no tools)
      (let ((fsm2 (gptel-agent-harness-test--make-fsm buf
                    :handlers gptel-send--handlers)))
        (should-not (gptel-agent-harness--need-compaction-p fsm2)))
      ;; Not top-level
      (let ((fsm3 (gptel-agent-harness-test--make-fsm buf
                    :handlers 'sub-agent
                    :tools (vector (list :type "function")))))
        (should-not (gptel-agent-harness--need-compaction-p fsm3)))
      ;; Below trigger
      (with-current-buffer buf
        (setq gptel-agent-harness--context-ratio 0.50))
      (should-not (gptel-agent-harness--need-compaction-p fsm))
      ;; Compact already in progress
      (with-current-buffer buf
        (setq gptel-agent-harness--context-ratio 0.80)
        (setq gptel-agent-harness--compacting-p t))
      (should-not (gptel-agent-harness--need-compaction-p fsm)))))

;;;; Mode-line Tests

(ert-deftest gptel-agent-harness-test-mode-line-setup-idempotent ()
  "Test mode-line setup is idempotent and uses a risky construct."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-mode t)
      (should (get 'gptel-agent-harness--mode-line-construct
                   'risky-local-variable))
      (gptel-agent-harness--setup-mode-line)
      (gptel-agent-harness--setup-mode-line)
      ;; Construct appears exactly once in either mode-line-format or mode-line-misc-info
      (let ((count (+ (cl-count 'gptel-agent-harness--mode-line-construct
                                mode-line-format)
                      (cl-count 'gptel-agent-harness--mode-line-construct
                                mode-line-misc-info))))
        (should (= 1 count))))))

(ert-deftest gptel-agent-harness-test-teardown-mode-line-misc-info-path ()
  "`--teardown-mode-line' cleans the construct from `mode-line-misc-info'."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local mode-line-misc-info
                  (append '(gptel-agent-harness--mode-line-construct)
                          (default-value 'mode-line-misc-info)))
      (setq-local mode-line-format (default-value 'mode-line-format))
      (setq-local which-func-mode t)
      (gptel-agent-harness--teardown-mode-line)
      (should-not (memq 'gptel-agent-harness--mode-line-construct
                        mode-line-misc-info))
      (should-not (local-variable-p 'mode-line-misc-info))
      (should-not (local-variable-p 'mode-line-format))
      (should-not (local-variable-p 'which-func-mode)))))

;;;; Global Mode Enable/Disable

(ert-deftest gptel-agent-harness-test-mode-enable-disable ()
  "End-to-end regression: enabling and disabling the global mode."
  (let ((was-enabled gptel-agent-harness-mode))
    (gptel-agent-harness-test--with-buffer buf
      (when was-enabled (gptel-agent-harness-mode -1))
      (with-current-buffer buf (setq-local gptel-mode t))
      ;; Enable
      (gptel-agent-harness-mode 1)
      (should (advice-member-p
               #'gptel-agent-harness--transition-advice
               'gptel--fsm-transition))
      (should (memq #'gptel-agent-harness--setup-mode-line gptel-mode-hook))
      (with-current-buffer buf
        ;; Construct should be in mode-line-format or mode-line-misc-info
        (should (or (memq 'gptel-agent-harness--mode-line-construct
                          mode-line-format)
                    (memq 'gptel-agent-harness--mode-line-construct
                          mode-line-misc-info)))
        (setq-local gptel-agent-harness--context-ratio 0.42)
        (should (string-match-p
                 "\\[Ctx:42%%/70%%\\]"
                 (gptel-agent-harness--context-ratio-indicator))))
      ;; Disable
      (gptel-agent-harness-mode -1)
      (should-not (advice-member-p
                   #'gptel-agent-harness--transition-advice
                   'gptel--fsm-transition))
      (should-not (memq #'gptel-agent-harness--setup-mode-line gptel-mode-hook))
      (with-current-buffer buf
        (should-not (or (memq 'gptel-agent-harness--mode-line-construct
                              mode-line-format)
                        (memq 'gptel-agent-harness--mode-line-construct
                              mode-line-misc-info)))
        (should-not gptel-agent-harness--context-ratio)))
    ;; Restore original state
    (if was-enabled
        (gptel-agent-harness-mode 1)
      (gptel-agent-harness-mode -1))))

;;;; Calibration fallback

(ert-deftest gptel-agent-harness-test-context-ratio-calibration-fallback ()
  "`--context-ratio-for-fsm' falls back to calibration 1.0 when the buffer is gone."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))
    (let* ((buf (generate-new-buffer " *dead-ratio*"))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :system "sys"
                  :messages (vector (list :role "user" :content "hi")))))
      (kill-buffer buf)
      (should (> (gptel-agent-harness--context-ratio-for-fsm fsm) 0)))))

(provide 'gptel-agent-harness-test-context)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-context.el ends here
