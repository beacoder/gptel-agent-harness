;;; gptel-agent-harness-test.el --- Tests for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
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
;; ERT tests for gptel-agent-harness.
;;
;; Run with:
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -l gptel-agent-harness-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness-test")'
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness)

;; Ensure gptel backends are available (needed for `gptel' function in
;; review/commands tests when running in batch mode).
(require 'gptel-openai nil t)

;;;; Stubs — minimal gptel API surface needed for testing
;; These provide a minimal gptel API surface when the real packages
;; are not available.  We use `fset' to avoid package-lint prefix errors.

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

;;;; Token Estimation Tests

(ert-deftest gptel-agent-harness-test-cjk-char-p ()
  "Test CJK character detection."
  (should (gptel-agent-harness--cjk-char-p ?中))
  (should (gptel-agent-harness--cjk-char-p ?あ))
  (should (gptel-agent-harness--cjk-char-p ?Ａ))
  (should-not (gptel-agent-harness--cjk-char-p ?A))
  (should-not (gptel-agent-harness--cjk-char-p ?é)))

(ert-deftest gptel-agent-harness-test-estimate-tokens ()
  "Test token estimation for mixed content."
  (with-temp-buffer
    (insert "abcdefghijklmnopqrst")  ; 20 latin chars → 5 tokens
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 5)))
  (with-temp-buffer
    (insert "你好世界")  ; 4 CJK chars → 2 tokens
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 2)))
  (with-temp-buffer
    (insert "hello   你好世界")  ; 8 latin + 4 CJK → 2+2=4
    (should (= (gptel-agent-harness--estimate-tokens (point-min) (point-max)) 4))))

;;;; Model / Context Window Tests

(ert-deftest gptel-agent-harness-test-model-name ()
  "Test model name coercion from various types."
  (let ((gptel-model 'claude-sonnet))
    (should (equal (gptel-agent-harness--model-name) "claude-sonnet")))
  (let ((gptel-model "gpt-5"))
    (should (equal (gptel-agent-harness--model-name) "gpt-5")))
  (let ((gptel-model 42))
    (should (equal (gptel-agent-harness--model-name) ""))))

(ert-deftest gptel-agent-harness-test-context-window ()
  "Test model context window lookup with pattern matching."
  (let ((gptel-model "claude-sonnet-4-20250514"))
    (should (= (gptel-agent-harness--context-window) 200000)))
  (let ((gptel-model "gpt-5-mini-2026"))
    (should (= (gptel-agent-harness--context-window) 128000)))
  (let ((gptel-model "unknown-model-xyz"))
    (should (= (gptel-agent-harness--context-window) 32768))))

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

;;;; Context Token Estimation from FSM Data

(ert-deftest gptel-agent-harness-test-context-tokens-from-data ()
  "Test token estimation from full prompt payload."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "system prompt here"
                   :messages (vector
                              (list :role "user" :content "hello world")
                              (list :role "assistant" :content "hi there")
                              (list :role "user" :content "do something")))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 12))))))

(ert-deftest gptel-agent-harness-test-context-tokens-includes-tools ()
  "Test token estimation includes tool definitions (schemas)."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      ;; Without tools
      (let* ((fsm-no-tools (gptel-agent-harness-test--make-fsm buf
                             :system "sys"
                             :messages (vector
                                        (list :role "user" :content "hi"))))
             (tokens-no-tools (gptel-agent-harness--context-tokens-from-data fsm-no-tools))
             ;; With tools — a vector of tool schema plists (as gptel serializes them)
             (tools-array (vector
                           (list :type "function"
                                 :function
                                 (list :name "search_files"
                                       :description "Search for files matching a pattern"
                                       :parameters
                                       (list :type "object"
                                             :properties
                                             (list :pattern (list :type "string"
                                                                  :description "Glob pattern")))))
                           (list :type "function"
                                 :function
                                 (list :name "read_file"
                                       :description "Read the contents of a file"
                                       :parameters
                                       (list :type "object"
                                             :properties
                                             (list :path (list :type "string"
                                                              :description "File path")))))))
             (fsm-with-tools (gptel-agent-harness-test--make-fsm buf
                               :system "sys"
                               :messages (vector
                                          (list :role "user" :content "hi"))
                               :tools tools-array))
             (tokens-with-tools (gptel-agent-harness--context-tokens-from-data fsm-with-tools)))
        ;; Tools should add a significant number of tokens
        (should (> tokens-with-tools tokens-no-tools))
        ;; The difference should be substantial (tool schemas are verbose)
        (should (> (- tokens-with-tools tokens-no-tools) 10))))))

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-with-list-content ()
  "Test token estimation with structured (list) content in messages."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "sys"
                   :messages (vector
                              (list :role "assistant"
                                    :content (list (list :text "part one")
                                                   (list :text "part two")))))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 5))))))

(ert-deftest gptel-agent-harness-test-context-tokens-gemini-format ()
  "Test token estimation with Gemini-style data (:contents, :systemInstruction, :parts)."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      ;; Gemini uses :contents instead of :messages, :systemInstruction instead
      ;; of :system, and :parts vectors instead of :content strings.
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :systemInstruction '(:parts [(:text "gemini system")])
                   :contents (vector
                              (list :role "user"
                                    :parts (vector (list :text "hello world")))
                              (list :role "model"
                                    :parts (vector (list :text "hi there")))))))
        ;; "gemini system\n" = 14 chars → 4 tokens (newline from parts loop)
        ;; "hello world" = 11 chars → 3 tokens
        ;; "hi there" = 8 chars → 2 tokens
        ;; total = 9
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 9))))))

(ert-deftest gptel-agent-harness-test-context-tokens-reasoning-and-thinking ()
  "Test token estimation includes reasoning/thinking content variants."
  (let ((gptel-agent-harness-verbose nil))
    ;; DeepSeek-style :reasoning_content
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system ""
                   :messages (vector
                              (list :role "assistant"
                                    :reasoning_content "think step by step"
                                    :content "final answer")))))
        ;; "think step by step\n" = 19 chars → 5 tokens
        ;; "final answer" = 12 chars → 3 tokens
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 8))))
    ;; Claude-style :thinking content blocks
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system ""
                   :messages (vector
                              (list :role "assistant"
                                    :content (list (list :thinking "let me think about this")
                                                   (list :text "here is the answer")))))))
        ;; Combined in one buffer pass = 41 chars → round(41/4) = 10
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 10))))
    ;; Reasoning with nil content + tool_calls
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system ""
                   :messages (vector
                              (list :role "assistant"
                                    :reasoning_content "internal reasoning here"
                                    :content nil
                                    :tool_calls
                                    (vector
                                     (list :type "function"
                                           :id "call_1"
                                           :function
                                           (list :name "search"
                                                 :arguments "{\"q\":\"test\"}"))))))))
        ;; reasoning: 23 + "\n" = 24 chars, nil content: 0,
        ;; tool_calls: "search\n" + "{\"q\":\"test\"}\n" = 7+13 = 20 chars
        ;; total = 44 chars → round(44/4) = 11
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 11))))))

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

;;;; Session Management Tests

(ert-deftest gptel-agent-harness-test-session-file-naming ()
  "Verify session file naming: nil without `gptel-mode', naming with project."
  ;; nil when gptel-mode is off
  (with-temp-buffer
    (setq-local gptel-mode nil)
    (should (null (gptel-agent-harness--session-file))))
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (rename-buffer "*test-session*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (let* ((file (gptel-agent-harness--session-file))
                 (basename (file-name-nondirectory file)))
            (should (string-prefix-p "project_" basename))
            (should (string-suffix-p ".md" basename))
            (should (string-match-p "[0-9]\\{12\\}" basename))
            (should (string-prefix-p temp-dir file))))))))

