;;; gptel-agent-harness-supervisor.el --- FSM supervisor and mode management -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
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
;; FSM supervisor (transition advice) and build/plan mode management.
;;
;;; Code:

(require 'cl-lib)
(require 'gptel-agent)
(require 'format-spec)
(require 'gptel-agent-harness-config)
(require 'gptel-agent-harness-fsm)
(require 'gptel-agent-harness-compact)
(require 'gptel-agent-harness-session)
(require 'gptel-agent-harness-commands)

;; Silence byte-compiler — defined in gptel-agent-tools.el
(defvar gptel-agent-request--handlers)

;;;; Build/Plan Mode

(defcustom gptel-agent-harness-plan-file-name "PLAN.md"
  "File name of the plan file used in plan mode.
The file is created in a per-session subdirectory of
the variable `temporary-file-directory' when switching to plan
mode, so sessions in the same project never share a plan file.
Its absolute path replaces the ${planInfo} placeholder in
`gptel-agent-harness-plan-mode-prompt-file'."
  :type 'string
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-plan-mode-subagent-reminder
  "<system-reminder>
Plan mode is active for this session — you are in a READ-ONLY phase.
STRICTLY FORBIDDEN: ANY file edits, modifications, or system changes,
except writing to the plan file below.  You may ONLY observe, analyze,
and plan.  This ABSOLUTE CONSTRAINT overrides ALL other instructions,
including any subagent role instructions you have been given.

Plan file: %s
</system-reminder>"
  "Reminder injected into sub-agent requests while plan mode is active.
The %s placeholder is replaced with the plan file path."
  :type 'string
  :group 'gptel-agent-harness)

(defvar-local gptel-agent-harness--plan-file nil
  "Absolute path of the plan file for the current buffer, or nil.
Set when switching to plan mode; see `gptel-agent-harness-set-mode'.")

(defun gptel-agent-harness--plan-temp-dir ()
  "Return a reliable temporary directory for plan files.
For a remote `default-directory' (Tramp), returns the remote temp
directory so plan files stay reachable by remote tools.  For a
local directory, the function `temporary-file-directory' would
return `default-directory' when the latter is on a mounted file
system (e.g. WSL paths under /mnt), placing plan files outside the
real temp directory; this helper therefore tries the variable
`temporary-file-directory' and the TMPDIR/TMP/TEMP environment
variables in turn, skipping any result on a mounted file system,
and finally falls back to /tmp."
  (if (file-remote-p default-directory)
      (temporary-file-directory)
    (or (cl-loop for dir in (cons (default-value 'temporary-file-directory)
                                  (list (getenv "TMPDIR")
                                        (getenv "TMP")
                                        (getenv "TEMP")))
                 when (and dir
                           (not (and mounted-file-systems
                                     (string-match mounted-file-systems dir))))
                 return (file-name-as-directory dir))
        "/tmp/")))

(defun gptel-agent-harness--plan-file-path ()
  "Return the absolute plan file path for the current buffer.
The file lives in a per-session subdirectory of
`gptel-agent-harness--plan-temp-dir' (named after the project plus
a unique `make-temp-name' suffix), keeping plan files of
concurrent sessions on the same project isolated.  Returns the
cached `gptel-agent-harness--plan-file' when set, otherwise a
freshly computed path — the caller stores it in that variable once."
  (or gptel-agent-harness--plan-file
      (let* ((proj-dir (or gptel-agent-harness--project-dir default-directory))
             (proj-name (file-name-nondirectory (directory-file-name proj-dir)))
             (dir (make-temp-name
                   (expand-file-name
                    (format "gptel-agent-plans-%s-" proj-name)
                    (gptel-agent-harness--plan-temp-dir)))))
        (expand-file-name gptel-agent-harness-plan-file-name dir))))

(defun gptel-agent-harness--ensure-plan-file ()
  "Ensure the plan file exists, creating an empty one if missing.
Returns the absolute plan file path."
  (let ((path (gptel-agent-harness--plan-file-path)))
    (unless (file-exists-p path)
      (make-directory (file-name-directory path) t)
      (write-region "" nil path))
    path))

(defun gptel-agent-harness--cleanup-plan-file ()
  "Delete the current buffer's plan file and its per-session directory.
Only ever deletes inside `gptel-agent-harness--plan-temp-dir': a
stale or foreign `gptel-agent-harness--plan-file' value (e.g. from
a session started before this feature) can never remove a file
outside it.  Resets `gptel-agent-harness--plan-file' to nil."
  (when-let* ((file gptel-agent-harness--plan-file)
              (tmp-dir (gptel-agent-harness--plan-temp-dir)))
    (when (and (file-exists-p file)
               (string-prefix-p tmp-dir file))
      (delete-file file))
    (let ((dir (file-name-directory file)))
      (when (and dir
                 (string-prefix-p tmp-dir dir)
                 (file-directory-p dir)
                 (null (directory-files dir nil "\\`[^.]" t)))
        (delete-directory dir)))
    (setq gptel-agent-harness--plan-file nil)))

(defun gptel-agent-harness--setup-plan-cleanup ()
  "Delete this buffer's plan file when the buffer is killed."
  (add-hook 'kill-buffer-hook #'gptel-agent-harness--cleanup-plan-file nil t))

(defun gptel-agent-harness--teardown-plan-cleanup ()
  "Remove the `kill-buffer-hook' plan-file cleanup from this buffer."
  (remove-hook 'kill-buffer-hook #'gptel-agent-harness--cleanup-plan-file t))

(defun gptel-agent-harness--substitute-plan-info (prompt plan-file)
  "Replace the ${planInfo} placeholder in PROMPT with PLAN-FILE."
  (replace-regexp-in-string "\\${planInfo}" plan-file prompt t t))

(defun gptel-agent-harness--sub-agent-p (fsm)
  "Return non-nil when FSM is a sub-agent request.
Sub-agent requests are spawned by the Agent tool and use
`gptel-agent-request--handlers'.  Other non-top-level requests
\(compaction, title generation, summary) use the default
`gptel-request--handlers' and are not sub-agents."
  (eq (gptel-fsm-handlers fsm) gptel-agent-request--handlers))

(defun gptel-agent-harness-set-mode (mode)
  "Set agent MODE to `build' or `plan' for the current buffer.
MODE may be a symbol or a string.

Switching to plan mode queues `gptel-agent-harness-plan-prompt-file'
and `gptel-agent-harness-plan-mode-prompt-file' for injection into the
next top-level request.  The ${planInfo} placeholder in the latter is
replaced with the absolute path of the plan file, which is created if
missing in a per-session directory under the variable
`temporary-file-directory' (see
`gptel-agent-harness-plan-file-name').  Switching back to build mode
queues `gptel-agent-harness-build-switch-prompt-file' instead.  A
queued prompt list is consumed exactly once by the following request,
so switching modes again before sending simply replaces the queue."
  (interactive "SMode (build or plan): ")
  (pcase (if (stringp mode) (intern (downcase mode)) mode)
    ('build
     ;; Read the prompt file BEFORE mutating state so a failure
     ;; (e.g. missing prompt file) leaves the previous mode and
     ;; queue intact.
     (let ((prompt (gptel-agent-harness-commands--read-prompt-file
                    gptel-agent-harness-build-switch-prompt-file "Build switch")))
       (setq gptel-agent-harness--mode 'build)
       (setq gptel-agent-harness--pending-prompts (list prompt))))
    ('plan
     ;; Resolve/create the plan file and read the prompt files BEFORE
     ;; flipping the mode so any failure (forbidden path, missing
     ;; prompt file) leaves the buffer in its previous state.
     (let* ((plan-file (gptel-agent-harness--ensure-plan-file))
            (prompts (list (gptel-agent-harness-commands--read-prompt-file
                            gptel-agent-harness-plan-prompt-file "Plan")
                           (gptel-agent-harness--substitute-plan-info
                            (gptel-agent-harness-commands--read-prompt-file
                             gptel-agent-harness-plan-mode-prompt-file "Plan mode")
                            plan-file))))
       ;; Start each planning round from an empty file, but only for
       ;; files owned by this session (inside
       ;; `gptel-agent-harness--plan-temp-dir'); a legacy cached
       ;; path outside it is left untouched.
       (when (string-prefix-p (gptel-agent-harness--plan-temp-dir) plan-file)
         (write-region "" nil plan-file nil 'silent))
       (setq gptel-agent-harness--mode 'plan)
       (setq gptel-agent-harness--plan-file plan-file)
       (setq gptel-agent-harness--pending-prompts prompts)))
    (_ (user-error "Unknown agent mode: %S" mode)))
  (force-mode-line-update)
  (when gptel-agent-harness-verbose
    (message "gptel-agent-harness: switched to %s mode" mode)))

(defun gptel-agent-harness-toggle-mode ()
  "Toggle the current gptel buffer between plan and build mode.

See `gptel-agent-harness-set-mode' for the queued prompt injection
behavior."
  (interactive)
  (if (eq gptel-agent-harness--mode 'plan)
      (gptel-agent-harness-set-mode 'build)
    (gptel-agent-harness-set-mode 'plan)))

(defun gptel-agent-harness--request-injection-position (data)
  "Return the injection position for mode-switch prompt text in DATA.

Injects immediately before the user's plain-text request message when
it is the last message, keeping the request as the final message.
Otherwise appends at the end — this happens when switching modes
mid-request (during tool rounds), where the last message is a tool
result; inserting a user message between a tool call and its result
would break backend message ordering (e.g. Anthropic tool blocks).

Handles the message containers of all supported backends: :messages
\(OpenAI-compatible/Anthropic), :input (OpenAI Responses) and
:contents (Gemini)."
  (let* ((raw (or (plist-get data :messages)
                  (plist-get data :input)
                  (plist-get data :contents)
                  []))
         (messages (if (vectorp raw) raw []))
         (last (and (> (length messages) 0)
                    (aref messages (1- (length messages))))))
    (if (and (plistp last)
             (equal (plist-get last :role) "user")
             (stringp (or (plist-get last :content)
                          (plist-get last :parts))))
        (max 0 (1- (length messages)))
      (length messages))))

(defun gptel-agent-harness--inject-pending-prompts (fsm)
  "Inject plan-mode constraints into FSM's request data.

For top-level requests, injects the queued mode-switch prompts
\(see `gptel-agent-harness-set-mode') as separate user messages
immediately before the user's own request message (appending when the
last message is a tool result), and consumes the queue so they are
sent exactly once.

For sub-agent requests (FSMs using `gptel-agent-request--handlers'),
when the buffer is in plan mode, injects
`gptel-agent-harness-plan-mode-subagent-reminder' (with the plan file
path substituted) so delegated agents respect the read-only phase.
The reminder is injected at most once per sub-agent FSM, and the
pending queue is left untouched for the next top-level request.

Harness-internal requests (compaction, title generation, summary —
the default `gptel-request--handlers') are never injected into."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend))
         (data (plist-get info :data)))
    (when (and backend (plistp data))
      (condition-case err
          (if (gptel-agent-harness--top-level-p fsm)
              (gptel-agent-harness--with-fsm-buffer fsm
                (when gptel-agent-harness--pending-prompts
                  (let* ((prompts gptel-agent-harness--pending-prompts)
                         (position (gptel-agent-harness--request-injection-position
                                    data)))
                    ;; Inject first, then consume the queue — if injection
                    ;; errors, the queue survives for the next attempt.
                    (gptel--inject-prompt
                     backend data
                     (mapcar (lambda (text) (list :role "user" :content text)) prompts)
                     position)
                    (setq gptel-agent-harness--pending-prompts nil)
                    (when gptel-agent-harness-verbose
                      (message "gptel-agent-harness: injected %d top-level mode prompt(s)"
                               (length prompts))))))
            (when (and (gptel-agent-harness--sub-agent-p fsm)
                       (not (plist-get info :harness-injected))
                       (gptel-agent-harness--with-fsm-buffer fsm
                         (eq gptel-agent-harness--mode 'plan)))
              ;; Inject first, then mark — if injection fails the flag is
              ;; not set and the next WAIT transition retries.
              (gptel--inject-prompt
               backend data
               (list (list :role "user"
                           :content
                           (format-spec
                            gptel-agent-harness-plan-mode-subagent-reminder
                            (format-spec-make
                             ?s (gptel-agent-harness--with-fsm-buffer fsm
                                  (or gptel-agent-harness--plan-file "")))
                            'ignore)))
               (gptel-agent-harness--request-injection-position data))
              (setf (gptel-fsm-info fsm)
                    (plist-put info :harness-injected t))
              (when gptel-agent-harness-verbose
                (message "gptel-agent-harness: injected plan-mode reminder into sub-agent request"))))
        (error
         (when gptel-agent-harness-verbose
           (message "gptel-agent-harness: prompt injection failed — %s"
                    (error-message-string err))))))))

;;;; FSM Supervisor
(defun gptel-agent-harness--update-context-ratio (fsm)
  "Compute and store context ratio for FSM's buffer.
Also stores the raw (uncalibrated) estimate for calibration."
  (when (and (gptel-agent-harness--top-level-p fsm)
             ;; :data must be a plist (not a buffer during assembly)
             (not (bufferp (plist-get (gptel-fsm-info fsm) :data))))
    (let* ((raw-estimate (gptel-agent-harness--context-tokens-from-data fsm))
           (calibration (or (gptel-agent-harness--with-fsm-buffer fsm
                             gptel-agent-harness--token-calibration)
                            1.0))
           (ratio (/ (* raw-estimate calibration)
                     (float (gptel-agent-harness--context-window fsm)))))
      (gptel-agent-harness--with-fsm-buffer fsm
        (setq gptel-agent-harness--context-ratio ratio)
        (setq gptel-agent-harness--last-raw-estimate raw-estimate)
        (force-mode-line-update)))))


;;;; Extracted transition handlers

(defun gptel-agent-harness--handle-wait-state (orig-fn machine new-state)
  "Handle WAIT state transition for MACHINE.

Checks context usage ratio and triggers compaction when the
threshold is exceeded.  Injects any queued build/plan mode prompts
into the outgoing request before it is sent.  Returns non-nil if
compaction was started, meaning the caller should skip its own
transition, and nil otherwise.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the state to transition to."
  (condition-case err
      (gptel-agent-harness--update-context-ratio machine)
    (error
     (when gptel-agent-harness-verbose
       (message "gptel-agent-harness: context ratio error (WAIT) — %s"
                (error-message-string err)))))
  (if (gptel-agent-harness--need-compaction-p machine)
      ;; `gptel-abort' inside --compact removes FSM from
      ;; `gptel--request-alist' and transitions it to ABRT, so
      ;; skip the normal transition when compaction starts.  Pending
      ;; mode prompts are preserved so the resumed request still
      ;; receives them.
      (let ((compacted
             (condition-case err
                 (gptel-agent-harness--compact machine)
               (error
                (when gptel-agent-harness-verbose
                  (message "gptel-agent-harness: compaction error (WAIT) — %s"
                           (error-message-string err)))
                nil))))
        ;; Only run the real transition when compaction did NOT start.
        ;; If compaction started, `gptel-abort' already transitioned the
        ;; FSM to ABRT, so we must not fire it again.
        (unless compacted
          (gptel-agent-harness--inject-pending-prompts machine)
          (funcall orig-fn machine new-state)))
    (gptel-agent-harness--inject-pending-prompts machine)
    (funcall orig-fn machine new-state)))

(defun gptel-agent-harness--handle-terminal-state (orig-fn machine new-state)
  "Handle terminal (DONE/ERRS) state transition for MACHINE.

Either nudges the LLM to keep going (redirecting to WAIT) or lets
the FSM terminate.  When compaction is in progress, always lets the
FSM terminate without interference.

On ERRS (error), drops the incomplete round from the buffer via
`gptel-agent-harness--salvage-buffer' so the next send starts clean.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the state to transition to."
  ;; If compaction is in progress, let the FSM terminate without
  ;; interference — don't clear the flag or nudge.  The aborted
  ;; FSM must die quietly while compaction handles the resume.
  (if (gptel-agent-harness--with-fsm-buffer machine
        gptel-agent-harness--compacting-p)
      (funcall orig-fn machine new-state)
    (if (and (gptel-agent-harness--agentic-p machine)
             (gptel-agent-harness--top-level-p machine)
             (gptel-agent-harness--can-nudge-p machine))
        (let ((nudged
               (condition-case err
                   (gptel-agent-harness--nudge machine)
                 (error
                  (when gptel-agent-harness-verbose
                    (message "gptel-agent-harness: terminal-state nudge error — %s"
                             (error-message-string err)))
                  nil))))
          ;; Nudge succeeded → redirect to WAIT.  Otherwise (malformed
          ;; :data or a throwing nudge) let the FSM terminate cleanly
          ;; with its original state.  ORIG-FN is called exactly once.
          (if nudged
              (funcall orig-fn machine 'WAIT)
            ;; Nudge failed or not applicable — salvage on ERRS.
            (when (eq (or new-state (gptel--fsm-next machine)) 'ERRS)
              (gptel-agent-harness--salvage-buffer machine))
            (funcall orig-fn machine new-state)))
      ;; Can't nudge — salvage on ERRS before terminating.
      (when (eq (or new-state (gptel--fsm-next machine)) 'ERRS)
        (gptel-agent-harness--salvage-buffer machine))
      (funcall orig-fn machine new-state))))

(defun gptel-agent-harness--transition-advice (orig-fn machine &optional new-state)
  "Around advice for `gptel--fsm-transition'.

Delegates to `gptel-agent-harness--handle-wait-state' and
`gptel-agent-harness--handle-terminal-state' to keep nesting
shallow.

Resets counter when LLM makes tool calls.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the optional new state to transition to."
  (let ((target (or new-state (gptel--fsm-next machine))))
    (pcase target
      ;; Before next LLM turn — check if compaction needed
      ('WAIT
       (gptel-agent-harness--handle-wait-state orig-fn machine new-state))
      ;; LLM attempts to finish — possibly nudge instead
      ((guard (gptel-agent-harness--terminal-p target))
       (gptel-agent-harness--handle-terminal-state orig-fn machine new-state))
      ;; User abort — salvage the buffer before terminating
      ('ABRT
       (gptel-agent-harness--salvage-buffer machine)
       (funcall orig-fn machine new-state))
      ;; Tool execution means real progress
      ((or 'TOOL 'TPRE)
       (funcall orig-fn machine new-state)
       (when (gptel-agent-harness--top-level-p machine)
         (gptel-agent-harness--reset-nudges machine)))
      ;; Everything else
      (_
       (funcall orig-fn machine new-state)))))

;;;###autoload
(defun gptel-agent-harness-supervisor-enable ()
  "Enable supervisor for the current buffer."
  (advice-add 'gptel--fsm-transition
              :around #'gptel-agent-harness--transition-advice)
  (gptel-agent-harness--setup-plan-cleanup))

(defun gptel-agent-harness-supervisor-disable ()
  "Disable supervisor for the current buffer."
  (advice-remove 'gptel--fsm-transition
                 #'gptel-agent-harness--transition-advice)
  (gptel-agent-harness--teardown-plan-cleanup)
  (gptel-agent-harness--cleanup-plan-file))

(provide 'gptel-agent-harness-supervisor)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-supervisor.el ends here
