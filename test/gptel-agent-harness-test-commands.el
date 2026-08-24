;;; gptel-agent-harness-test-commands.el --- Commands module tests -*- lexical-binding: t -*-
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
;; ERT tests for the commands module (gptel-agent-harness-commands):
;; prompt file readers, placeholder substitution, the review/summary/
;; initialize commands, and custom command auto-discovery.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Commands Module Tests

(ert-deftest gptel-agent-harness-test-read-prompt-files ()
  "Test prompt file readers handle existing and missing files."
  ;; Review prompt
  (let ((temp-file (make-temp-file "review-" nil ".txt" "test review prompt")))
    (let ((gptel-agent-harness-commands--review-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-review-prompt)
                     "test review prompt")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--review-prompt-file "/nonexistent/review.md"))
    (should-error (gptel-agent-harness-commands--read-review-prompt)))
  ;; Initialize prompt
  (let ((temp-file (make-temp-file "initialize-" nil ".txt" "initialize prompt")))
    (let ((gptel-agent-harness-commands--initialize-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-initialize-prompt)
                     "initialize prompt")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--initialize-prompt-file "/nonexistent/init.md"))
    (should-error (gptel-agent-harness-commands--read-initialize-prompt)))
  ;; Summary prompt
  (let ((temp-file (make-temp-file "summary-" nil ".txt" "Summarize this.")))
    (let ((gptel-agent-harness-commands--summary-prompt-file temp-file))
      (should (equal (gptel-agent-harness-commands--read-summary-prompt)
                     "Summarize this.")))
    (delete-file temp-file))
  (let ((gptel-agent-harness-commands--summary-prompt-file "/nonexistent/summary.md"))
    (should-error (gptel-agent-harness-commands--read-summary-prompt)))
  ;; Compact prompt
  (let ((temp-file (make-temp-file "compact-" nil ".txt" "compact instructions")))
    (unwind-protect
        (let ((gptel-agent-harness-compact-prompt-file temp-file))
          (should (equal (gptel-agent-harness--read-compact-prompt)
                         "compact instructions")))
      (delete-file temp-file)))
  (let ((gptel-agent-harness-compact-prompt-file "/nonexistent/compact.md"))
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

(ert-deftest gptel-agent-harness-test-session-tolerates-unknown-tools ()
  "A tool name that is not registered degrades the tool set, not the command.

`gptel-get-tool' signals for an unknown name, and the harness's own
tools (Question, PlanExit) only exist while `gptel-agent-harness-mode' is
enabled — but the commands are autoloaded and can run before that.

`debug-on-error' is bound to t on purpose.  The production code must use
a plain `condition-case': `with-demoted-errors' expands to
`condition-case-unless-debug' and re-signals when `debug-on-error' is
set, so the degradation would silently disappear for anyone debugging.
Emacs 29's ERT binds `debug-on-error' to t around every test body while
Emacs 30's uses `handler-bind', so without this explicit binding the
regression is invisible on Emacs 30."
  (let ((temp-file (make-temp-file "review-" nil ".txt" "Reviewer at ${path}.")))
    (let ((gptel-agent-harness-commands--review-prompt-file temp-file)
          (gptel-agent-harness--default-tools '("Glob" "NoSuchTool" "Grep"))
          (debug-on-error t))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) ""))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name)
                   (if (equal name "NoSuchTool")
                       (error "No tool matches for %S" name)
                     (intern (format "tool-%s" name)))))
                ((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-send) #'ignore))
        (let ((buf (gptel-agent-harness-commands-review nil)))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should gptel-use-tools)
            ;; The unknown name is dropped; the resolvable ones survive.
            (should (equal gptel-tools '(tool-Glob tool-Grep))))
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
  (should (equal (gptel-agent-harness-commands--custom-name "/x/Explain.md")
                 "explain"))
  (should (equal (gptel-agent-harness-commands--custom-name "/x/Fix Bug!.md")
                 "fix-bug"))
  (should (equal (gptel-agent-harness-commands--custom-name "/x/write_docs.md")
                 "write-docs")))

(ert-deftest gptel-agent-harness-test-custom-load-discovers-files ()
  "Test `load-custom' defines one command per .md file and ignores others."
  (gptel-agent-harness-test--with-temp-dir dir
    ;; Two prompt files plus a non-md file that must be ignored.  Names are
    ;; unique so they never collide with load-time example commands.
    (with-temp-file (expand-file-name "tfoo.md" dir) (insert "Foo ${path}."))
    (with-temp-file (expand-file-name "tbar.md" dir) (insert "Bar: $ARGUMENTS"))
    (with-temp-file (expand-file-name "notes.txt" dir) (insert "ignore me"))
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
    ;; A file named review.md would map to the built-in review command.
    (with-temp-file (expand-file-name "review.md" dir) (insert "custom review"))
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
    (with-temp-file (expand-file-name "trun.md" dir)
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

(ert-deftest gptel-agent-harness-test-load-custom-interactive ()
  "`load-custom' reports defined commands when called interactively."
  (gptel-agent-harness-test--with-temp-dir dir
    (with-temp-file (expand-file-name "tfoo.md" dir)
      (insert "Foo ${path}."))
    (let ((gptel-agent-harness-commands--custom-commands nil)
          (message-text nil))
      (cl-letf (((symbol-function 'called-interactively-p)
                 (lambda (&rest _) t))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-text (apply #'format fmt args)))))
        (let ((defined (gptel-agent-harness-commands-load-custom dir)))
          (should (= 1 (length defined)))
          (should (string-match-p "Defined 1 custom command"
                                  message-text)))
        (fmakunbound 'gptel-agent-harness-commands-tfoo)))))

(ert-deftest gptel-agent-harness-test-custom-explain-command ()
  "The load-time `explain' custom command spawns a buffer."
  (gptel-agent-harness-test--with-temp-dir dir
    (cl-letf (((symbol-function 'gptel-get-tool)
               (lambda (name) (intern (format "tool-%s" name))))
              ((symbol-function 'gptel-agent-update) #'ignore)
              ((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'gptel--update-status) (lambda (&rest _) nil))
              ((symbol-function 'gptel)
               (lambda (buf-name &optional _p _i _int)
                 (get-buffer-create buf-name)))
              ((symbol-function 'project-current) (lambda () nil)))
      (let ((buf (gptel-agent-harness-commands-explain "why")))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string-match-p "senior engineer" gptel-system-prompt)))
        (kill-buffer buf)))))

(provide 'gptel-agent-harness-test-commands)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-commands.el ends here
