;;; gptel-agent-harness-commands.el --- Commands for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: Kiro-cli:claude-opus-4-8, gptel-agent-harness:deepseek-v4-flash
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

(require 'cl-lib)
(require 'gptel)
(require 'gptel-agent)
(require 'gptel-agent-harness-session)
(require 'gptel-agent-harness-tools)
(require 'project)

;;;; Context Compaction

(defvar gptel-agent-harness-compact-prompt-file)
(defvar gptel-agent-harness-nudge-message)
(defvar gptel-agent-harness-compact-header)
(declare-function gptel-agent-harness--read-compact-prompt "gptel-agent-harness")

;; Defined in gptel-agent-harness.el, loaded after this file.
(defvar gptel-agent-harness--nudge-count)

(defun gptel-agent-harness-commands--run-post-funcs (info)
  "Call all post-funcs stored in INFO's :post plist and clear them.
Each function is called with INFO as its argument."
  (let ((funcs (plist-get info :post)))
    (when funcs
      (plist-put info :post nil)
      (dolist (fn funcs)
        (when (functionp fn)
          (funcall fn info))))))

(defun gptel-agent-harness-commands--compact-callback (resp info)
  "Callback for `gptel-agent-harness-commands-compact'.

Handles the LLM response RESP.  On success (RESP is a string),
erases the buffer and inserts the compacted summary.  On failure,
reports the error.  INFO is the request info plist."
  (let ((buf (plist-get info :buffer)))
    (cond
     ((not (buffer-live-p buf))
      (gptel-agent-harness-commands--run-post-funcs info)
      ;; Do not signal: this runs from a network callback, where an error
      ;; escapes into gptel's response machinery instead of reaching a
      ;; caller who could handle it.  The result is simply dropped.
      (message "gptel-agent-harness: session buffer is gone, compaction result dropped"))
     ;; API error — resp is nil
     ((null resp)
      (plist-put info :error
                 (or (plist-get info :error)
                     (format "Compaction failed: %s"
                             (plist-get info :status))))
      (with-current-buffer buf
        (gptel--update-status
         (format " Error: %s" (plist-get info :status)) 'error))
      (message "Compaction failed: %S" (plist-get info :status))
      (gptel-agent-harness-commands--run-post-funcs info))
     ;; Success — resp is a string
     ((stringp resp)
      (with-current-buffer buf
        ;; Erase all buffer content and insert the compacted summary
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert resp)
          (unless (eq (char-before) ?\n) (insert "\n")))
        (gptel--update-status " Ready" 'success))
      (gptel-agent-harness-commands--run-post-funcs info))
     ;; Reasoning block — ignore, wait for text
     ((and (consp resp) (eq (car resp) 'reasoning)) nil)
     ;; End-of-stream marker — ignore (non-streaming mode, never expected)
     ((eq resp t) nil)
     ;; Abort
     ((eq resp 'abort)
      (with-current-buffer buf
        (plist-put info :error "Compaction aborted")
        (gptel--update-status " Aborted" 'error))
      (message "Compaction aborted")
      (gptel-agent-harness-commands--run-post-funcs info))
     ;; Anything else (e.g., tool call) — treat as error
     (t
      (with-current-buffer buf
        (plist-put info :error "Compaction failed: unexpected response type")
        (gptel--update-status " Error: Compaction failed" 'error))
      (message "Compaction failed: unexpected response type %S" (type-of resp))
      (gptel-agent-harness-commands--run-post-funcs info)))))

(declare-function gptel-agent-harness--strip-compact-prefix "gptel-agent-harness")

(declare-function gptel-agent-harness--insert-compact-frame "gptel-agent-harness")

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
         ;; Disable tools/context/reasoning for the compaction request
         (gptel-include-reasoning nil)
         (gptel-use-tools nil)
         (gptel-use-context nil)
         ;; Send entire buffer content as the prompt
         (content (buffer-substring-no-properties (point-min) (point-max)))
         (fsm (gptel-request content
                :system compact-prompt
                :stream nil
                :buffer (current-buffer)
                :position (point-max-marker)
                :transforms nil
                :callback #'gptel-agent-harness-commands--compact-callback)))
    (when (functionp post-func)
      (let ((info (gptel-fsm-info fsm)))
        (plist-put info :post (cons post-func (plist-get info :post)))))
    fsm))


(defun gptel-agent-harness--mode-reminder-p (text)
  "Return non-nil if TEXT is a harness-injected plan/build mode reminder.
Mode reminders start with `<system-reminder>' or match the
plan-exit approved message template."
  (or (string-prefix-p "<system-reminder>" text)
      (gptel-agent-harness--plan-exit-notice-p text)))

(defun gptel-agent-harness--plan-exit-notice-p (text)
  "Return non-nil if TEXT matches the plan-exit approved message template."
  (let ((template gptel-agent-harness-tools-plan-exit-approved-message))
    (if (not (string-match-p "%s" template))
        (string= text template)
      (let* ((parts (split-string template "%s" t))
             (prefix (car parts))
             (suffix (cadr parts)))
        (and (string-prefix-p prefix text)
             (or (null suffix) (string-suffix-p suffix text)))))))

(defun gptel-agent-harness-commands--filter-user-prompts (texts)
  "Return the kept user messages from TEXTS, oldest first.
TEXTS is a list of user prompt strings in chronological order.
The kept messages exclude nudges, compacted summary frames, and
stale mode reminders (see below).

Excludes:
- nudge messages (completion supervision, not user input)
- previously compacted summary frames (old harness artifacts)
- stale mode reminders (only the most recent contiguous batch is kept)

The most recent batch of mode reminders IS preserved because it
represents the current mode state (plan vs build).  Dropping all
of them would leave the model unsure which mode is active."
  (let* ((nudge gptel-agent-harness-nudge-message)
         (header gptel-agent-harness-compact-header)
         (is-reminder (mapcar (lambda (text)
                                (gptel-agent-harness--mode-reminder-p text))
                              texts))
         (last-reminder-idx
          (cl-loop for i downfrom (1- (length is-reminder)) to 0
                   when (nth i is-reminder) return i
                   finally return -1))
         (batch-start (if (>= last-reminder-idx 0)
                          (let ((s last-reminder-idx))
                            (while (and (> s 0) (nth (1- s) is-reminder))
                              (cl-decf s))
                            s)
                        -1))
         (prompts nil))
    (cl-loop for i from 0
             for text in texts
             unless (or (string= text nudge)
                        (string-prefix-p header text)
                        (and (nth i is-reminder)
                             (not (and (>= i batch-start)
                                       (<= i last-reminder-idx)))))
             do (push text prompts))
    (nreverse prompts)))

(defun gptel-agent-harness-commands--buffer-user-prompts ()
  "Extract all user prompt texts from the current buffer.

Scans text property boundaries to find user text regions (those
not marked with `gptel' property value `response'), then applies
the shared exclusion rules of
`gptel-agent-harness-commands--filter-user-prompts'.

Returns a list of non-empty user prompt strings, oldest first."
  (let ((raw-texts nil))
    (save-excursion
      (goto-char (point-min))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let* ((next-change (next-single-property-change pos 'gptel nil (point-max)))
                 (prop-val (get-text-property pos 'gptel)))
            ;; User text: no gptel property or gptel property is not 'response
            (unless (eq prop-val 'response)
              (let ((text (string-trim
                           (buffer-substring-no-properties pos next-change))))
                (unless (string-empty-p text)
                  (push text raw-texts))))
            (setq pos next-change)))))
    (gptel-agent-harness-commands--filter-user-prompts
     (nreverse raw-texts))))

;;;###autoload
(defun gptel-agent-harness-commands-compact-buffer ()
  "Manually compact the current gptel buffer.

Strips the compaction frame (header/separator), sends the buffer
to the LLM for summarization, and rebuilds the buffer with the
standard header/separator structure.  All user prompts (excluding
nudges and mode-switch messages) are restored after the summary
frame, so the model retains the original requests.

Use this when context is getting large and you want to compact
without waiting for the automatic trigger."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (user-error "Not in a gptel buffer"))
  (when (bound-and-true-p gptel-agent-harness--compacting-p)
    (user-error "Compaction already in progress"))
  ;; Extract user prompts BEFORE stripping frame (frame text is excluded
  ;; by the header-prefix check, so order doesn't matter, but doing it
  ;; before strip ensures we see the full buffer).
  (let ((prompts (gptel-agent-harness-commands--buffer-user-prompts)))
    (setq-local gptel-agent-harness--compacting-p t)
    ;; Strip header and separator, leaving old summary as plain text.
    (gptel-agent-harness--strip-compact-prefix)
    ;; Set compact prompt and send.
    (setq-local gptel-agent-compact-prompt
                (gptel-agent-harness--read-compact-prompt))
    (let ((buf (current-buffer))
          (resume-prompts prompts))
      (gptel-agent-harness-commands-compact
       (lambda (&optional info)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (kill-local-variable 'gptel-agent-compact-prompt)
             (setq gptel-agent-harness--compacting-p nil)
             ;; Reset nudge count so the post-compaction conversation starts
             ;; with a fresh nudge budget, matching the automatic path.
             (setq gptel-agent-harness--nudge-count 0)
             (if (and info (plist-get info :error))
                 (message "Manual compaction failed: %s"
                          (plist-get info :error))
               ;; Success: add header + separator + restored user prompts.
               (gptel-agent-harness--insert-compact-frame)
               (goto-char (point-max))
               (dolist (prompt resume-prompts)
                 (insert prompt "\n\n"))
               (message "Buffer compacted successfully.")))))))))

(defconst gptel-agent-harness-commands--summary-prompt-file
  (expand-file-name
   "prompts/summary.md"
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

(defun gptel-agent-harness-commands--start-session
    (prompt-content dir buffer-name status kickoff)
  "Spawn a dedicated gptel agent buffer and kick off the conversation.

Creates a new interactive gptel buffer named BUFFER-NAME with
PROMPT-CONTENT as its buffer-local system prompt, agent tools enabled,
and `default-directory'/project set to DIR.  STATUS is shown in the
mode-line, KICKOFF is inserted as the first user message, and the
request is sent.  Returns the new buffer.

Shared by the `initialize'/`review' commands (via
`gptel-agent-harness-commands--define-session-command') and by
auto-discovered custom commands."
  (let ((gptel-buf (gptel (generate-new-buffer-name buffer-name)
                          nil nil 'interactive)))
    (with-current-buffer gptel-buf
      (setq default-directory dir)
      (setq-local gptel-system-prompt prompt-content)
      (setq-local gptel-temperature 0)
      (setq gptel-agent-harness--project-dir dir)
      (gptel-agent-update)
      ;; Enable tools for this buffer.  Resolve each name defensively:
      ;; `gptel-get-tool' signals for an unknown name, and tools the
      ;; harness registers itself (Question, PlanExit) only exist once
      ;; `gptel-agent-harness-mode' is on.  These commands are autoloaded,
      ;; so they can run before that — a missing tool must degrade to a
      ;; smaller tool set, not abort the command.
      ;;
      ;; Uses an explicit `condition-case', NOT `with-demoted-errors':
      ;; the latter expands to `condition-case-unless-debug', which
      ;; re-signals whenever `debug-on-error' is non-nil.  The degradation
      ;; would then vanish precisely when someone is debugging — and inside
      ;; ERT tests on Emacs < 30, whose runner binds `debug-on-error' to t.
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools
                  (delq nil
                        (mapcar
                         (lambda (name)
                           (condition-case err
                               (gptel-get-tool name)
                             (error
                              (message "gptel-agent-harness: tool %S unavailable — %s"
                                       name (error-message-string err))
                              nil)))
                         gptel-agent-harness--default-tools)))
      (gptel-agent-harness--setup-session)
      (gptel--update-status status 'warning)
      (goto-char (point-max))
      (insert kickoff)
      (gptel-send))
    gptel-buf))

;;;; New-session command generator
;;
;; `initialize' and `review' both: read a prompt file from prompts/,
;; substitute ${path}/$ARGUMENTS, spawn a dedicated gptel buffer with agent
;; tools enabled, and kick off the conversation.  The macro below captures
;; that shared flow so adding a command needs only a prompt file plus a short
;; declaration.  For each KEY it defines:
;;   - gptel-agent-harness-commands--KEY-prompt-file  (defconst, let-bindable)
;;   - gptel-agent-harness-commands--read-KEY-prompt  (prompt reader)
;;   - the interactive command itself

(cl-defmacro gptel-agent-harness-commands--define-session-command
    (key command arglist interactive-spec
         &key docstring dir extra buffer-name status kickoff validate-dir)
  "Define a new-session agent command COMMAND from a prompt file.

KEY is a symbol (e.g. `review'); the prompt text is read from the file
KEY.md in the package prompt directory.  KEY derives the prompt-file
constant `gptel-agent-harness-commands--KEY-prompt-file' and the reader
`gptel-agent-harness-commands--read-KEY-prompt'.

ARGLIST and INTERACTIVE-SPEC are the command's argument list and the
body of its `interactive' form.  DIR, EXTRA, BUFFER-NAME and KICKOFF are
forms evaluated in the command body; DIR is bound to `dir' first and is
in scope for BUFFER-NAME and KICKOFF.  EXTRA is substituted into the
prompt's $ARGUMENTS placeholder and DIR into ${path}.  When VALIDATE-DIR
is non-nil the command errors unless `dir' is an existing directory.
STATUS is the status-line string shown while the request is in flight.
KICKOFF is inserted verbatim (include a trailing newline if desired)."
  (let* ((prefix "gptel-agent-harness-commands")
         (const-sym (intern (format "%s--%s-prompt-file" prefix key)))
         (reader-sym (intern (format "%s--read-%s-prompt" prefix key)))
         (desc (capitalize (symbol-name key)))
         (rel-path (format "prompts/%s.md" key)))
    `(progn
       (defconst ,const-sym
         (expand-file-name
          ,rel-path
          (file-name-directory (or (locate-library "gptel-agent-harness")
                                   (error "Failed to find gptel-agent-harness"))))
         ,(format "File path for the %s prompt." key))
       (defun ,reader-sym ()
         ,(format "Read and return the %s prompt file contents." key)
         (gptel-agent-harness-commands--read-prompt-file ,const-sym ,desc))
       (defun ,command ,arglist
         ,docstring
         (interactive ,interactive-spec)
         (let ((dir ,dir)
               (extra ,extra))
           ,@(when validate-dir
               '((unless (file-directory-p dir)
                   (user-error "Invalid project directory: %s" dir))))
           (let ((prompt-content
                  (gptel-agent-harness-commands--substitute-placeholders
                   (,reader-sym) dir extra)))
             (gptel-agent-harness-commands--start-session
              prompt-content dir ,buffer-name ,status ,kickoff)))))))

;;;###autoload (autoload 'gptel-agent-harness-commands-initialize "gptel-agent-harness-commands" nil t)
(gptel-agent-harness-commands--define-session-command
    initialize gptel-agent-harness-commands-initialize
    (&optional project-dir extra)
    (let* ((detected (if-let* ((proj (project-current)))
                         (project-root proj)
                       default-directory))
           (proj-name (file-name-nondirectory
                       (directory-file-name detected)))
           (dir (if (y-or-n-p (format "Initialize project %s? " proj-name))
                    detected
                  (read-directory-name "Project directory: ")))
           (extra-str (read-string "Extra instructions (for $ARGUMENTS): ")))
      (list dir (and (not (string-blank-p extra-str)) extra-str)))
  :docstring "Initialize a project by creating or updating AGENTS.md.

Creates a dedicated gptel buffer with agent tools enabled and uses the
initialize prompt from `gptel-agent-harness-commands--initialize-prompt-file' to
guide the LLM in analyzing the repository and generating AGENTS.md.

PROJECT-DIR defaults to the current project root (via `project-current')
or `default-directory'.  The detected directory is presented to the
user, who can confirm it or provide a different one.

EXTRA is additional instructions to substitute into the $ARGUMENTS
placeholder of the initialize prompt.  When called interactively, the
user is prompted to provide extra instructions."
  :dir project-dir
  :extra extra
  :validate-dir t
  :buffer-name (format "*gptel-agent-init:%s*"
                       (file-name-nondirectory (directory-file-name dir)))
  :status " Initializing..."
  :kickoff (format
            "Analyze the repository at %s and create/update AGENTS.md.\n"
            dir))

;;;###autoload (autoload 'gptel-agent-harness-commands-review "gptel-agent-harness-commands" nil t)
(gptel-agent-harness-commands--define-session-command
    review gptel-agent-harness-commands-review
    (&optional arguments)
    (let ((arg-str (read-string "Review arguments (commit/branch/PR, or empty for uncommitted changes): ")))
      (list (and (not (string-blank-p arg-str)) arg-str)))
  :docstring "Perform a code review using the review prompt.

ARGUMENTS can be:
- nil or empty: Review all uncommitted changes (default)
- A commit hash (40-char SHA or short hash): Review that specific commit
- A branch name: Compare current branch to the specified branch
- A PR URL or number: Review the pull request

A dedicated *gptel-agent-review* buffer is created for the review."
  :dir (or (and (project-current) (project-root (project-current)))
           default-directory)
  :extra arguments
  :buffer-name "*gptel-agent-review*"
  :status " Reviewing..."
  :kickoff "Review the requested code changes.")


;;;; Auto-Discovered Custom Commands
;;
;; Any `NAME.md' file dropped into `gptel-agent-harness-commands-custom-dir'
;; becomes the interactive command `gptel-agent-harness-commands-NAME'.  The
;; file contents are the system prompt; ${path} is replaced with the project
;; root and $ARGUMENTS with the (optional) user input read interactively.
;; Discovery runs at load time; call `gptel-agent-harness-commands-load-custom'
;; to pick up newly added or edited files without restarting Emacs.

(defcustom gptel-agent-harness-commands-custom-dir
  (expand-file-name
   "prompts/commands"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Failed to find gptel-agent-harness"))))
  "Directory scanned for custom command prompt files.
Each `NAME.md' file defines the interactive command
`gptel-agent-harness-commands-NAME'.  See
`gptel-agent-harness-commands-load-custom'."
  :type 'directory
  :group 'gptel-agent-harness)

(defvar gptel-agent-harness-commands--custom-commands nil
  "Command symbols defined from `gptel-agent-harness-commands-custom-dir'.")

(defun gptel-agent-harness-commands--custom-name (file)
  "Return a sanitized, symbol-safe command basename derived from FILE."
  (let ((base (downcase (file-name-base file))))
    ;; Collapse any run of non-alphanumeric characters into a single dash and
    ;; trim leading/trailing dashes, so \"Fix Bug!.md\" -> \"fix-bug\".
    (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" base) "-+" "-+")))

(defun gptel-agent-harness-commands--define-custom-command (file)
  "Define an interactive command from prompt FILE.
Return the command symbol, or nil when the derived name is empty or
already bound to something the harness did not define (to avoid
clobbering built-in commands or unrelated functions)."
  (let* ((name (gptel-agent-harness-commands--custom-name file))
         (sym (and (not (string-empty-p name))
                   (intern (format "gptel-agent-harness-commands-%s" name)))))
    (cond
     ((null sym)
      (message "gptel-agent-harness: ignoring custom prompt %s (empty name)"
               (file-name-nondirectory file))
      nil)
     ((and (fboundp sym)
           (not (memq sym gptel-agent-harness-commands--custom-commands)))
      (message "gptel-agent-harness: skipping custom command %s (name already in use)"
               sym)
      nil)
     (t
      (defalias sym
        (lambda (&optional arguments)
          (interactive
           (list (let ((s (read-string
                           (format "%s $ARGUMENTS (empty for none): " name))))
                   (and (not (string-blank-p s)) s))))
          (let* ((dir (or (and (project-current)
                               (project-root (project-current)))
                          default-directory))
                 (prompt-content
                  (gptel-agent-harness-commands--substitute-placeholders
                   (gptel-agent-harness-commands--read-prompt-file file name)
                   dir arguments)))
            (gptel-agent-harness-commands--start-session
             prompt-content dir
             (format "*gptel-agent-%s*" name)
             (format " Running %s..." name)
             "Proceed with the task described in your instructions.\n")))
        (format "Custom gptel-agent command generated from a prompt file.

Spawns a dedicated agent buffer whose system prompt is the contents of:
  %s
${path} is replaced with the project root and the optional ARGUMENTS
string fills the $ARGUMENTS placeholder.

Defined by `gptel-agent-harness-commands-load-custom'."
                file))
      sym))))

;;;###autoload
(defun gptel-agent-harness-commands-load-custom (&optional dir)
  "Discover and define custom commands from DIR.
DIR defaults to `gptel-agent-harness-commands-custom-dir'.  Each
`NAME.md' file becomes `gptel-agent-harness-commands-NAME'.  Existing
harness-defined custom commands are redefined; names already bound to
other functions are skipped.  Returns the list of command symbols."
  (interactive)
  (let ((dir (or dir gptel-agent-harness-commands-custom-dir))
        (defined nil))
    (when (and dir (file-directory-p dir))
      (dolist (file (sort (directory-files dir t "\\.md\\'") #'string<))
        (unless (file-directory-p file)
          (when-let* ((sym (gptel-agent-harness-commands--define-custom-command
                            file)))
            (push sym defined)))))
    (setq gptel-agent-harness-commands--custom-commands (nreverse defined))
    (when (called-interactively-p 'interactive)
      (message "Defined %d custom command(s)%s"
               (length gptel-agent-harness-commands--custom-commands)
               (if gptel-agent-harness-commands--custom-commands
                   (format ": %s"
                           (mapconcat #'symbol-name
                                      gptel-agent-harness-commands--custom-commands
                                      ", "))
                 "")))
    gptel-agent-harness-commands--custom-commands))

;; Discover custom commands present at load time.
(gptel-agent-harness-commands-load-custom)


;;;###autoload
(defun gptel-agent-harness-commands-summary ()
  "Summarize the current gptel buffer conversation.

Uses summary prompt from `gptel-agent-harness-commands--summary-prompt-file'
as system prompt, sending buffer conversation as user input.  If the
region is active, uses region content instead of full buffer."
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
    ;; Disable tools/context/reasoning for the summary request
    (let ((gptel-include-reasoning nil)
          (gptel-use-tools nil)
          (gptel-use-context nil))
      (gptel-request conversation
        :system system-prompt
        :stream nil
        :callback (lambda (response info)
                    (pcase response
                      ((pred stringp)
                       (if (string-blank-p response)
                           (progn
                             (message "Summary returned empty response")
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (gptel--update-status " Failed" 'error))))
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (goto-char (point-max))
                             (insert "\n" response "\n")
                             (gptel-agent-harness--auto-save-session)
                             (gptel--update-status " Ready" 'success)))))
                      (`(reasoning . ,_)   ;skip reasoning, await actual content
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (gptel--update-status " Summarizing..." 'warning))))
                      (`t                   ;streaming end-of-stream marker
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (gptel--update-status " Ready" 'success))))
                      (`abort
                       (message "Summary request aborted")
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (gptel--update-status " Aborted" 'error))))
                      (_
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (if (member (plist-get info :http-status) '("200" "100"))
                               (gptel--update-status " Ready" 'success)
                             (message "Summary request failed: %s" (plist-get info :status))
                             (gptel--update-status " Failed" 'error)))))))))))

(provide 'gptel-agent-harness-commands)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-commands.el ends here
