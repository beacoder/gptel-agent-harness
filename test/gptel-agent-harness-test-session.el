;;; gptel-agent-harness-test-session.el --- Session persistence tests -*- lexical-binding: t -*-
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
;; ERT tests for session persistence: file naming, auto-save/restore
;; (local variables, tool names, trailing-block parsing, title
;; handling), preview, session title generation, and the serialization
;; helpers (`--write-local-vars', `--sanitize-title',
;; `--title-from-filename').
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

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

;;;; Serialization Helpers

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

(ert-deftest gptel-agent-harness-test-read-title-prompt ()
  "`--read-title-prompt' reads the file and errors when missing."
  (let ((temp-file (make-temp-file "title-" nil ".txt" "title prompt")))
    (let ((gptel-agent-harness--title-prompt-file temp-file))
      (should (equal (gptel-agent-harness--read-title-prompt) "title prompt")))
    (delete-file temp-file))
  (let ((gptel-agent-harness--title-prompt-file "/nonexistent/title.md"))
    (should-error (gptel-agent-harness--read-title-prompt))))

;;;; Session Restore Tool Names Path

(ert-deftest gptel-agent-harness-test-restore-session-tool-names ()
  "Test session restore uses `gptel--tool-names' when no preset is available.
A name that no longer resolves is skipped instead of aborting the
restore.  `debug-on-error' is bound to t so the check also covers the
`condition-case-unless-debug' trap: `with-demoted-errors' here would
re-signal and lose every tool (see the comment at the call site)."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (debug-on-error t)
          (session-file (expand-file-name "test_260723100000.md" temp-dir)))
      ;; Write a session file with tool names but no preset
      (with-temp-file session-file
        (insert "Session content.\n")
        (insert "\n" gptel-agent-harness-test--lv-header "\n")
        (insert ";; gptel-agent-harness--project-dir: \"/tmp/proj\"\n")
        (insert ";; gptel-model: \"gpt-5-mini\"\n")
        (insert ";; gptel--backend-name: \"test-be\"\n")
        (insert ";; gptel--tool-names: (\"Glob\" \"Gone\" \"Grep\" \"Read\")\n")
        (insert ";; End:\n"))
      (cl-letf (((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-mode)
                 (lambda (&optional arg)
                   (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t)))))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name)
                   (if (equal name "Gone")
                       (error "No tool matches for %S" name)
                     (list :name name :function #'ignore))))
                ((symbol-function 'gptel-get-preset) (lambda (_) nil)))
        (gptel-agent-harness-restore-session session-file)
        ;; Tools should be restored from gptel--tool-names
        (should gptel-use-tools)
        (should (= (length gptel-tools) 3))
        (kill-buffer (current-buffer))))))

(ert-deftest gptel-agent-harness-test-restore-session-local-vars-in-content ()
  "Test restore with a trailing local-vars block in the session.
Restore must use the trailing local-vars block, not an earlier
occurrence quoted in the conversation.
Conversations can contain a quoted local-variables header inside source
code; parsing the first match truncates the conversation and discards
all saved state."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (session-file (expand-file-name "test_260723100000.md" temp-dir)))
      ;; Conversation content that itself quotes a local-vars block
      (with-temp-file session-file
        (insert "Conversation start.\n")
        (insert "```elisp\n")
        (insert gptel-agent-harness-test--lv-header "\n")
        (insert ";; package-lint-main-file: \"foo.el\"\n")
        (insert ";; End:\n")
        (insert "```\n")
        (insert "Conversation end.\n")
        ;; The real trailing block appended by auto-save
        (insert "\n" gptel-agent-harness-test--lv-header "\n")
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

(ert-deftest gptel-agent-harness-test-restore-session-short-title ()
  "Restore keeps a short title as the buffer name without truncation."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (session-file (expand-file-name
                         "Fix-auth-bug_260723100000.md" temp-dir)))
      (with-temp-file session-file
        (insert "content\n")
        (insert "\n" gptel-agent-harness-test--lv-header "\n")
        (insert ";; End:\n"))
      (cl-letf (((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-mode)
                 (lambda (&optional arg)
                   (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t)))))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name) (list :name name :function #'ignore)))
                ((symbol-function 'gptel-get-preset) (lambda (_) nil)))
        (gptel-agent-harness-restore-session session-file)
        (should (equal (buffer-name) "*Fix auth bug*"))
        (should (equal gptel-agent-harness--session-title "Fix auth bug"))
        (kill-buffer (current-buffer))))))

(ert-deftest gptel-agent-harness-test-restore-latest-session-missing-dir ()
  "`restore-latest-session' reports a missing session directory."
  (let ((gptel-agent-harness-session-dir "/nonexistent/gptel-sessions-xyz"))
    (should (string-match-p "does not exist"
                            (gptel-agent-harness-restore-latest-session)))))

