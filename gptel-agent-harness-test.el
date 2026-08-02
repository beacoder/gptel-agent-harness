;;; gptel-agent-harness-test.el --- Tests for gptel-agent-harness -*- lexical-binding: t -*-
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
;; ERT tests for the gptel-agent-harness core: completion supervision,
;; context management, compaction, session persistence, and commands.
;;
;; Tool-layer tests (enhanced glob/grep/Question tools, result cache)
;; and module tests (safety, tools, cache) live in
;; gptel-agent-harness-extra-test.el.
;;
;; Run with:
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

;;;; Build/Plan Mode Tests

(defun gptel-agent-harness-test--position-aware-inject-prompt
    (_backend data new-prompt &optional position)
  "Test stub for `gptel--inject-prompt' honoring POSITION."
  (let* ((msgs (or (plist-get data :messages) []))
         (new (if (keywordp (car-safe new-prompt))
                  (list new-prompt)
                new-prompt))
         (pos (or position (length msgs))))
    (plist-put data :messages
               (vconcat (substring msgs 0 pos) new (substring msgs pos)))))

(ert-deftest gptel-agent-harness-test-mode-switch-queues-prompts ()
  "Switching modes queues the correct prompts for the next request."
  (gptel-agent-harness-test--with-temp-dir proj-dir
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--project-dir proj-dir)
        ;; Default is build mode with an empty queue.
        (should (eq gptel-agent-harness--mode 'build))
        (should (null gptel-agent-harness--pending-prompts))
        ;; Switch to plan → plan.txt + plan-mode.txt queued.
        (gptel-agent-harness-toggle-mode)
        (should (eq gptel-agent-harness--mode 'plan))
        (should (= 2 (length gptel-agent-harness--pending-prompts)))
        (should (string-match-p "Plan Mode"
                                (car gptel-agent-harness--pending-prompts)))
        (should (string-match-p "Plan mode is active"
                                (nth 1 gptel-agent-harness--pending-prompts)))
        ;; Plan file created and ${planInfo} replaced with its path.
        (let ((plan-file (expand-file-name "PLAN.md" proj-dir)))
          (should (file-exists-p plan-file))
          (should (equal gptel-agent-harness--plan-file plan-file))
          (should (string-match-p (regexp-quote plan-file)
                                  (nth 1 gptel-agent-harness--pending-prompts)))
          (should-not (string-match-p "\\${planInfo}"
                                      (nth 1 gptel-agent-harness--pending-prompts))))
        ;; Switch back to build → only build-switch.txt queued.
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

(ert-deftest gptel-agent-harness-test-inject-pending-top-level-only ()
  "Without backend info (prompt still being assembled) nothing is
injected, and the queue is preserved for the top-level request."
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
                     :messages messages)))
          (plist-put (gptel-fsm-info fsm) :backend 'test-backend)
          (with-current-buffer buf
            (setq-local gptel-agent-harness--project-dir proj-dir)
            (gptel-agent-harness-set-mode 'plan))
          (gptel-agent-harness--inject-pending-prompts fsm)
          (let ((final (plist-get (plist-get (gptel-fsm-info fsm) :data)
                                  :messages)))
            (should (= 2 (length final)))
            (let ((reminder (plist-get (aref final 0) :content)))
              (should (string-match-p "READ-ONLY" reminder))
              (should (string-match-p (regexp-quote
                                       (expand-file-name "PLAN.md" proj-dir))
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
  "Return the last non-nudge user message text across content shapes.
Verifies plain strings, multimodal vector/list content, and Gemini
\":parts\" content all reduce to an insertable plain string."
  (gptel-agent-harness-test--with-buffer buf
    ;; Plain string content: returns last non-nudge user message
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
      (should-not (gptel-agent-harness--last-user-request fsm)))
    ;; Multimodal (OpenAI) vector content → text, ignoring image parts
    (let* ((messages (vector
                      (list :role "user"
                            :content (vector '(:type "text" :text "describe ")
                                             '(:type "image_url"
                                               :image_url (:url "data:..."))
                                             '(:type "text" :text "this image")))
                      (list :role "assistant" :content "reply")))
           (fsm (gptel-agent-harness-test--make-fsm buf :messages messages))
           (req (gptel-agent-harness--last-user-request fsm)))
      (should (stringp req))
      (should (equal req "describe this image")))
    ;; Gemini-style :contents with :parts and no :content
    (let* ((messages (vector
                      (list :role "user"
                            :parts (vector '(:text "gemini question")))))
           (fsm (gptel-agent-harness-test--make-fsm buf :contents messages))
           (req (gptel-agent-harness--last-user-request fsm)))
      (should (stringp req))
      (should (equal req "gemini question")))))

(ert-deftest gptel-agent-harness-test-content-to-text ()
  "Test `--content-to-text' reduces multimodal content to plain text."
  ;; Plain string passes through
  (should (equal (gptel-agent-harness--content-to-text "hello") "hello"))
  ;; nil → nil
  (should-not (gptel-agent-harness--content-to-text nil))
  ;; A plain empty string passes through as-is (caller guards separately)
  (should (equal (gptel-agent-harness--content-to-text "") ""))
  ;; OpenAI multipart vector: gather :text, ignore image parts
  (should (equal (gptel-agent-harness--content-to-text
                  (vector '(:type "text" :text "look at ")
                          '(:type "image_url" :image_url (:url "data:..."))
                          '(:type "text" :text "this")))
                 "look at this"))
  ;; Anthropic-style content-block list
  (should (equal (gptel-agent-harness--content-to-text
                  (list '(:type "text" :text "hi")
                        '(:type "image" :source (:data "..."))))
                 "hi"))
  ;; Bare strings in a list
  (should (equal (gptel-agent-harness--content-to-text (list "a" "b")) "ab"))
  ;; No text parts → nil
  (should-not (gptel-agent-harness--content-to-text
               (vector '(:type "image_url" :image_url (:url "x"))))))

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
                 "spaced-out"))
  ;; Embedded newlines collapsed
  (should (equal (gptel-agent-harness--sanitize-title "Fix the bug\nin session handling")
                 "Fix-the-bug-in-session-handling"))
  ;; Multiple newlines and carriage returns
  (should (equal (gptel-agent-harness--sanitize-title "Line one\r\n\r\nLine two")
                 "Line-one-Line-two")))

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
  "Test review command creates a buffer, sets system prompt."
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
            (should (string-match-p "Review the requested code changes" (thing-at-point 'line t))))
          (kill-buffer buf))
        ;; Without arguments (nil)
        (let ((buf (gptel-agent-harness-commands-review nil)))
          (with-current-buffer buf
            (goto-char (point-max))
            (forward-line -1)
            (should (string-match-p "Review the requested code changes" (thing-at-point 'line t))))
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

;;;; Custom Command Auto-Discovery Tests

(ert-deftest gptel-agent-harness-test-custom-name-sanitize ()
  "Test custom command name derivation is symbol-safe."
  (should (equal (gptel-agent-harness-commands--custom-name "/x/Explain.txt")
                 "explain"))
  (should (equal (gptel-agent-harness-commands--custom-name "/x/Fix Bug!.txt")
                 "fix-bug"))
  (should (equal (gptel-agent-harness-commands--custom-name "/x/write_docs.txt")
                 "write-docs")))

(ert-deftest gptel-agent-harness-test-custom-load-discovers-files ()
  "Test `load-custom' defines one command per .txt file and ignores others."
  (gptel-agent-harness-test--with-temp-dir dir
    ;; Two prompt files plus a non-txt file that must be ignored.  Names are
    ;; unique so they never collide with load-time example commands.
    (with-temp-file (expand-file-name "tfoo.txt" dir) (insert "Foo ${path}."))
    (with-temp-file (expand-file-name "tbar.txt" dir) (insert "Bar: $ARGUMENTS"))
    (with-temp-file (expand-file-name "notes.md" dir) (insert "ignore me"))
    (let ((gptel-agent-harness-commands--custom-commands nil))
      (let ((defined (gptel-agent-harness-commands-load-custom dir)))
        (unwind-protect
            (progn
              (should (= (length defined) 2))
              (should (memq 'gptel-agent-harness-commands-tfoo defined))
              (should (memq 'gptel-agent-harness-commands-tbar defined))
              (should (commandp 'gptel-agent-harness-commands-tfoo))
              (should (commandp 'gptel-agent-harness-commands-tbar))
              (should-not (fboundp 'gptel-agent-harness-commands-notes)))
          (fmakunbound 'gptel-agent-harness-commands-tfoo)
          (fmakunbound 'gptel-agent-harness-commands-tbar))))))

(ert-deftest gptel-agent-harness-test-custom-does-not-clobber-builtin ()
  "Test discovery refuses to overwrite an existing non-custom command."
  (gptel-agent-harness-test--with-temp-dir dir
    ;; A file named review.txt would map to the built-in review command.
    (with-temp-file (expand-file-name "review.txt" dir) (insert "custom review"))
    (let ((gptel-agent-harness-commands--custom-commands nil)
          (orig (symbol-function 'gptel-agent-harness-commands-review)))
      (let ((defined (gptel-agent-harness-commands-load-custom dir)))
        ;; Nothing defined, and the built-in review is untouched.
        (should (null defined))
        (should (eq (symbol-function 'gptel-agent-harness-commands-review) orig))))))

(ert-deftest gptel-agent-harness-test-custom-command-runs ()
  "Test an invoked custom command spawns a buffer with substituted prompt."
  (declare-function gptel-agent-harness-commands-trun "gptel-agent-harness" (&rest _))
  (gptel-agent-harness-test--with-temp-dir dir
    (with-temp-file (expand-file-name "trun.txt" dir)
      (insert "Explain code in ${path}. Focus: $ARGUMENTS"))
    (let ((gptel-agent-harness-commands--custom-commands nil)
          (gptel-send-called nil))
      (gptel-agent-harness-commands-load-custom dir)
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-get-tool)
                     (lambda (name) (intern (format "tool-%s" name))))
                    ((symbol-function 'gptel-agent-update) #'ignore)
                    ((symbol-function 'gptel-send)
                     (lambda () (setq gptel-send-called t)))
                    ((symbol-function 'gptel--update-status)
                     (lambda (&rest _) nil))
                    ((symbol-function 'gptel)
                     (lambda (buf-name &optional _p _i _int)
                       (get-buffer-create buf-name))))
            (let ((buf (gptel-agent-harness-commands-trun "concurrency")))
              (should (buffer-live-p buf))
              (should (string-match-p "gptel-agent-trun" (buffer-name buf)))
              (with-current-buffer buf
                (should gptel-use-tools)
                (should (eq gptel-temperature 0))
                (should (string-match-p "Explain code in" gptel-system-prompt))
                (should (string-match-p "Focus: concurrency" gptel-system-prompt))
                (should gptel-send-called)
                (should (string-match-p "Proceed with the task"
                                        (buffer-string))))
              (kill-buffer buf)))
        (fmakunbound 'gptel-agent-harness-commands-trun)))))

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

(ert-deftest gptel-agent-harness-test-restore-session-local-vars-in-content ()
  "Restore must use the trailing local-vars block, not an earlier
occurrence quoted in the conversation.
Conversations can contain \";; Local Variables:\" inside quoted source
code; parsing the first match truncates the conversation and discards
all saved state."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (session-file (expand-file-name "test_260723100000.md" temp-dir)))
      ;; Conversation content that itself quotes a local-vars block
      (with-temp-file session-file
        (insert "Conversation start.\n")
        (insert "```elisp\n")
        (insert ";; Local Variables:\n")
        (insert ";; package-lint-main-file: \"foo.el\"\n")
        (insert ";; End:\n")
        (insert "```\n")
        (insert "Conversation end.\n")
        ;; The real trailing block appended by auto-save
        (insert "\n;; Local Variables:\n")
        (insert ";; gptel-agent-harness--project-dir: \"/tmp/proj\"\n")
        (insert ";; gptel-model: \"gpt-5-mini\"\n")
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
        ;; Full conversation preserved — nothing truncated
        (should (string-match-p "Conversation start" (buffer-string)))
        (should (string-match-p "Conversation end" (buffer-string)))
        ;; Trailing block stripped, quoted one kept
        (should (string-match-p "package-lint-main-file" (buffer-string)))
        (should-not (string-match-p "^;; End:\n\\'" (buffer-string)))
        ;; Local variables from the trailing block applied
        (should (equal gptel-agent-harness--project-dir "/tmp/proj"))
        (should (equal gptel-model "gpt-5-mini"))
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

(provide 'gptel-agent-harness-test)
;;; gptel-agent-harness-test.el ends here