(ert-deftest gptel-agent-harness-test-auto-save-and-restore ()
  "Test auto-save creates a file with local variables and restore loads them."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (gptel-model "gpt-5-mini")
          (gptel--backend-name "test-backend")
          (gptel-system-prompt "system prompt")
          (gptel-tools (list (gptel-make-tool :name "test-tool" :function #'ignore)))
          (gptel-temperature 0.5)
          (gptel-max-tokens 1000)
          (gptel--num-messages-to-send 2))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (rename-buffer "*test-auto*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "Hello session")
          (gptel-agent-harness--auto-save-session)
          ;; Verify file was created with expected content
          (let* ((files (directory-files temp-dir t "\\.md\\'"))
                 (file (car files)))
            (should (file-exists-p file))
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (should (search-forward "gptel-agent-harness--project-dir" nil t))
              (should (search-forward "gptel-model" nil t))
              (should (search-forward "gptel--backend-name" nil t))
              (should (search-forward "gptel-system-prompt" nil t))
              (should (search-forward "gptel--tool-names" nil t)))
            ;; Test restore — creates a new non-file-visiting buffer
            (cl-letf (((symbol-function 'gptel-agent-update) #'ignore))
              (gptel-agent-harness-restore-session file))
            (should (derived-mode-p 'markdown-mode))
            (should gptel-mode)
            (should-not buffer-file-name)  ; not visiting a file
            (should-not (buffer-modified-p))
            (should (equal gptel-agent-harness--project-dir "/tmp/project"))
            (should (equal default-directory "/tmp/project"))
            (should (equal gptel-model "gpt-5-mini"))
            (should (equal gptel--backend-name "test-backend"))
            (should (equal gptel-system-prompt "system prompt"))
            (should (equal gptel-temperature 0.5))
            (should (equal gptel-max-tokens 1000))
            (should (equal gptel--num-messages-to-send 2))
            (kill-buffer (current-buffer))))))))

(ert-deftest gptel-agent-harness-test-restore-latest-session ()
  "Ensure the latest session file is chosen for restore."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir))
      ;; Create two session files from different buffers (different project names
      ;; to avoid filename collision when timestamps are identical)
      (gptel-agent-harness-test--with-buffer buf1
        (with-current-buffer buf1
          (rename-buffer "*test-first*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf1 "/tmp/alpha")
          (insert "first")
          (gptel-agent-harness--auto-save-session)))
      (gptel-agent-harness-test--with-buffer buf2
        (with-current-buffer buf2
          (rename-buffer "*test-second*" t)
          (gptel-agent-harness-test--setup-gptel-buffer buf2 "/tmp/beta")
          (insert "second")
          (gptel-agent-harness--auto-save-session)))
      ;; Make "second" file newer by touching its timestamp
      (let* ((files (directory-files temp-dir t "\\.md\\'"))
             (second-file (cl-find-if
                           (lambda (f)
                             (with-temp-buffer
                               (insert-file-contents f)
                               (search-forward "second" nil t)))
                           files)))
        (set-file-times second-file (time-add (current-time) 10)))
      ;; Verify latest is "second"
      (let* ((files (directory-files temp-dir t "\\.md\\'"))
             (latest (car (sort files #'file-newer-than-file-p))))
        (should (= (length files) 2))
        (with-temp-buffer
          (insert-file-contents latest)
          (should (search-forward "second" nil t)))
        (cl-letf (((symbol-function 'gptel-agent-update) #'ignore))
          (gptel-agent-harness-restore-latest-session))
        (should (derived-mode-p 'markdown-mode))
        (should-not buffer-file-name)
        (should (string= (buffer-string) "second"))
        (kill-buffer (current-buffer))))))

(ert-deftest gptel-agent-harness-test-auto-save-creates-dir ()
  "Verify auto-save creates the session directory if it does not exist."
  (gptel-agent-harness-test--with-temp-dir temp-parent
    (let* ((temp-dir (expand-file-name "subdir" temp-parent))
           (gptel-agent-harness-session-dir temp-dir)
           (gptel-model "gpt-5-mini"))
      (should-not (file-exists-p temp-dir))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "content")
          (gptel-agent-harness--auto-save-session)
          (should (file-exists-p temp-dir))
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'")))))))))
(ert-deftest gptel-agent-harness-test-auto-save-overwrites-same-file ()
  "Verify repeated auto-saves from same buffer overwrite the same file."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (gptel-model "gpt-5-mini"))
      (gptel-agent-harness-test--with-buffer buf
        (with-current-buffer buf
          (gptel-agent-harness-test--setup-gptel-buffer buf "/tmp/project")
          (insert "version-1")
          (gptel-agent-harness--auto-save-session)
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'"))))
          ;; Save again with different content
          (erase-buffer)
          (insert "version-2")
          (gptel-agent-harness--auto-save-session)
          ;; Still only one file
          (should (= 1 (length (directory-files temp-dir t "\\.md\\'"))))
          ;; Content is updated
          (let ((file (car (directory-files temp-dir t "\\.md\\'"))))
            (with-temp-buffer
              (insert-file-contents file)
              (should (search-forward "version-2" nil t)))))))))

;;;; Compaction Tests

(ert-deftest gptel-agent-harness-test-compaction ()
  "Test the full compaction flow across multiple compaction cycles.
Covers:
 - 1st compaction: no prior summary, current round dropped, resume request sent
 - 2nd compaction: old summary kept as plain text in LLM input
 - 3rd compaction: header/separator stripped, old summary is plain context"
  (let ((gptel-agent-harness-compact-header "**[Compacted Summary]**\n\n")
        (gptel-agent-harness-compact-separator "\n\n---\n\n")
        (gptel-agent-harness-verbose nil))
    (let ((prompt-file (make-temp-file "compact-prompt-" nil ".txt"
                                       "compact test prompt")))
      (unwind-protect
          (let ((gptel-agent-harness-compact-prompt-file prompt-file))
            (gptel-agent-harness-test--with-buffer buf
              (with-current-buffer buf
                (gptel-agent-harness-test--setup-gptel-buffer buf)
                (setq-local gptel-agent-harness--compacting-p nil)
                (let* ((gptel-send-called nil)
                       (captured-content nil)
                       (tools (vector (list :type "function"
                                            :function (list :name "test"))))
                       (make-fsm
                        (lambda ()
                          (gptel-agent-harness-test--make-fsm buf
                            :handlers gptel-send--handlers
                            :tools tools
                            :messages (vector
                                       (list :role "user" :content "req1")
                                       (list :role "user" :content "req2"))))))

                  ;; === 1st compaction: fresh buffer with user text + response ===
                  (insert "User prompt.\n")
                  (let ((round-start (point)))
                    (insert "Assistant first response.")
                    (put-text-property round-start (point) 'gptel 'response))
                  (cl-letf (((symbol-function 'gptel-agent-harness-commands-compact)
                             (lambda (callback)
                               (setq captured-content
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                               (erase-buffer)
                               (insert "Summary after 1st compaction.\n")
                               (when (functionp callback)
                                 (funcall callback nil))))
                            ((symbol-function 'gptel-send)
                             (lambda () (setq gptel-send-called t))))
                    (setq gptel-send-called nil)
                    (gptel-agent-harness--compact (funcall make-fsm))
                    ;; Current round dropped — not in LLM input
                    (should-not (string-match-p "Assistant first response" captured-content))
                    ;; User prompt IS in the input (no header to strip on first time)
                    (should (string-match-p "User prompt" captured-content))
                    ;; Resume layout: header + summary + separator + last request
                    (let ((content (buffer-string)))
                      (should (string-match-p "\\`\\*\\*\\[Compacted Summary\\]\\*\\*"
                                              content))
                      (should (string-match-p "Summary after 1st compaction" content))
                      (should (string-match-p "\n\n---\n\n" content))
                      (should (string-match-p "req2" content))
                      (should gptel-send-called)))

                  ;; === 2nd compaction: buffer has header + summary + separator + content ===
                  (setq-local gptel-agent-harness--compacting-p nil)
                  (let ((round-start (point-max)))
                    (goto-char (point-max))
                    (insert "Assistant second response.")
                    (put-text-property round-start (point-max) 'gptel 'response))
                  (cl-letf (((symbol-function 'gptel-agent-harness-commands-compact)
                             (lambda (callback)
                               (setq captured-content
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                               (erase-buffer)
                               (insert "Summary after 2nd compaction.\n")
                               (when (functionp callback)
                                 (funcall callback nil))))
                            ((symbol-function 'gptel-send)
                             (lambda () (setq gptel-send-called t))))
                    (setq gptel-send-called nil)
                    (gptel-agent-harness--compact (funcall make-fsm))
                    ;; Old summary present as plain text (no tags)
                    (should (string-match-p "Summary after 1st compaction"
                                            captured-content))
                    (should-not (string-match-p "<previous-summary>" captured-content))
                    ;; Header and separator stripped from input
                    (should-not (string-match-p "\\*\\*\\[Compacted Summary\\]\\*\\*"
                                                captured-content))
                    (should-not (string-match-p "\n\n---\n\n" captured-content))
                    ;; Current round dropped
                    (should-not (string-match-p "Assistant second response"
                                                captured-content))
                    (should gptel-send-called))

                  ;; === 3rd compaction: verify repeated cycles work cleanly ===
                  (setq-local gptel-agent-harness--compacting-p nil)
                  (let ((round-start (point-max)))
                    (goto-char (point-max))
                    (insert "Assistant third response.")
                    (put-text-property round-start (point-max) 'gptel 'response))
                  (cl-letf (((symbol-function 'gptel-agent-harness-commands-compact)
                             (lambda (callback)
                               (setq captured-content
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                               (erase-buffer)
                               (insert "Summary after 3rd compaction.\n")
                               (when (functionp callback)
                                 (funcall callback nil))))
                            ((symbol-function 'gptel-send)
                             (lambda () (setq gptel-send-called t))))
                    (setq gptel-send-called nil)
                    (gptel-agent-harness--compact (funcall make-fsm))
                    ;; Previous summary as plain text
                    (should (string-match-p "Summary after 2nd compaction"
                                            captured-content))
                    ;; No tags, no frame artifacts
                    (should-not (string-match-p "<previous-summary>" captured-content))
                    (should-not (string-match-p "\\*\\*\\[Compacted Summary\\]\\*\\*"
                                                captured-content))
                    (should-not (string-match-p "\n\n---\n\n" captured-content))
                    ;; Current round dropped
                    (should-not (string-match-p "Assistant third response"
                                                captured-content))
                    (should gptel-send-called))))))
        (delete-file prompt-file)))))
;;;; Token Calibration Tests

(ert-deftest gptel-agent-harness-test-calibration-updates-ratio ()
  "Test calibration factor: normal update, clamping, no-op, and non-interference with compacting-p."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-agent-harness--token-calibration 1.0)
      (setq-local gptel-agent-harness--last-raw-estimate 100)
      (setq-local gptel-agent-harness--compacting-p nil)
      ;; Normal: 150 input / 100 estimate = 1.5
      (setq-local gptel--token-usage (list (list :input 150 :output 20) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 1.5))
      ;; Clamp high: 800 / 100 = 8 → clamped to 3.0
      (setq-local gptel--token-usage (list (list :input 800 :output 200) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 3.0))
      ;; Clamp low: 5 / 100 = 0.05 → clamped to 0.5
      (setq-local gptel--token-usage (list (list :input 5 :output 5) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 0.5))
      ;; No-op when usage is nil
      (setq-local gptel-agent-harness--token-calibration 1.5)
      (setq-local gptel--token-usage nil)
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 1.5))
      ;; No-op when raw estimate is nil
      (setq-local gptel-agent-harness--last-raw-estimate nil)
      (setq-local gptel--token-usage (list (list :input 120 :output 50) nil))
      (gptel-agent-harness--update-token-calibration)
      (should (= gptel-agent-harness--token-calibration 1.5))
      ;; Does not clear compacting-p anymore
      (setq-local gptel-agent-harness--compacting-p t)
      (setq-local gptel-agent-harness--last-raw-estimate 100)
      (setq-local gptel--token-usage (list (list :input 150 :output 20) nil))
      (gptel-agent-harness--update-token-calibration)
      ;; Calibration hook no longer clears compacting-p
      (should (eq gptel-agent-harness--compacting-p t)))))

(ert-deftest gptel-agent-harness-test-calibration-applied-to-ratio ()
  "Test that context ratio incorporates calibration factor."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--token-calibration 1.5))
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :system (make-string 40000 ?x)
                    :messages (vector)))
             (ratio (gptel-agent-harness--context-ratio-for-fsm fsm)))
        ;; Raw: 10000 tokens, calibrated: 15000, ratio: 15000/32768 ≈ 0.458
        (should (> ratio 0.44))
        (should (< ratio 0.47))))))

