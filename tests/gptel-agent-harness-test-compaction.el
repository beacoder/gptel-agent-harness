;;; gptel-agent-harness-test-compaction.el --- Compaction tests -*- lexical-binding: t -*-
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
;; ERT tests for context compaction: the full multi-cycle
;; `--compact' flow, frame helpers (`--strip-compact-prefix',
;; `--insert-compact-frame'), the compact-buffer command, and the
;; commands-module compact callback/request paths.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

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

;;;; Commands Module Compact Tests

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

(ert-deftest gptel-agent-harness-test-commands-compact-sends-request ()
  "`commands-compact' sends buffer content with the compact prompt."
  (let ((prompt-file (make-temp-file "compact-" nil ".txt" "compact instructions"))
        (gptel-agent-harness-compact-prompt-file nil)
        (captured-content nil)
        (captured-system nil)
        (post-fn-called nil))
    (unwind-protect
        (progn
          (setq gptel-agent-harness-compact-prompt-file prompt-file)
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (content &rest args)
                       (setq captured-content content)
                       (setq captured-system (plist-get args :system))
                       (gptel-make-fsm :info (list :buffer (current-buffer)))))
                    ((symbol-function 'gptel--update-status)
                     (lambda (&rest _) nil)))
            (with-temp-buffer
              (setq-local gptel-mode t)
              (insert "buffer content to compact")
              (let ((fsm (gptel-agent-harness-commands-compact
                          (lambda (&optional _info) (setq post-fn-called t)))))
                (should (equal captured-content "buffer content to compact"))
                (should (equal captured-system "compact instructions"))
                ;; The post-func is stored in the FSM info and run by the
                ;; callback machinery once compaction completes.
                (gptel-agent-harness-commands--run-post-funcs
                 (gptel-fsm-info fsm))
                (should post-fn-called)))
            ;; A buffer-local compact prompt wins over the file.
            (setq captured-system nil)
            (with-temp-buffer
              (setq-local gptel-mode t)
              (setq-local gptel-agent-compact-prompt "local prompt")
              (gptel-agent-harness-commands-compact)
              (should (equal captured-system "local prompt")))))
      (delete-file prompt-file))))

(provide 'gptel-agent-harness-test-compaction)

;; Local Variables:
;; package-lint-main-file: "tests/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-compaction.el ends here