(ert-deftest gptel-agent-harness-test-restore-session-long-title ()
  "Restore truncates long titles in the buffer name and keeps the cache."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((gptel-agent-harness-session-dir temp-dir)
          (session-file (expand-file-name
                         "This-is-a-very-long-session-title_260723100000.md"
                         temp-dir)))
      (with-temp-file session-file
        (insert "content\n")
        (insert "\n" gptel-agent-harness-test--lv-header "\n")
        (insert ";; gptel-agent-harness--project-dir: \"/tmp/proj\"\n")
        (insert ";; End:\n"))
      (cl-letf (((symbol-function 'gptel-agent-update) #'ignore)
                ((symbol-function 'gptel-mode)
                 (lambda (&optional arg)
                   (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t)))))
                ((symbol-function 'gptel-get-tool)
                 (lambda (name) (list :name name :function #'ignore)))
                ((symbol-function 'gptel-get-preset) (lambda (_) nil)))
        (let ((gptel--preset 'some-preset))
          (gptel-agent-harness-restore-session session-file))
        (should (string-match-p "…" (buffer-name)))
        (should (equal gptel-agent-harness--session-title
                       "This is a very long session title"))
        (should (equal gptel-agent-harness--session-file-cache session-file))
        (kill-buffer (current-buffer))))))

;;;; Preview Session Tests

(ert-deftest gptel-agent-harness-test-preview-session ()
  "Test `--preview-session' creates a preview buffer with metadata."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((session-file (expand-file-name "test_260723100000.md" temp-dir)))
      (with-temp-file session-file
        (insert "User: hello\nAssistant: hi\n")
        (insert "\n" gptel-agent-harness-test--lv-header "\n")
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
                (should-not (string-match-p (regexp-quote gptel-agent-harness-test--lv-header)
                                            (buffer-string))))))
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

(ert-deftest gptel-agent-harness-test-preview-candidate-at-point ()
  "`--preview-candidate-at-point' previews the current file candidate."
  (let ((gptel-agent-harness--preview-candidate nil))
    (gptel-agent-harness-test--with-temp-dir dir
      (let ((session-file (expand-file-name "test_260723100000.md" dir)))
        (with-temp-file session-file (insert "content"))
        (unwind-protect
            (progn
              ;; vertico path (dynamic binding via defvar'd special vars)
              (let ((vertico--index 0)
                    (vertico--candidates (list session-file)))
                (gptel-agent-harness--preview-candidate-at-point)
                (should (get-buffer "*gptel-session-preview*"))
                (gptel-agent-harness--dismiss-preview))
              ;; minibuffer content path (reset the remembered candidate)
              (setq gptel-agent-harness--preview-candidate nil)
              (cl-letf (((symbol-function 'minibuffer-contents)
                         (lambda () session-file)))
                (gptel-agent-harness--preview-candidate-at-point)
                (should (get-buffer "*gptel-session-preview*"))
                (gptel-agent-harness--dismiss-preview))
              ;; non-file candidate → no preview, no error
              (let ((vertico--index 0)
                    (vertico--candidates (list "/nonexistent/foo.md")))
                (gptel-agent-harness--preview-candidate-at-point)
                (should-not (get-buffer "*gptel-session-preview*")))
              ;; non-string candidate errors inside and is swallowed
              (let ((vertico--index 0)
                    (vertico--candidates (list 42)))
                (gptel-agent-harness--preview-candidate-at-point))
              ;; no candidates at all → no error
              (let ((vertico--index nil))
                (gptel-agent-harness--preview-candidate-at-point)))
          (gptel-agent-harness--dismiss-preview))))))

(ert-deftest gptel-agent-harness-test-setup-preview-hook ()
  "`--setup-preview-hook' installs a local `post-command-hook'."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness--setup-preview-hook)
      (should (memq #'gptel-agent-harness--preview-candidate-at-point
                    post-command-hook)))))

(ert-deftest gptel-agent-harness-test-read-session-file ()
  "`--read-session-file' returns the selected file and dismisses the preview."
  (cl-letf (((symbol-function 'read-file-name)
             (lambda (&rest _) "/tmp/selected-session.md")))
    (gptel-agent-harness-test--with-temp-dir dir
      (let ((gptel-agent-harness-session-dir dir))
        (should (equal (gptel-agent-harness--read-session-file)
                       "/tmp/selected-session.md"))
        (should-not (get-buffer "*gptel-session-preview*"))))))

(provide 'gptel-agent-harness-test-session)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-session.el ends here