;;;; Tool Override Tests (gptel-agent-harness-tools)

(ert-deftest gptel-agent-harness-test-tools-enable-disable-idempotent ()
  "Test tools enable/disable: overrides, restores, and idempotency."
  (let ((gptel-agent-harness-tools--orig-glob nil)
        (gptel-agent-harness-tools--orig-grep nil)
        (orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep)))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          ;; After enable, glob/grep should NOT be the originals
          (should-not (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should-not (eq (symbol-function 'gptel-agent--grep) orig-grep))
          ;; The originals should be saved
          (should (eq gptel-agent-harness-tools--orig-glob orig-glob))
          (should (eq gptel-agent-harness-tools--orig-grep orig-grep))
          ;; Second enable should not lose the originals
          (gptel-agent-harness-tools-enable)
          (should (eq gptel-agent-harness-tools--orig-glob orig-glob))
          (should (eq gptel-agent-harness-tools--orig-grep orig-grep))
          ;; Disable should restore
          (gptel-agent-harness-tools-disable)
          (should (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should (eq (symbol-function 'gptel-agent--grep) orig-grep)))
      ;; Safety restore
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep)
      (setq gptel-agent-harness-tools--orig-glob nil)
      (setq gptel-agent-harness-tools--orig-grep nil))))

;;;; Agent Override Tests

(ert-deftest gptel-agent-harness-test-agent-enable-disable-idempotent ()
  "Test agent override: enable overrides dirs+fn, disable restores, idempotent."
  (let ((gptel-agent-harness-agent--orig-dirs nil)
        (gptel-agent-harness-agent--orig-fn nil)
        (gptel-agent-harness-tools--orig-glob nil)
        (gptel-agent-harness-tools--orig-grep nil)
        (orig-dirs gptel-agent-dirs)
        (orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep))
        (orig-agent (and (fboundp 'gptel-agent)
                         (symbol-function 'gptel-agent))))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          (gptel-agent-harness-agent-enable)
          ;; Dirs overridden
          (should (equal gptel-agent-dirs gptel-agent-harness-agent-dirs))
          (should (equal gptel-agent-harness-agent--orig-dirs orig-dirs))
          ;; Function overridden
          (should (advice-member-p #'gptel-opencode-agent 'gptel-agent))
          ;; Second enable preserves originals
          (gptel-agent-harness-agent-enable)
          (should (equal gptel-agent-harness-agent--orig-dirs orig-dirs))
          ;; Disable restores everything and clears state
          (gptel-agent-harness-agent-disable)
          (gptel-agent-harness-tools-disable)
          (should (equal gptel-agent-dirs orig-dirs))
          (when orig-agent
            (should (eq (symbol-function 'gptel-agent) orig-agent)))
          (should-not gptel-agent-harness-tools--orig-glob)
          (should-not gptel-agent-harness-tools--orig-grep)
          (should-not gptel-agent-harness-agent--orig-dirs)
          (should-not gptel-agent-harness-agent--orig-fn))
      (setq gptel-agent-dirs orig-dirs)
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep)
      (when orig-agent (fset 'gptel-agent orig-agent))
      (setq gptel-agent-harness-agent--orig-dirs nil)
      (setq gptel-agent-harness-agent--orig-fn nil)
      (setq gptel-agent-harness-tools--orig-glob nil)
      (setq gptel-agent-harness-tools--orig-grep nil))))

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

;;;; Nudge and Compaction Helpers

(ert-deftest gptel-agent-harness-test-nudge ()
  "Test `--nudge' injects message and bumps counter."
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
        (gptel-agent-harness--nudge fsm)
        (should (= (gptel-agent-harness--get-nudges fsm) (1+ orig-count)))))))

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

(ert-deftest gptel-agent-harness-test-last-user-request ()
  "Test `--last-user-request' returns last non-nudge user message."
  (gptel-agent-harness-test--with-buffer buf
    (let* ((nudge-msg gptel-agent-harness-nudge-message)
           (messages (vector
                      (list :role "user" :content "request 1")
                      (list :role "assistant" :content "reply 1")
                      (list :role "user" :content nudge-msg)
                      (list :role "assistant" :content "reply 2")
                      (list :role "user" :content "request 2")))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :messages messages)))
      (should (equal (gptel-agent-harness--last-user-request fsm)
                     "request 2")))
    ;; Only nudges → nil
    (let* ((nudge-msg gptel-agent-harness-nudge-message)
           (messages (vector
                      (list :role "user" :content nudge-msg)
                      (list :role "assistant" :content "reply")))
           (fsm (gptel-agent-harness-test--make-fsm buf
                  :messages messages)))
      (should-not (gptel-agent-harness--last-user-request fsm)))))

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

(ert-deftest gptel-agent-harness-test-write-local-vars ()
  "Test `--write-local-vars' serialization."
  (with-temp-buffer
    (gptel-agent-harness--write-local-vars
     '(("gptel-model" . "test-model")
       ("gptel-temperature" . 0.7)
       ("gptel--backend-name" . nil)
       ("gptel-max-tokens" . 1000)))
    (goto-char (point-min))
    (should (search-forward "gptel-model: " nil t))
    (should (search-forward "\"test-model\"" nil t))
    (should (search-forward "gptel-temperature: " nil t))
    (should (search-forward "0.7" nil t))
    (should (search-forward "gptel-max-tokens: " nil t))
    (should (search-forward "1000" nil t))
    (should-not (search-forward "gptel--backend-name" nil t))))

(ert-deftest gptel-agent-harness-test-sanitize-title ()
  "Test `--sanitize-title' produces safe filenames."
  ;; Normal title
  (should (equal (gptel-agent-harness--sanitize-title "Debugging 500 errors")
                 "Debugging-500-errors"))
  ;; Quoted title from LLM
  (should (equal (gptel-agent-harness--sanitize-title "\"Fix auth bug\"")
                 "Fix-auth-bug"))
  ;; Unsafe filesystem chars
  (should (equal (gptel-agent-harness--sanitize-title "path/to\\file:test")
                 "path-to-file-test"))
  ;; Truncation at 50 chars
  (let ((long-title (make-string 60 ?x)))
    (should (= (length (gptel-agent-harness--sanitize-title long-title)) 50)))
  ;; Trailing hyphens removed
  (should (equal (gptel-agent-harness--sanitize-title "trailing---")
                 "trailing"))
  ;; Whitespace trimmed
  (should (equal (gptel-agent-harness--sanitize-title "  spaced out  ")
                 "spaced-out")))

(ert-deftest gptel-agent-harness-test-setup-teardown-session ()
  "Test session and calibration setup/teardown hook management."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness--setup-session)
      (gptel-agent-harness--setup-calibration)
      (should (memq #'gptel-agent-harness--auto-save-session
                    gptel-post-response-functions))
      (should (memq #'gptel-agent-harness--update-token-calibration
                    gptel-post-response-functions))
      (gptel-agent-harness--teardown-session)
      (gptel-agent-harness--teardown-calibration)
      (should-not (memq #'gptel-agent-harness--auto-save-session
                        gptel-post-response-functions))
      (should-not (memq #'gptel-agent-harness--update-token-calibration
                        gptel-post-response-functions)))))

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

;;;; Commands Module Tests

(ert-deftest gptel-agent-harness-test-read-prompt-files ()
  "Test prompt file readers handle existing and missing files."
  ;; Review prompt
  (let ((temp-file (make-temp-file "review-" nil ".txt" "test review prompt")))
    (let ((gptel-agent-harness-commands--review-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-review-prompt)
                     "test review prompt")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--review-prompt-file "/nonexistent/review.txt"))
    (should-error (gptel-agent-harness-commands--read-review-prompt)))
  ;; Initialize prompt
  (let ((temp-file (make-temp-file "initialize-" nil ".txt" "initialize prompt")))
    (let ((gptel-agent-harness-commands--initialize-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-initialize-prompt)
                     "initialize prompt")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--initialize-prompt-file "/nonexistent/init.txt"))
    (should-error (gptel-agent-harness-commands--read-initialize-prompt)))
  ;; Summary prompt
  (let ((temp-file (make-temp-file "summary-" nil ".txt" "Summarize this.")))
    (let ((gptel-agent-harness-commands--summary-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-summary-prompt)
                     "Summarize this.")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--summary-prompt-file "/nonexistent/summary.txt"))
    (should-error (gptel-agent-harness-commands--read-summary-prompt)))
  ;; Compact prompt
  (let ((temp-file (make-temp-file "compact-" nil ".txt" "compact instructions")))
    (unwind-protect
        (let ((gptel-agent-harness-compact-prompt-file temp-file))
          (should (equal (gptel-agent-harness--read-compact-prompt)
                         "compact instructions")))
      (delete-file temp-file)))
  (let ((gptel-agent-harness-compact-prompt-file "/nonexistent/compact.txt"))
    (should-error (gptel-agent-harness--read-compact-prompt))))

(ert-deftest gptel-agent-harness-test-substitute-placeholders ()
  "Test `gptel-agent-harness-commands--substitute-placeholders' replaces ${path} and $ARGUMENTS."
  (let ((template "Review files in ${path} with args: $ARGUMENTS"))
    (should (equal (gptel-agent-harness-commands--substitute-placeholders
                    template "/tmp/project" "commit-hash")
                   "Review files in /tmp/project with args: commit-hash")))
  ;; $ARGUMENTS is nil → empty string
  (should (equal (gptel-agent-harness-commands--substitute-placeholders
                  "Args: $ARGUMENTS" "/tmp" nil)
                 "Args: "))
  ;; Multiple occurrences
  (should (equal (gptel-agent-harness-commands--substitute-placeholders
                  "${path} ... ${path}" "/a" nil)
                 "/a ... /a")))

(ert-deftest gptel-agent-harness-test-review-creates-dedicated-buffer ()
  "Test review command creates a buffer, sets system prompt, and passes arguments."
  (let ((temp-file (make-temp-file "review-" nil ".txt" "You are a code reviewer at ${path}. $ARGUMENTS")))
    (let ((gptel-agent-harness-commands--review-prompt-file temp-file))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) ""))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name) (intern (format "tool-%s" name))))
                ((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-send) #'ignore))
        ;; With arguments
        (let ((buf (gptel-agent-harness-commands-review "abc123")))
          (should (buffer-live-p buf))
          (should (string-match-p "\\*gptel-agent-review\\*" (buffer-name buf)))
          (with-current-buffer buf
            (should gptel-use-tools)
            (should (listp gptel-tools))
            (should (eq gptel-temperature 0))
            (should (string-match-p "You are a code reviewer" gptel-system-prompt))
            (should (string-match-p "abc123" gptel-system-prompt))
            (goto-char (point-max))
            (forward-line -1)
            (should (string-match-p "abc123" (thing-at-point 'line t))))
          (kill-buffer buf))
        ;; Without arguments (nil)
        (let ((buf (gptel-agent-harness-commands-review nil)))
          (with-current-buffer buf
            (goto-char (point-max))
            (forward-line -1)
            (should (string-match-p "Review code changes" (thing-at-point 'line t))))
          (kill-buffer buf))))
    (delete-file temp-file)))

(ert-deftest gptel-agent-harness-test-summary-requires-gptel-mode ()
  "Test summary command errors when not in a gptel buffer."
  (with-temp-buffer
    (setq-local gptel-mode nil)
    (should-error (gptel-agent-harness-commands-summary)
                  :type 'user-error)))

(ert-deftest gptel-agent-harness-test-summary-sends-request ()
  "Test summary command uses buffer content as input and prompt as system."
  (let* ((temp-file (make-temp-file "summary-" nil ".txt" "You are a summarizer."))
         (gptel-agent-harness-commands--summary-prompt-file temp-file)
         (captured-content nil)
         (captured-system nil))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (content &rest args)
                     (setq captured-content content)
                     (setq captured-system (plist-get args :system))))
                  ((symbol-function 'gptel--update-status)
                   (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq-local gptel-mode t)
            (insert "User: hello\nAssistant: hi there\n")
            (gptel-agent-harness-commands-summary)
            ;; Should have inserted the marker text
            (should (string-match-p "Summarize current conversation"
                                    (buffer-string)))
            ;; gptel-request should have been called with buffer content
            (should (string-match-p "User: hello" captured-content))
            (should (string-match-p "Assistant: hi there" captured-content))
            ;; System prompt should be from the file
            (should (equal captured-system "You are a summarizer."))))
      (delete-file temp-file))))

(ert-deftest gptel-agent-harness-test-summary-uses-region ()
  "Test summary command uses active region when set."
  (let* ((temp-file (make-temp-file "summary-" nil ".txt" "Summarize."))
         (gptel-agent-harness-commands--summary-prompt-file temp-file)
         (captured-content nil))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (content &rest _args)
                     (setq captured-content content)))
                  ((symbol-function 'gptel--update-status)
                   (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq-local gptel-mode t)
            (insert "line 1\nline 2\nline 3\n")
            ;; Activate region on "line 2\n"
            (goto-char (point-min))
            (forward-line 1)
            (set-mark (point))
            (forward-line 1)
            (activate-mark)
            (gptel-agent-harness-commands-summary)
            ;; Should only capture the region
            (should (equal captured-content "line 2\n"))
            ;; Mark should be deactivated
            (should-not mark-active)))
      (delete-file temp-file))))



(ert-deftest gptel-agent-harness-test-commands-compact-callback ()
  "Test compact callback handles success, error, abort, and unexpected types."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-mode t)
      (insert "old content")
      ;; Success: erases buffer and inserts response
      (let ((info (list :buffer buf)))
        (gptel-agent-harness-commands--compact-callback "new summary" info)
        (should (equal (buffer-string) "new summary\n"))
        (should-not (plist-get info :error)))
      ;; API error (nil response): info already has :error set by gptel
      (erase-buffer)
      (insert "still here")
      (let ((info (list :buffer buf :status "500 Internal" :error "server error")))
        (gptel-agent-harness-commands--compact-callback nil info)
        ;; Buffer unchanged on error
        (should (equal (buffer-string) "still here")))
      ;; Abort
      (let ((info (list :buffer buf)))
        (gptel-agent-harness-commands--compact-callback 'abort info)
        (should (equal (plist-get info :error) "Compaction aborted")))
      ;; Unexpected type (e.g., tool call)
      (let ((info (list :buffer buf)))
        (gptel-agent-harness-commands--compact-callback '(tool-call . stuff) info)
        (should (string-match-p "unexpected" (plist-get info :error))))
      ;; Reasoning block: ignored, no change
      (erase-buffer)
      (insert "unchanged")
      (let ((info (list :buffer buf)))
        (gptel-agent-harness-commands--compact-callback '(reasoning . "thinking...") info)
        (should (equal (buffer-string) "unchanged"))
        (should-not (plist-get info :error))))))

(ert-deftest gptel-agent-harness-test-commands-compact-requires-gptel-mode ()
  "Test compact function errors when not in a gptel buffer."
  (with-temp-buffer
    (setq-local gptel-mode nil)
    (should-error (gptel-agent-harness-commands-compact)
                  :type 'user-error)))

;;;; Title From Filename Tests

(ert-deftest gptel-agent-harness-test-title-from-filename ()
  "Test `--title-from-filename' extracts title from session file names."
  ;; Normal titled file
  (should (equal (gptel-agent-harness--title-from-filename
                  "/path/to/Fix-auth-bug_260723102000.md")
                 "Fix auth bug"))
  ;; Multi-word title with hyphens
  (should (equal (gptel-agent-harness--title-from-filename
                  "Debugging-500-errors_260101120000.md")
                 "Debugging 500 errors"))
  ;; Single word (project name only) → nil
  (should-not (gptel-agent-harness--title-from-filename
               "project_260723102000.md"))
  ;; No timestamp suffix → nil
  (should-not (gptel-agent-harness--title-from-filename
               "no-timestamp.md"))
  ;; Short timestamp (not 12 digits) → nil
  (should-not (gptel-agent-harness--title-from-filename
               "title_12345.md")))

;;;; Strip Compact Prefix / Insert Compact Frame (Isolated)

(ert-deftest gptel-agent-harness-test-strip-compact-prefix ()
  "Test `--strip-compact-prefix' removes header and separator."
  (let ((gptel-agent-harness-compact-header "**[Compacted Summary]**\n\n")
        (gptel-agent-harness-compact-separator "\n\n---\n\n"))
    ;; With header + separator present
    (with-temp-buffer
      (insert "**[Compacted Summary]**\n\nOld summary text.\n\n---\n\nNew conversation.")
      (gptel-agent-harness--strip-compact-prefix)
      (should (equal (buffer-string) "Old summary text.\n\nNew conversation.")))
    ;; Without header → no-op
    (with-temp-buffer
      (insert "Plain content with no frame.")
      (gptel-agent-harness--strip-compact-prefix)
      (should (equal (buffer-string) "Plain content with no frame.")))
    ;; Header without separator → only header removed
    (with-temp-buffer
      (insert "**[Compacted Summary]**\n\nSummary without separator.")
      (gptel-agent-harness--strip-compact-prefix)
      (should (equal (buffer-string) "Summary without separator.")))))

(ert-deftest gptel-agent-harness-test-insert-compact-frame ()
  "Test `--insert-compact-frame' adds header at start and separator at end."
  (let ((gptel-agent-harness-compact-header "**[Compacted Summary]**\n\n")
        (gptel-agent-harness-compact-separator "\n\n---\n\n"))
    (with-temp-buffer
      (insert "The summary content.")
      (gptel-agent-harness--insert-compact-frame)
      (should (equal (buffer-string)
                     "**[Compacted Summary]**\n\nThe summary content.\n\n---\n\n")))))

;;;; Update Context Ratio Tests

(ert-deftest gptel-agent-harness-test-update-context-ratio ()
  "Test `--update-context-ratio' computes and stores ratio + raw estimate."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))  ; 32768 fallback
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
          ;; Ratio should be computed
          (should (numberp gptel-agent-harness--context-ratio))
          (should (> gptel-agent-harness--context-ratio 0))
          ;; Raw estimate should be stored
          (should (numberp gptel-agent-harness--last-raw-estimate))
          (should (> gptel-agent-harness--last-raw-estimate 0)))))))

