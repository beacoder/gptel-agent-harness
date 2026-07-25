;;; gptel-agent-harness-commands.el --- Commands for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
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
;; Commands for gptel-agent-harness.
;;
;;; Code:

(require 'gptel)
(require 'gptel-agent)
(require 'gptel-agent-harness-session)
(require 'project)

;;;; Context Compaction

(defvar gptel-agent-harness-compact-prompt-file)

(defun gptel-agent-harness--read-compact-prompt ()
  "Read the compact prompt from `gptel-agent-harness-compact-prompt-file'."
  (if (file-exists-p gptel-agent-harness-compact-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-compact-prompt-file)
        (buffer-string))
    (error "Compact prompt file not found: %s" gptel-agent-harness-compact-prompt-file)))

(declare-function gptel-agent-harness-cache--reset-epoch "gptel-agent-harness-cache")

(defun gptel-agent-harness-commands--compact-callback (resp info)
  "Callback for `gptel-agent-harness-commands-compact'.

Handles the LLM response RESP.  On success (RESP is a string),
erases the buffer and inserts the compacted summary.  On failure,
reports the error.  INFO is the request info plist."
  (let ((buf (plist-get info :buffer)))
    (cond
     ((not (buffer-live-p buf))
      (user-error "Session buffer \"%s\" is no longer available"
                  (buffer-name buf)))
     ;; API error — resp is nil
     ((null resp)
      (with-current-buffer buf
        (gptel--update-status
         (format " Error: %s" (plist-get info :status)) 'error))
      (message "Compaction failed: %S" (plist-get info :status)))
     ;; Success — resp is a string
     ((stringp resp)
      (with-current-buffer buf
        ;; Erase all buffer content and insert the compacted summary
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert resp)
          (unless (eq (char-before) ?\n) (insert "\n")))
        (gptel--update-status " Ready" 'success)))
     ;; Reasoning block — ignore, wait for text
     ((and (consp resp) (eq (car resp) 'reasoning)) nil)
     ;; End-of-stream marker — ignore
     ((eq resp t) nil)
     ;; Abort
     ((eq resp 'abort)
      (with-current-buffer buf
        (plist-put info :error "Compaction aborted")
        (gptel--update-status " Aborted" 'error))
      (message "Compaction aborted"))
     ;; Anything else (e.g., tool call) — treat as error
     (t
      (with-current-buffer buf
        (plist-put info :error "Compaction failed: unexpected response type")
        (gptel--update-status " Error: Compaction failed" 'error))
      (message "Compaction failed: unexpected response type %S" (type-of resp))))))

(defun gptel-agent-harness--strip-compact-prefix ()
  "Strip the header and separator from current buffer, keeping the summary.
If a previous compaction frame exists (header + summary + separator),
remove the header and separator, leaving the old summary as plain text
followed by the new conversation content.

Must be called with point in the buffer to compact."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward gptel-agent-harness-compact-header nil t)
      ;; Remove the header (already matched, point is after it).
      (delete-region (point-min) (point))
      ;; Find and remove the separator.
      (when (search-forward gptel-agent-harness-compact-separator nil t)
        (replace-match "\n\n" t t)))))

(defun gptel-agent-harness--insert-compact-frame ()
  "Insert the compact header at buffer start and separator at buffer end.
Call this after the LLM has written its summary into the buffer."
  (goto-char (point-min))
  (insert gptel-agent-harness-compact-header)
  (goto-char (point-max))
  (insert gptel-agent-harness-compact-separator))

(defun gptel-agent-harness-commands-compact (&optional post-func)
  "Compact the current buffer contents using the LLM.

Sends the entire buffer content as a user message to the LLM with the
compact system prompt.  On success, erases the buffer and replaces it
with the compacted summary.

POST-FUNC, if provided, is called with the INFO plist after the
compaction completes (success or failure).  Check (plist-get info :error)
to determine if compaction succeeded.

This function does NOT modify the buffer before sending — it sends
whatever is currently in the buffer as-is.  The caller is responsible
for preparing the buffer content (e.g., stripping headers).

Returns the FSM object for the compaction request."
  (unless (bound-and-true-p gptel-mode)
    (user-error "Not in a gptel buffer"))
  (gptel--update-status " Compacting..." 'warning)
  (let* ((compact-prompt (or (and (local-variable-p 'gptel-agent-compact-prompt)
                                  gptel-agent-compact-prompt)
                             (gptel-agent-harness--read-compact-prompt)))
         ;; Disable tools and reasoning for the compaction request
         (gptel-include-reasoning nil)
         (gptel-use-tools nil)
         (gptel-stream nil)
         ;; Send entire buffer content as the prompt
         (content (buffer-substring-no-properties (point-min) (point-max)))
         (fsm (gptel-request content
                :system compact-prompt
                :buffer (current-buffer)
                :position (point-max-marker)
                :transforms nil
                :callback #'gptel-agent-harness-commands--compact-callback)))
    (when (functionp post-func)
      (let ((info (gptel-fsm-info fsm)))
        (plist-put info :post (cons post-func (plist-get info :post)))))
    fsm))


;;;###autoload
(defun gptel-agent-harness-commands-compact-buffer ()
  "Manually compact the current gptel buffer.

Strips the compaction frame (header/separator), sends the buffer
to the LLM for summarization, and rebuilds the buffer with the
standard header/separator structure.

Use this when context is getting large and you want to compact
without waiting for the automatic trigger."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (user-error "Not in a gptel buffer"))
  (when (bound-and-true-p gptel-agent-harness--compacting-p)
    (user-error "Compaction already in progress"))
  (setq-local gptel-agent-harness--compacting-p t)
  ;; Strip header and separator, leaving old summary as plain text.
  (gptel-agent-harness--strip-compact-prefix)
  ;; Set compact prompt and send.
  (setq-local gptel-agent-compact-prompt
              (gptel-agent-harness--read-compact-prompt))
  (let ((buf (current-buffer)))
    (gptel-agent-harness-commands-compact
     (lambda (&optional info)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (kill-local-variable 'gptel-agent-compact-prompt)
           (setq gptel-agent-harness--compacting-p nil)
           (if (and info (plist-get info :error))
               (message "Manual compaction failed: %s"
                        (plist-get info :error))
             ;; Success: add header + separator.
             (gptel-agent-harness-cache--reset-epoch)
             (gptel-agent-harness--insert-compact-frame)
             (message "Buffer compacted successfully."))))))))

(defconst gptel-agent-harness-commands--initialize-prompt-file
  (expand-file-name
   "prompts/initialize.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the project initialization prompt.")

(defconst gptel-agent-harness-commands--review-prompt-file
  (expand-file-name
   "prompts/review.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the code review prompt.")

(defconst gptel-agent-harness-commands--summary-prompt-file
  (expand-file-name
   "prompts/summary.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "File path for the conversation summary prompt.")

(defun gptel-agent-harness-commands--read-prompt-file (file description)
  "Read and return the prompt FILE contents.
DESCRIPTION is used in error messages."
  (if (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    (error "%s prompt file not found: %s" description file)))

;; Removed duplicate function definition - the first definition with 'description' parameter is sufficient

(defun gptel-agent-harness-commands--read-initialize-prompt ()
  "Read and return the initialize prompt file contents."
  (gptel-agent-harness-commands--read-prompt-file
   gptel-agent-harness-commands--initialize-prompt-file "Initialize"))

(defun gptel-agent-harness-commands--read-review-prompt ()
  "Read and return the review prompt file contents."
  (gptel-agent-harness-commands--read-prompt-file
   gptel-agent-harness-commands--review-prompt-file "Review"))

(defun gptel-agent-harness-commands--read-summary-prompt ()
  "Read and return the summary prompt file contents."
  (gptel-agent-harness-commands--read-prompt-file
   gptel-agent-harness-commands--summary-prompt-file "Summary"))

(defun gptel-agent-harness-commands--substitute-placeholders (template project-dir extra)
  "Substitute ${path} and $ARGUMENTS in TEMPLATE with PROJECT-DIR and EXTRA."
  (let ((result template))
    (setq result (replace-regexp-in-string
                  "\\${path}" project-dir result t t))
    (setq result (replace-regexp-in-string
                  "\\$ARGUMENTS" (or extra "") result t t))
    result))

;;;###autoload
(defun gptel-agent-harness-commands-initialize (&optional project-dir extra)
  "Initialize a project by creating or updating AGENTS.md.

Creates a dedicated gptel buffer with agent tools enabled and uses the
initialize prompt from `gptel-agent-harness-commands--initialize-prompt-file' to
guide the LLM in analyzing the repository and generating AGENTS.md.

PROJECT-DIR defaults to the current project root (via `project-current')
or `default-directory'.  The detected directory is presented to the
user, who can confirm it or provide a different one.

EXTRA is additional instructions to substitute into the $ARGUMENTS
placeholder of the initialize prompt.  When called interactively, the
user is prompted to provide extra instructions."
  (interactive
   (let* ((detected (if-let* ((proj (project-current)))
                        (project-root proj)
                      default-directory))
          (proj-name (file-name-nondirectory
                      (directory-file-name detected)))
          (dir (if (y-or-n-p (format "Initialize project %s? " proj-name))
                   detected
                 (read-directory-name "Project directory: ")))
          (extra-str (read-string "Extra instructions (for $ARGUMENTS): ")))
     (list dir (and (not (string-blank-p extra-str)) extra-str))))
  (unless (file-directory-p project-dir)
    (user-error "Invalid project directory: %s" project-dir))
  (let* ((raw-prompt (gptel-agent-harness-commands--read-initialize-prompt))
         (prompt-content (gptel-agent-harness-commands--substitute-placeholders
                          raw-prompt project-dir extra))
         (proj-name (file-name-nondirectory
                     (directory-file-name project-dir)))
         ;; Set up gptel variables for the new buffer
         (gptel-system-prompt prompt-content)
         (gptel-temperature 0)
         (gptel-buf
          (gptel (generate-new-buffer-name
                  (format "*gptel-agent-init:%s*" proj-name))
                 nil nil 'interactive)))
    (with-current-buffer gptel-buf
      (setq default-directory project-dir)
      (setq gptel-agent-harness--project-dir project-dir)
      (gptel-agent-update)
      ;; Enable tools for this buffer
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools
                  (mapcar #'gptel-get-tool gptel-agent-harness--default-tools))
      (gptel-agent-harness--setup-session)
      (gptel--update-status " Initializing..." 'warning)
      (goto-char (point-max))
      (insert (format
               "Analyze the repository at %s and create/update AGENTS.md."
               project-dir))
      (insert "\n")
      (gptel-send))
    gptel-buf))

;;;###autoload
(defun gptel-agent-harness-commands-review (&optional arguments)
  "Perform a code review using the review prompt.

ARGUMENTS can be:
- nil or empty: Review all uncommitted changes (default)
- A commit hash (40-char SHA or short hash): Review that specific commit
- A branch name: Compare current branch to the specified branch
- A PR URL or number: Review the pull request

A dedicated *gptel-agent-review* buffer is created for the review."
  (interactive
   (let ((arg-str (read-string "Review arguments (commit/branch/PR, or empty for uncommitted changes): ")))
     (list (and (not (string-blank-p arg-str)) arg-str))))
  (let* ((raw-prompt (gptel-agent-harness-commands--read-review-prompt))
         (prompt-content (gptel-agent-harness-commands--substitute-placeholders
                          raw-prompt default-directory arguments))
         gptel-buf)
    (setq gptel-buf (gptel (generate-new-buffer-name "*gptel-agent-review*")
                           nil nil 'interactive))
    (with-current-buffer gptel-buf
      (setq-local gptel-system-prompt prompt-content)
      (setq-local gptel-temperature 0)
      (setq default-directory (or (and (project-current)
                                       (project-root (project-current)))
                                  default-directory))
      (setq gptel-agent-harness--project-dir default-directory)
      (gptel-agent-update)
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools
                  (mapcar #'gptel-get-tool gptel-agent-harness--default-tools))
      (gptel-agent-harness--setup-session)
      (gptel--update-status " Reviewing..." 'warning)
      (goto-char (point-max))
      (insert (format "Review code changes%s.\n"
                      (if arguments
                          (format " with arguments: %s" arguments)
                        "")))
      (gptel-send)
      gptel-buf)))

;;;###autoload
(defun gptel-agent-harness-commands-summary ()
  "Summarize the current gptel buffer conversation.

Uses the summary prompt from `gptel-agent-harness-commands--summary-prompt-file'
as the system prompt, and sends the current buffer's conversation history as user
input.  If the region is active, uses the region content instead of the full
buffer.  The resulting summary is inserted at the end of the buffer."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (user-error "Not in a gptel buffer"))
  (let* ((system-prompt (gptel-agent-harness-commands--read-summary-prompt))
         (conversation (if (use-region-p)
                           (buffer-substring-no-properties
                            (region-beginning) (region-end))
                         (buffer-substring-no-properties
                          (point-min) (point-max))))
         (buf (current-buffer)))
    (deactivate-mark)
    (goto-char (point-max))
    (insert "Summarize current conversation.\n")
    (gptel--update-status " Summarizing..." 'warning)
    (let ((gptel-use-tools nil)
          (gptel-use-context nil)
          (gptel-stream nil))
      (gptel-request conversation
        :system system-prompt
        :stream nil
        :callback (lambda (response info)
                    (pcase response
                      ((pred stringp)
                       (with-current-buffer buf
                         (goto-char (point-max))
                         (insert "\n" response "\n")
                         (gptel-agent-harness--auto-save-session)
                         (gptel--update-status " Ready" 'success)))
                      (`(reasoning . ,_)   ;skip reasoning, await actual content
                       (gptel--update-status " Summarizing..." 'warning))
                      (`t                   ;streaming end-of-stream marker
                       (gptel--update-status " Ready" 'success))
                      (`abort
                       (message "Summary request aborted")
                       (gptel--update-status " Aborted" 'error))
                      (_
                       (if (member (plist-get info :http-status) '("200" "100"))
                           (gptel--update-status " Ready" 'success)
                         (message "Summary request failed: %s" (plist-get info :status))
                         (gptel--update-status " Failed" 'error)))))))))

(provide 'gptel-agent-harness-commands)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-commands.el ends here
