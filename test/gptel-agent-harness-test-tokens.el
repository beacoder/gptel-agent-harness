;;; gptel-agent-harness-test-tokens.el --- Token estimation tests -*- lexical-binding: t -*-
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
;; ERT tests for token estimation: CJK-aware counting, model/context
;; window lookup, per-backend payload estimation (OpenAI, Anthropic,
;; Gemini, reasoning/tool-call variants), calibration, and the content
;; extractors (`--content-to-text', `--last-user-request',
;; `--extract-content', `--extract-system-content'), including their
;; malformed-data behavior.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Token Estimation Tests

(ert-deftest gptel-agent-harness-test-cjk-char-p ()
  "Test CJK character detection."
  (should (gptel-agent-harness--cjk-char-p ?中))
  (should (gptel-agent-harness--cjk-char-p ?あ))
  (should (gptel-agent-harness--cjk-char-p ?Ａ))
  (should-not (gptel-agent-harness--cjk-char-p ?A))
  (should-not (gptel-agent-harness--cjk-char-p ?é)))

(ert-deftest gptel-agent-harness-test-cjk-char-p-ranges ()
  "Test CJK detection across all covered code ranges."
  ;; CJK compat ideographs
  (should (gptel-agent-harness--cjk-char-p #xf900))
  (should (gptel-agent-harness--cjk-char-p #xfaff))
  ;; Full-width forms
  (should (gptel-agent-harness--cjk-char-p #xff00))
  (should (gptel-agent-harness--cjk-char-p #xffef))
  ;; CJK extensions B–F boundaries
  (should (gptel-agent-harness--cjk-char-p #x20000))
  (should (gptel-agent-harness--cjk-char-p #x2fa1f))
  ;; Outside every range
  (should-not (gptel-agent-harness--cjk-char-p #x10000))
  (should-not (gptel-agent-harness--cjk-char-p #x2fa20))
  (should-not (gptel-agent-harness--cjk-char-p #x2fff))
  (should-not (gptel-agent-harness--cjk-char-p 0)))

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

;;;; Context Token Estimation from FSM Data

(ert-deftest gptel-agent-harness-test-context-tokens-from-data ()
  "Test token estimation from full prompt payload.
Covers plain string content (OpenAI-style) and a list of `:text' parts
\(Anthropic-style structured content)."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "system prompt here"
                   :messages (vector
                              (list :role "user" :content "hello world")
                              (list :role "assistant" :content "hi there")
                              (list :role "user" :content "do something")))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 12))))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "sys"
                   :messages (vector
                              (list :role "assistant"
                                    :content (list (list :text "part one")
                                                   (list :text "part two")))))))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 5))))))

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

;;;; Content Extractors

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

;;;; Malformed Data Defensiveness

(ert-deftest gptel-agent-harness-test-context-tokens-from-data-malformed ()
  "`--context-tokens-from-data' never signals on malformed data."
  (let ((gptel-agent-harness-verbose nil))
    (gptel-agent-harness-test--with-buffer buf
      ;; Non-plist :data (buffer/string) → 0
      (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                    :messages (vector (list :role "user" :content "hi"))))
             (info (gptel-fsm-info fsm)))
        (plist-put info :data (current-buffer))
        (should (= (gptel-agent-harness--context-tokens-from-data fsm) 0)))
      ;; :messages as a list (not vector) → no error
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :messages (list (list :role "user" :content "hi")))))
        (should (integerp (gptel-agent-harness--context-tokens-from-data fsm))))
      ;; :messages vector with string/number entries → no error
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :messages (vector "raw string" 42
                                     (list :role "user" :content "hi")))))
        (should (integerp (gptel-agent-harness--context-tokens-from-data fsm))))
      ;; :toolConfig as a string → no error
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :messages (vector (list :role "user" :content "hi"))
                   :toolConfig "x")))
        (should (integerp (gptel-agent-harness--context-tokens-from-data fsm))))
      ;; :tool_calls as a string → no error
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :messages (vector (list :role "assistant"
                                           :content nil
                                           :tool_calls "str")))))
        (should (integerp (gptel-agent-harness--context-tokens-from-data fsm)))))))