(ert-deftest gptel-agent-harness-test-update-context-ratio-skip-cases ()
  "Test `--update-context-ratio' is a no-op for non-top-level FSMs and buffer data."
  (let ((gptel-agent-harness-verbose nil)
        (gptel-model "unknown-model"))
    ;; Non-top-level FSM
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
    ;; :data is a buffer (during assembly)
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--context-ratio nil))
      (let ((fsm (gptel-make-fsm
                  :info (list :buffer buf :data buf)
                  :handlers gptel-send--handlers)))
        (gptel-agent-harness--update-context-ratio fsm)
        (with-current-buffer buf
          (should-not gptel-agent-harness--context-ratio))))))

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

;;;; Compact Buffer Command Tests

(ert-deftest gptel-agent-harness-test-compact-buffer-preconditions ()
  "Test compact-buffer errors for missing `gptel-mode' and in-progress compaction."
  ;; Not in gptel buffer
  (with-temp-buffer
    (setq-local gptel-mode nil)
    (should-error (gptel-agent-harness-commands-compact-buffer)
                  :type 'user-error))
  ;; Already compacting
  (with-temp-buffer
    (setq-local gptel-mode t)
    (setq-local gptel-agent-harness--compacting-p t)
    (should-error (gptel-agent-harness-commands-compact-buffer)
                  :type 'user-error)))

(ert-deftest gptel-agent-harness-test-compact-buffer-success-flow ()
  "Test compact-buffer sets compacting-p, strips prefix, calls compact, inserts frame."
  (let ((gptel-agent-harness-compact-header "**[Compacted Summary]**\n\n")
        (gptel-agent-harness-compact-separator "\n\n---\n\n")
        (prompt-file (make-temp-file "compact-" nil ".txt" "compact prompt")))
    (unwind-protect
        (let ((gptel-agent-harness-compact-prompt-file prompt-file))
          (gptel-agent-harness-test--with-buffer buf
            (with-current-buffer buf
              (setq-local gptel-mode t)
              (setq-local gptel-agent-harness--compacting-p nil)
              (insert "**[Compacted Summary]**\n\nOld summary.\n\n---\n\nConversation text.")
              (cl-letf (((symbol-function 'gptel-agent-harness-commands-compact)
                         (lambda (callback)
                           ;; Simulate successful compaction
                           (erase-buffer)
                           (insert "New summary.\n")
                           (when (functionp callback)
                             (funcall callback nil)))))
                (gptel-agent-harness-commands-compact-buffer)
                ;; After success: frame inserted, compacting cleared
                (should-not gptel-agent-harness--compacting-p)
                (should (string-match-p "\\`\\*\\*\\[Compacted Summary\\]\\*\\*"
                                        (buffer-string)))
                (should (string-match-p "New summary" (buffer-string)))
                (should (string-match-p "\n\n---\n\n" (buffer-string)))))))
      (delete-file prompt-file))))

;;;; Initialize Command Tests

(ert-deftest gptel-agent-harness-test-initialize-invalid-dir ()
  "Test initialize errors with invalid project directory."
  (should-error (gptel-agent-harness-commands-initialize "/nonexistent/xyz")
                :type 'user-error))

(ert-deftest gptel-agent-harness-test-initialize-creates-buffer ()
  "Test initialize creates a buffer with correct setup."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let* ((temp-file (make-temp-file "init-" nil ".txt"
                                      "Initialize ${path}. $ARGUMENTS"))
           (gptel-agent-harness-commands--initialize-prompt-file temp-file)
           (gptel-send-called nil))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-get-tool)
                     (lambda (name) (intern (format "tool-%s" name))))
                    ((symbol-function 'gptel-agent-update) #'ignore)
                    ((symbol-function 'gptel-send)
                     (lambda () (setq gptel-send-called t)))
                    ((symbol-function 'gptel--update-status)
                     (lambda (&rest _) nil))
                    ((symbol-function 'gptel)
                     (lambda (buf-name &optional _prompt _initial _interactive)
                       (get-buffer-create buf-name))))
            (let ((buf (gptel-agent-harness-commands-initialize temp-dir "extra-arg")))
              (should (buffer-live-p buf))
              (should (string-match-p "gptel-agent-init" (buffer-name buf)))
              (with-current-buffer buf
                (should gptel-use-tools)
                (should (listp gptel-tools))
                (should (equal default-directory temp-dir))
                (should (equal gptel-agent-harness--project-dir temp-dir))
                (should gptel-send-called)
                ;; Buffer should contain the analysis request
                (should (string-match-p "Analyze the repository" (buffer-string))))
              (kill-buffer buf)))
        (delete-file temp-file)))))

;;;; Generate Session Title Guard Tests

(ert-deftest gptel-agent-harness-test-generate-title-guards ()
  "Test `--generate-session-title' early returns without making LLM call."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq-local gptel-mode t)
      ;; Guard 1: no session file cache → no call
      (setq-local gptel-agent-harness--session-file-cache nil)
      (setq-local gptel-agent-harness--session-title nil)
      (setq-local gptel-agent-harness--session-title-pending nil)
      (let ((request-called nil))
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (&rest _) (setq request-called t))))
          (gptel-agent-harness--generate-session-title)
          (should-not request-called)))
      ;; Guard 2: title already set → no call
      (setq-local gptel-agent-harness--session-file-cache "/tmp/test.md")
      (setq-local gptel-agent-harness--session-title "Existing Title")
      (let ((request-called nil))
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (&rest _) (setq request-called t))))
          (gptel-agent-harness--generate-session-title)
          (should-not request-called)))
      ;; Guard 3: pending → no call
      (setq-local gptel-agent-harness--session-title nil)
      (setq-local gptel-agent-harness--session-title-pending t)
      (let ((request-called nil))
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (&rest _) (setq request-called t))))
          (gptel-agent-harness--generate-session-title)
          (should-not request-called)))
      ;; Guard 4: no user message in buffer → no call
      (setq-local gptel-agent-harness--session-title-pending nil)
      ;; Buffer is empty, no gptel 'response text property → no first-msg
      (let ((request-called nil))
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (&rest _) (setq request-called t))))
          (gptel-agent-harness--generate-session-title)
          (should-not request-called))))))

;;;; Session Restore Tool Names Path

(ert-deftest gptel-agent-harness-test-restore-session-tool-names ()
  "Test session restore uses `gptel--tool-names' when no preset is available."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (session-file (expand-file-name "test_260723100000.md" temp-dir)))
      ;; Write a session file with tool names but no preset
      (with-temp-file session-file
        (insert "Session content.\n")
        (insert "\n;; Local Variables:\n")
        (insert ";; gptel-agent-harness--project-dir: \"/tmp/proj\"\n")
        (insert ";; gptel-model: \"gpt-5-mini\"\n")
        (insert ";; gptel--backend-name: \"test-be\"\n")
        (insert ";; gptel--tool-names: (\"Glob\" \"Grep\" \"Read\")\n")
        (insert ";; End:\n"))
      (cl-letf (((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-mode)
                 (lambda (&optional arg)
                   (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t)))))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name) (list :name name :function #'ignore)))
                ((symbol-function 'gptel-get-preset) (lambda (_) nil)))
        (gptel-agent-harness-restore-session session-file)
        ;; Tools should be restored from gptel--tool-names
        (should gptel-use-tools)
        (should (= (length gptel-tools) 3))
        (kill-buffer (current-buffer))))))

;;;; Read Compact Prompt Tests

;;;; Preview Session Tests