(ert-deftest gptel-agent-harness-test-last-user-request-malformed ()
  "`--last-user-request' returns nil on malformed data, never signals."
  (gptel-agent-harness-test--with-buffer buf
    ;; Non-plist :data → nil
    (let* ((fsm (gptel-agent-harness-test--make-fsm buf
                  :messages (vector (list :role "user" :content "hi"))))
           (info (gptel-fsm-info fsm)))
      (plist-put info :data "oops")
      (should-not (gptel-agent-harness--last-user-request fsm)))
    ;; :messages as a list → nil
    (let ((fsm (gptel-agent-harness-test--make-fsm buf
                 :messages (list (list :role "user" :content "hi")))))
      (should-not (gptel-agent-harness--last-user-request fsm)))
    ;; :messages vector with non-plist entries → nil, no error
    (let ((fsm (gptel-agent-harness-test--make-fsm buf
                 :messages (vector "raw" 42))))
      (should-not (gptel-agent-harness--last-user-request fsm)))))

(ert-deftest gptel-agent-harness-test-extract-content-malformed ()
  "Content extractors never signal on malformed parts."
  (with-temp-buffer
    (gptel-agent-harness--extract-content (vector 42 "str" '(:text "ok")))
    (should (string-match-p "ok" (buffer-string))))
  (with-temp-buffer
    (gptel-agent-harness--extract-content (list 42 "str" '(:text "ok")))
    (should (string-match-p "ok" (buffer-string))))
  (with-temp-buffer
    (gptel-agent-harness--extract-content (list (list :text "a") (list :text "b")))
    (should (string-match-p "ab" (buffer-string))))
  (with-temp-buffer
    (gptel-agent-harness--extract-content 42)
    (should (string-match-p "42" (buffer-string)))))

(ert-deftest gptel-agent-harness-test-content-to-text-malformed ()
  "`--content-to-text' never signals on malformed content."
  ;; Non-plist parts are skipped; bare strings are still collected.
  (should (equal (gptel-agent-harness--content-to-text (vector 42 "str")) "str"))
  (should (equal (gptel-agent-harness--content-to-text (list 42 "str")) "str"))
  ;; Non-sequence/non-string content → nil
  (should-not (gptel-agent-harness--content-to-text 42))
  ;; Non-plist part in a list is skipped, text still gathered
  (should (equal (gptel-agent-harness--content-to-text (list (list :text "a") 42))
                 "a")))

;;;; Token-estimation / extractor edge cases

(ert-deftest gptel-agent-harness-test-extract-system-content-forms ()
  "`--extract-system-content' handles vector and list system prompts.
Also renders malformed parts defensively without signalling."
  (with-temp-buffer
    (gptel-agent-harness--extract-system-content
     [( :type "text" :text "vec part one") (:type "text" :text "vec part two")])
    (should (string-match-p "vec part one" (buffer-string)))
    (should (string-match-p "vec part two" (buffer-string))))
  (with-temp-buffer
    (gptel-agent-harness--extract-system-content
     (list "list string" (list :text "list part")))
    (should (string-match-p "list string" (buffer-string)))
    (should (string-match-p "list part" (buffer-string))))
  ;; Malformed system never signals.
  (with-temp-buffer
    (gptel-agent-harness--extract-system-content
     (list :parts (vector 42 "str")))
    (should (string-match-p "42" (buffer-string))))
  (with-temp-buffer
    (gptel-agent-harness--extract-system-content 42)
    (should (string-empty-p (buffer-string)))))

(ert-deftest gptel-agent-harness-test-context-tokens-verbose-debug-buffer ()
  "Verbose mode logs the token estimation to the debug buffer."
  (let ((gptel-agent-harness-verbose t))
    (gptel-agent-harness-test--with-buffer buf
      (let ((fsm (gptel-agent-harness-test--make-fsm buf
                   :system "sys"
                   :tools (vector (list :type "function" :function (list :name "t")))
                   :messages (vector (list :role "user" :content "hello")))))
        (unwind-protect
            (progn
              (should (> (gptel-agent-harness--context-tokens-from-data fsm) 0))
              (let ((dbg (get-buffer "*gptel-agent-harness-debug*")))
                (should dbg)
                (with-current-buffer dbg
                  (should (string-match-p "Context Token Estimation" (buffer-string)))
                  (should (string-match-p "Total estimated tokens" (buffer-string)))
                  (should (string-match-p "\\[system\\]" (buffer-string)))
                  (should (string-match-p "\\[user\\]" (buffer-string)))
                  (should (string-match-p "tools" (buffer-string))))))
          (kill-buffer "*gptel-agent-harness-debug*"))))))

(provide 'gptel-agent-harness-test-tokens)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-tokens.el ends here