(ert-deftest gptel-agent-harness-test-preview-session ()
  "Test `--preview-session' creates a preview buffer with metadata."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((session-file (expand-file-name "test_260723100000.md" temp-dir)))
      (with-temp-file session-file
        (insert "User: hello\nAssistant: hi\n")
        (insert "\n;; Local Variables:\n")
        (insert ";; gptel-model: \"gpt-5\"\n")
        (insert ";; gptel-agent-harness--project-dir: \"/tmp/proj\"\n")
        (insert ";; End:\n"))
      (unwind-protect
          (progn
            (gptel-agent-harness--preview-session session-file)
            (let ((preview-buf (get-buffer "*gptel-session-preview*")))
              (should preview-buf)
              (with-current-buffer preview-buf
                (should (string-match-p "Session Preview" (buffer-string)))
                (should (string-match-p "gpt-5" (buffer-string)))
                (should (string-match-p "/tmp/proj" (buffer-string)))
                (should (string-match-p "User: hello" (buffer-string)))
                ;; Local vars block should be removed from preview
                (should-not (string-match-p ";; Local Variables:" (buffer-string))))))
        (gptel-agent-harness--dismiss-preview)))))

(ert-deftest gptel-agent-harness-test-preview-session-truncation ()
  "Test `--preview-session' truncates long files."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-preview-lines 5)
          (session-file (expand-file-name "long_260723100000.md" temp-dir)))
      (with-temp-file session-file
        (dotimes (i 100)
          (insert (format "Line %d of conversation\n" i))))
      (unwind-protect
          (progn
            (gptel-agent-harness--preview-session session-file)
            (let ((preview-buf (get-buffer "*gptel-session-preview*")))
              (should preview-buf)
              (with-current-buffer preview-buf
                (should (string-match-p "truncated" (buffer-string)))
                ;; Should not contain all 100 lines
                (should-not (string-match-p "Line 99" (buffer-string))))))
        (gptel-agent-harness--dismiss-preview)))))

(ert-deftest gptel-agent-harness-test-dismiss-preview ()
  "Test `--dismiss-preview' kills the preview buffer."
  ;; No preview buffer → no error
  (gptel-agent-harness--dismiss-preview)
  ;; Create and dismiss
  (get-buffer-create "*gptel-session-preview*")
  (should (get-buffer "*gptel-session-preview*"))
  (gptel-agent-harness--dismiss-preview)
  (should-not (get-buffer "*gptel-session-preview*")))

;;;; Cache Module Tests (gptel-agent-harness-cache)

(ert-deftest gptel-agent-harness-test-cache-make-key-canonicalizes ()
  "Test cache key canonicalizes paths but leaves non-paths alone."
  (let ((default-directory "/home/user/project/"))
    ;; Absolute path is preserved
    (let ((key (gptel-agent-harness-cache--make-key 'read '("/tmp/foo.el" 1 50))))
      (should (equal key '(read "/tmp/foo.el" 1 50))))
    ;; Relative path starting with . is expanded
    (let ((key (gptel-agent-harness-cache--make-key 'glob '("*.el" "./src" nil))))
      (should (equal (nth 2 key) "/home/user/project/src")))
    ;; Tilde path is expanded
    (let ((key (gptel-agent-harness-cache--make-key 'read '("~/foo.el" nil nil))))
      (should (string-prefix-p (expand-file-name "~") (nth 1 key))))
    ;; Non-path strings (patterns) are left alone
    (let ((key (gptel-agent-harness-cache--make-key 'grep '("defun.*foo" "/tmp" nil nil))))
      (should (equal (nth 1 key) "defun.*foo")))
    ;; nil values pass through
    (let ((key (gptel-agent-harness-cache--make-key 'read '("/tmp/f.el" nil nil))))
      (should (equal key '(read "/tmp/f.el" nil nil))))))

(ert-deftest gptel-agent-harness-test-cache-store-and-lookup ()
  "Test basic store and lookup operations."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-test-" nil ".el" "content"))
             (key '(read "/tmp/test.el" 1 10)))
        (unwind-protect
            (progn
              ;; Store
              (gptel-agent-harness-cache--store key "file content" temp-file)
              ;; Lookup succeeds
              (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                             "file content"))
              ;; Lookup with wrong key fails
              (should-not (gptel-agent-harness-cache--lookup
                           '(read "/tmp/other.el" 1 10) temp-file)))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-mtime-invalidation ()
  "Test that file modification invalidates cache entry."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((temp-file (make-temp-file "cache-mtime-" nil ".el" "original")))
        (unwind-protect
            (let ((key '(read "test" 1 10)))
              ;; Store with current mtime
              (gptel-agent-harness-cache--store key "original content" temp-file)
              (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                             "original content"))
              ;; Modify the file (changes mtime)
              (sleep-for 0.1)
              (with-temp-file temp-file (insert "modified"))
              ;; Lookup should now return nil (stale)
              (should-not (gptel-agent-harness-cache--lookup key temp-file)))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-ttl-invalidation ()
  "Test that TTL expiry invalidates directory-based cache entries."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-ttl 1)
             (key '(glob "*.el" "/tmp" nil)))
        ;; Store (path is a directory, so TTL is used)
        (gptel-agent-harness-cache--store key "file1.el\nfile2.el" "/tmp")
        (should (equal (gptel-agent-harness-cache--lookup key "/tmp")
                       "file1.el\nfile2.el"))
        ;; Wait for TTL to expire
        (sleep-for 1.1)
        ;; Should be invalidated
        (should-not (gptel-agent-harness-cache--lookup key "/tmp"))))))

(ert-deftest gptel-agent-harness-test-cache-deleted-file-invalidation ()
  "Test that a deleted file invalidates its cache entry."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((temp-file (make-temp-file "cache-del-" nil ".el" "content")))
        (let ((key '(read "test" nil nil)))
          ;; Store
          (gptel-agent-harness-cache--store key "file content" temp-file)
          (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                         "file content"))
          ;; Delete the file
          (delete-file temp-file)
          ;; Should be invalid
          (should-not (gptel-agent-harness-cache--lookup key temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-dedup-same-epoch ()
  "Test deduplication returns short message on repeat access within epoch."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-dedup-" nil ".el" "content"))
             (key '(read "/tmp/f.el" 1 50))
             (gptel-agent-harness-verbose nil))
        (unwind-protect
            (progn
              ;; Store and first get - full result
              (gptel-agent-harness-cache--store key "full file content" temp-file)
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (equal result "full file content")))
              ;; Second get - dedup message
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (string-match-p "\\[Cached: Read" result))
                (should (string-match-p "17 chars" result))))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-epoch-reset ()
  "Test epoch reset clears seen set but preserves cache entries."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-epoch-" nil ".el" "data"))
             (key '(read "/tmp/f.el" 1 50))
             (gptel-agent-harness-verbose nil))
        (unwind-protect
            (progn
              ;; Store and access (marks as seen)
              (gptel-agent-harness-cache--store key "the data" temp-file)
              (gptel-agent-harness-cache--get key temp-file)
              ;; Confirm it's in seen
              (should (gethash key gptel-agent-harness-cache--seen))
              ;; Reset epoch
              (gptel-agent-harness-cache--reset-epoch)
              ;; Seen is cleared
              (should-not (gethash key gptel-agent-harness-cache--seen))
              ;; Cache entry persists - next get returns full result
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (equal result "the data"))))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-write-through-invalidation ()
  "Test that editing a file invalidates related cache entries."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((dir "/tmp/project/src/")
             (file (concat dir "foo.el"))
             (key-read (list 'read file 1 50))
             (key-grep (list 'grep "pattern" dir nil nil))
             (key-unrelated (list 'read "/tmp/other/bar.el" 1 10)))
        ;; Populate cache
        (puthash key-read
                 (list :result "foo content" :mtime nil :timestamp (float-time))
                 gptel-agent-harness-cache--table)
        (puthash key-grep
                 (list :result "grep results" :mtime nil :timestamp (float-time))
                 gptel-agent-harness-cache--table)
        (puthash key-unrelated
                 (list :result "other content" :mtime nil :timestamp (float-time))
                 gptel-agent-harness-cache--table)
        ;; Mark as seen
        (puthash key-read t gptel-agent-harness-cache--seen)
        (puthash key-grep t gptel-agent-harness-cache--seen)
        (puthash key-unrelated t gptel-agent-harness-cache--seen)
        ;; Invalidate
        (gptel-agent-harness-cache--invalidate-path file)
        ;; foo.el: invalidated (exact match)
        (should-not (gethash key-read gptel-agent-harness-cache--table))
        (should-not (gethash key-read gptel-agent-harness-cache--seen))
        ;; grep on parent dir: invalidated (dir prefix match)
        (should-not (gethash key-grep gptel-agent-harness-cache--table))
        (should-not (gethash key-grep gptel-agent-harness-cache--seen))
        ;; Unrelated: preserved
        (should (gethash key-unrelated gptel-agent-harness-cache--table))
        (should (gethash key-unrelated gptel-agent-harness-cache--seen))))))

(ert-deftest gptel-agent-harness-test-cache-cacheable-p ()
  "Test `--cacheable-p' filters empty and error results."
  (should (gptel-agent-harness-cache--cacheable-p "file content here"))
  (should (gptel-agent-harness-cache--cacheable-p "1:match\n2:match"))
  (should-not (gptel-agent-harness-cache--cacheable-p ""))
  (should-not (gptel-agent-harness-cache--cacheable-p nil))
  (should-not (gptel-agent-harness-cache--cacheable-p "Error: File not readable"))
  (should-not (gptel-agent-harness-cache--cacheable-p
               "Glob failed with exit code 1\n.STDOUT:\n\n")))

(ert-deftest gptel-agent-harness-test-cache-eviction ()
  "Test oldest entry is evicted when cache reaches max capacity."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((gptel-agent-harness-cache-max-entries 3))
        (gptel-agent-harness-cache--store '(a) "result-a" "/tmp")
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(b) "result-b" "/tmp")
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(c) "result-c" "/tmp")
        (should (= (hash-table-count gptel-agent-harness-cache--table) 3))
        ;; Add one more - oldest (a) should be evicted
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(d) "result-d" "/tmp")
        (should (= (hash-table-count gptel-agent-harness-cache--table) 3))
        (should-not (gethash '(a) gptel-agent-harness-cache--table))
        (should (gethash '(b) gptel-agent-harness-cache--table))
        (should (gethash '(c) gptel-agent-harness-cache--table))
        (should (gethash '(d) gptel-agent-harness-cache--table))))))

(ert-deftest gptel-agent-harness-test-cache-stats ()
  "Test cache statistics are tracked correctly."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-verbose nil)
             (temp-file (make-temp-file "cache-stats-" nil ".el" "x"))
             (key '(read "/tmp/stats.el" 1 10)))
        (unwind-protect
            (progn
              ;; Reset stats
              (dolist (k '(:hits :misses :dedups :invalidations))
                (puthash k 0 gptel-agent-harness-cache--stats))
              ;; Store + first get = hit
              (gptel-agent-harness-cache--store key "content" temp-file)
              (gptel-agent-harness-cache--get key temp-file)
              (should (= (gethash :hits gptel-agent-harness-cache--stats) 1))
              ;; Second get = dedup
              (gptel-agent-harness-cache--get key temp-file)
              (should (= (gethash :dedups gptel-agent-harness-cache--stats) 1))
              ;; Modify file = invalidation on next lookup
              (sleep-for 0.1)
              (with-temp-file temp-file (insert "changed"))
              (gptel-agent-harness-cache--lookup key temp-file)
              (should (= (gethash :invalidations gptel-agent-harness-cache--stats) 1)))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-read-advice ()
  "Test read advice caches, deduplicates, and skips when disabled."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (call-count 0)
             (temp-file (make-temp-file "cache-read-" nil ".el" "line1\nline2\n"))
             (fake-read (lambda (filename &optional _start _end)
                          (cl-incf call-count)
                          (format "content of %s" filename))))
        (unwind-protect
            (progn
              ;; First call: miss, invokes orig-fn
              (let ((r (gptel-agent-harness-cache--read-advice
                        fake-read temp-file 1 10)))
                (should (string-match-p "content of" r))
                (should (= call-count 1)))
              ;; Second call: dedup, no orig-fn
              (let ((r (gptel-agent-harness-cache--read-advice
                        fake-read temp-file 1 10)))
                (should (string-match-p "\\[Cached:" r))
                (should (= call-count 1)))
              ;; With cache disabled: always calls orig-fn
              (let ((gptel-agent-harness-cache-enabled nil))
                (gptel-agent-harness-cache--read-advice fake-read temp-file 1 10)
                (should (= call-count 2))))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-glob-advice ()
  "Test glob advice caches and deduplicates."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (call-count 0)
             (fake-glob (lambda (_pattern &optional _path _depth)
                          (cl-incf call-count)
                          "/tmp/a.el\n/tmp/b.el\n")))
        ;; First call
        (let ((r (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)))
          (should (string-match-p "a\\.el" r))
          (should (= call-count 1)))
        ;; Second call: dedup
        (let ((r (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)))
          (should (string-match-p "\\[Cached:" r))
          (should (= call-count 1)))))))

(ert-deftest gptel-agent-harness-test-cache-grep-advice ()
  "Test grep advice caches and deduplicates."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (call-count 0)
             (fake-grep (lambda (_regex _path &optional _glob _ctx)
                          (cl-incf call-count)
                          "5:match here\n")))
        ;; First call
        (let ((r (gptel-agent-harness-cache--grep-advice
                  fake-grep "match" "/tmp/file.el" nil nil)))
          (should (string-match-p "match here" r))
          (should (= call-count 1)))
        ;; Second call: dedup
        (let ((r (gptel-agent-harness-cache--grep-advice
                  fake-grep "match" "/tmp/file.el" nil nil)))
          (should (string-match-p "\\[Cached:" r))
          (should (= call-count 1)))))))

(ert-deftest gptel-agent-harness-test-cache-skips-error-results ()
  "Test that error results from tool calls are not cached."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (call-count 0)
             (fake-glob (lambda (_pattern &optional _path _depth)
                          (cl-incf call-count)
                          "Glob failed with exit code 1\n.STDOUT:\n\n")))
        ;; First call: error result, not cached
        (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)
        (should (= call-count 1))
        ;; Second call: still invokes orig-fn (not cached)
        (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)
        (should (= call-count 2))))))

(ert-deftest gptel-agent-harness-test-cache-lifecycle ()
  "Test cache setup creates tables, clear empties them, teardown nils them."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      ;; Setup
      (should-not gptel-agent-harness-cache--table)
      (should-not gptel-agent-harness-cache--seen)
      (gptel-agent-harness-cache--setup)
      (should (hash-table-p gptel-agent-harness-cache--table))
      (should (hash-table-p gptel-agent-harness-cache--seen))
      ;; Populate and clear
      (puthash '(test) '(:result "x" :timestamp 0) gptel-agent-harness-cache--table)
      (puthash '(test) t gptel-agent-harness-cache--seen)
      (should (= (hash-table-count gptel-agent-harness-cache--table) 1))
      (should (= (hash-table-count gptel-agent-harness-cache--seen) 1))
      (gptel-agent-harness-cache-clear)
      (should (= (hash-table-count gptel-agent-harness-cache--table) 0))
      (should (= (hash-table-count gptel-agent-harness-cache--seen) 0))
      ;; Teardown
      (gptel-agent-harness-cache--teardown)
      (should-not gptel-agent-harness-cache--table)
      (should-not gptel-agent-harness-cache--seen))))

(ert-deftest gptel-agent-harness-test-cache-enable-disable ()
  "Test enable adds advice, disable removes it."
  (unwind-protect
      (progn
        (gptel-agent-harness-cache-enable)
        (should (advice-member-p #'gptel-agent-harness-cache--read-advice
                                 'gptel-agent--read-file-lines))
        (should (advice-member-p #'gptel-agent-harness-cache--glob-advice
                                 'gptel-agent--glob))
        (should (advice-member-p #'gptel-agent-harness-cache--grep-advice
                                 'gptel-agent--grep))
        (should (advice-member-p #'gptel-agent-harness-cache--after-edit
                                 'gptel-agent--edit-files))
        (should (advice-member-p #'gptel-agent-harness-cache--after-write
                                 'gptel-agent--write-file))
        (should (advice-member-p #'gptel-agent-harness-cache--after-insert
                                 'gptel-agent--insert-in-file))
        (gptel-agent-harness-cache-disable)
        (should-not (advice-member-p #'gptel-agent-harness-cache--read-advice
                                     'gptel-agent--read-file-lines))
        (should-not (advice-member-p #'gptel-agent-harness-cache--glob-advice
                                     'gptel-agent--glob))
        (should-not (advice-member-p #'gptel-agent-harness-cache--grep-advice
                                     'gptel-agent--grep)))
    (gptel-agent-harness-cache-disable)))

(provide 'gptel-agent-harness-test)
;;; gptel-agent-harness-test.el ends here
