;;; gptel-agent-harness.el --- Autonomous coding-agent harness for gptel-agent -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: Kiro-cli:claude-opus-4-8, gptel-agent-harness:deepseek-v4-flash
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Version: 0.3
;; Created: 2026-07-15
;; Keywords: programming, convenience, ai, agent
;; Package-Requires: ((emacs "29.1") (compat "30.1.0.0") (gptel "0.9.9") (gptel-agent "0.0.1"))

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

;; Autonomous coding-agent harness for gptel-agent.

;;; Code:

(require 'gptel-agent)
(require 'gptel-agent-harness-tools)
(require 'gptel-agent-harness-agent)
(require 'gptel-agent-harness-session)
(require 'gptel-agent-harness-commands)
(require 'gptel-agent-harness-fsm)
(require 'cl-lib)
(require 'format-spec)

;; Silence byte-compiler — defined in gptel-agent-tools.el
(defvar gptel-agent-request--handlers)

;;;; User Options
(defgroup gptel-agent-harness nil
  "Agent execution harness for gptel."
  :group 'gptel
  :prefix "gptel-agent-harness-")

(defcustom gptel-agent-harness-verbose nil
  "Log harness actions."
  :type 'boolean
  :group 'gptel-agent-harness)

;;;; Completion Supervision
(defcustom gptel-agent-harness-max-nudges 2
  "Maximum consecutive completion nudges.

Reset whenever the LLM performs tool calls."
  :type 'integer
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-nudge-message
  "Review the original user request and the Task Completion Rules in the context. \
Verify whether all completion criteria are satisfied. \
If all criteria are already satisfied and verified, finish the task normally. \
Otherwise, continue working and make the necessary tool calls. Do not stop until the rules are fully met."
  "Message injected when the agent tries to stop."
  :type 'string
  :group 'gptel-agent-harness)

;;;; Context Management
(defcustom gptel-agent-harness-context-trigger 0.70
  "Compact when context usage exceeds this ratio."
  :type 'float
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-context-windows
  '(("gpt-5-mini" . 128000)
    ("gpt-5" . 400000)
    ("claude" . 200000)
    ("deepseek-v3" . 128000)
    ("deepseek-v4" . 1000000)
    ("qwen3.5" . 131072)
    ("qwen3" . 131072)
    ("glm-5.2" . 1000000)
    ("glm-5.1" . 128000)
    ("kimi-k2.7" . 256000)
    ("kimi" . 128000))
  "Known model context window sizes.

Entries are matched in order using `string-match-p', so place
more specific patterns before general ones."
  :type '(alist :key-type string :value-type integer)
  :group 'gptel-agent-harness)

(defconst gptel-agent-harness-compact-prompt-file
  (or (locate-file "prompts/compact.md" load-path)
      (error "Gptel-agent-harness prompt not found"))
  "File path for the context compaction prompt.")

(defun gptel-agent-harness--read-compact-prompt ()
  "Read the compact prompt from `gptel-agent-harness-compact-prompt-file'."
  (if (file-exists-p gptel-agent-harness-compact-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-compact-prompt-file)
        (buffer-string))
    (error "Compact prompt file not found: %s" gptel-agent-harness-compact-prompt-file)))

(defconst gptel-agent-harness-plan-prompt-file
  (or (locate-file "prompts/plan.md" load-path)
      (error "Gptel-agent-harness prompt not found"))
  "File path for the plan mode instruction prompt.")

(defconst gptel-agent-harness-plan-mode-prompt-file
  (or (locate-file "prompts/plan-mode.md" load-path)
      (error "Gptel-agent-harness prompt not found"))
  "File path for the plan mode workflow prompt.")

(defconst gptel-agent-harness-build-switch-prompt-file
  (or (locate-file "prompts/build-switch.md" load-path)
      (error "Gptel-agent-harness prompt not found"))
  "File path for the switch-back-to-build prompt.")

;;;; Internal State
(defvar-local gptel-agent-harness--nudge-count 0
  "Current completion nudge count.")

(defvar-local gptel-agent-harness--compacting-p nil
  "Non-nil when compaction is in progress for this buffer.")

(defvar-local gptel-agent-harness--context-ratio nil
  "Last computed context usage ratio (0.0–1.0) for this buffer.")

(defvar-local gptel-agent-harness--token-calibration 1.0
  "Calibration factor: actual_tokens / estimated_tokens.

Updated after each LLM response using the API-reported input token
count.  Applied to future estimations to reduce drift.")

(defvar-local gptel-agent-harness--last-raw-estimate nil
  "Raw token estimate from the last context ratio computation.
Used by `gptel-agent-harness--update-token-calibration' to compare
against the actual token count reported by the API.")

(defvar-local gptel-agent-harness--mode 'build
  "Current agent mode in this buffer: `build' or `plan'.
The default is build mode; see `gptel-agent-harness-set-mode'.")

(defvar-local gptel-agent-harness--pending-prompts nil
  "Prompt strings queued for injection into the next top-level request.
Populated when the agent mode is switched and consumed exactly once
by the following request; see `gptel-agent-harness--inject-pending-prompts'.")

;;;; FSM Helpers

(defmacro gptel-agent-harness--with-fsm-buffer (fsm &rest body)
  "Execute BODY in FSM's associated buffer if it is live.
Binds nothing extra; use `current-buffer' inside BODY."
  (declare (indent 1) (debug (form body)))
  (let ((buf (gensym "buf")))
    `(let ((,buf (gptel-agent-harness--buffer ,fsm)))
       (when (and ,buf (buffer-live-p ,buf))
         (with-current-buffer ,buf ,@body)))))

(defun gptel-agent-harness--buffer (fsm)
  "Return buffer associated with FSM."
  (plist-get (gptel-fsm-info fsm) :buffer))

(defun gptel-agent-harness--get-nudges (fsm)
  "Return current nudge count for FSM's buffer."
  (or (gptel-agent-harness--with-fsm-buffer fsm
        gptel-agent-harness--nudge-count)
      0))

(defun gptel-agent-harness--inc-nudges (fsm)
  "Increment and return nudge count for FSM's buffer."
  (gptel-agent-harness--with-fsm-buffer fsm
    (cl-incf gptel-agent-harness--nudge-count)))

(defun gptel-agent-harness--reset-nudges (fsm)
  "Reset nudge count for FSM's buffer to 0."
  (gptel-agent-harness--with-fsm-buffer fsm
    (setq gptel-agent-harness--nudge-count 0)))

(defun gptel-agent-harness--terminal-p (state)
  "Return non-nil if STATE is a terminal FSM state."
  (memq state '(DONE ERRS)))

(defun gptel-agent-harness--agentic-p (fsm)
  "Return non-nil when FSM has tools."
  (plist-get (gptel-fsm-info fsm) :tools))

(defun gptel-agent-harness--top-level-p (fsm)
  "Return non-nil if FSM is a top-level (user-initiated) session.
Sub-agent FSMs use `gptel-agent-request--handlers' instead of
`gptel-send--handlers'."
  (eq (gptel-fsm-handlers fsm) gptel-send--handlers))

(defun gptel-agent-harness--can-nudge-p (fsm)
  "Return non-nil when nudge budget remains for FSM.

A dead (or missing) session buffer has NO budget: the nudge counter is
buffer-local, so `gptel-agent-harness--inc-nudges' cannot record
anything and `gptel-agent-harness--get-nudges' would keep reporting 0 —
every terminal transition would be redirected to WAIT and fire another
request, forever.  `gptel--handle-wait' does not check buffer liveness,
so that loop would keep hitting the API after the user killed the
buffer.  Failing closed here bounds it."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (and buf
         (buffer-live-p buf)
         (< (gptel-agent-harness--get-nudges fsm)
            gptel-agent-harness-max-nudges))))

;;;; Completion Actions
(defun gptel-agent-harness--nudge (fsm)
  "Inject nudge message into FSM prompt data and bump counter.

Returns non-nil iff the nudge was injected, nil otherwise.  Never
signals: if the FSM's `:data' is not a plist (e.g. still a prompt
buffer while gptel assembles the query) or `gptel--inject-prompt'
errors, the failure is logged (when verbose) and nil is returned so
the caller can fall back to a clean terminal transition instead of
wedging the FSM."
  (let ((info (gptel-fsm-info fsm)))
    (gptel-agent-harness--inc-nudges fsm)
    (let ((data (plist-get info :data)))
      (when (plistp data)
        (condition-case err
            (progn
              (gptel--inject-prompt
               (plist-get info :backend)
               data
               (list :role "user" :content gptel-agent-harness-nudge-message))
              (when gptel-agent-harness-verbose
                (message "gptel-agent-harness: completion nudge %d/%d — asking LLM to review task"
                         (gptel-agent-harness--get-nudges fsm)
                         gptel-agent-harness-max-nudges))
              t)
          (error
           (when gptel-agent-harness-verbose
             (message "gptel-agent-harness: nudge failed — %s"
                      (error-message-string err)))
           nil))))))

;;;; Context Window Management
(defun gptel-agent-harness--model-name (&optional fsm)
  "Return the model name for FSM, or the current buffer's if FSM is nil.
Prefers the model recorded in FSM's info (set by gptel at request
time), falling back to the dynamic `gptel-model' so callers without
an FSM (e.g. tests) keep working."
  (let ((model (or (and fsm (plist-get (gptel-fsm-info fsm) :model))
                   gptel-model)))
    (cond ((symbolp model)
           (symbol-name model))
          ((stringp model)
           model)
          (t ""))))

(defun gptel-agent-harness--context-window (&optional fsm)
  "Return the context window for FSM's model, or the current buffer's.
See `gptel-agent-harness--model-name' for the model resolution."
  (let ((model (gptel-agent-harness--model-name fsm)))
    (or
     (cdr (seq-find
           (lambda (entry) (string-match-p (car entry) model))
           gptel-agent-harness-context-windows))
     ;; safe fallback
     32768)))

(defun gptel-agent-harness--cjk-char-p (c)
  "Return non-nil if C is a CJK or full-width character."
  (or (and (>= c #x3000) (<= c #x9fff))    ; CJK + kana + punctuation
      (and (>= c #xf900) (<= c #xfaff))    ; CJK compat ideographs
      (and (>= c #xff00) (<= c #xffef))    ; full-width forms
      (and (>= c #x20000) (<= c #x2fa1f)))) ; CJK extensions B–F

(defun gptel-agent-harness--estimate-tokens (start end)
  "Estimate tokens between START and END.
Uses:
- Latin: ~4 chars/token
- CJK/full-width: ~2 chars/token"
  (let* ((text (buffer-substring-no-properties start end))
         (len (length text))
         (cjk-count 0))
    (dotimes (i len)
      (when (gptel-agent-harness--cjk-char-p (aref text i))
        (setq cjk-count (1+ cjk-count))))
    (round (+ (/ (float (- len cjk-count)) 4.0)
              (/ (float cjk-count) 2.0)))))


(defun gptel-agent-harness--extract-system-content (system)
  "Insert SYSTEM prompt text into current buffer.
Handles string, plist with :parts, vector, and list forms.
Malformed SYSTEM (non-plist parts, non-sequence containers) is
rendered defensively and never signals."
  (cond
   ((stringp system) (insert system))
   ((and (plistp system) (plist-get system :parts))
    (let ((parts (plist-get system :parts)))
      (cl-loop for part across (if (sequencep parts) (vconcat parts) [])
               do (insert (if (plistp part)
                              (or (plist-get part :text) (format "%S" part))
                            (format "%S" part))
                          "\n"))))
   ((vectorp system)
    (cl-loop for part across system
             do (insert (if (plistp part)
                            (or (plist-get part :text) (format "%S" part))
                          (format "%S" part))
                        "\n")))
   ((listp system)
    (dolist (s system)
      (insert (or (and (stringp s) s)
                  (and (plistp s) (plist-get s :text))
                  (format "%s" s))
              "\n")))))

(defun gptel-agent-harness--extract-content-openai (content)
  "Insert OpenAI-style string CONTENT into current buffer."
  (insert content))

(defun gptel-agent-harness--extract-content-gemini (content)
  "Insert Gemini-style vector CONTENT into current buffer.
Iterates over parts, extracting :thinking and :text fields.
Non-plist parts are rendered defensively and never signal."
  (cl-loop for part across content
           do (insert (or (and (stringp part) part)
                          (and (plistp part)
                               (stringp (plist-get part :thinking))
                               (plist-get part :thinking))
                          (and (plistp part)
                               (stringp (plist-get part :text))
                               (plist-get part :text))
                          (format "%S" part)))))

(defun gptel-agent-harness--extract-content-anthropic (content)
  "Insert Anthropic-style list CONTENT into current buffer.
Handles :thinking, :text, and :arguments blocks.
Non-plist parts are rendered defensively and never signal."
  (dolist (part content)
    (cond
     ((stringp part) (insert part))
     ((and (plistp part)
           (plist-get part :thinking)
           (stringp (plist-get part :thinking)))
      (insert (plist-get part :thinking)))
     ((and (plistp part)
           (plist-get part :text)
           (stringp (plist-get part :text)))
      (insert (plist-get part :text)))
     ((and (plistp part)
           (plist-get part :arguments)
           (stringp (plist-get part :arguments)))
      (insert (plist-get part :arguments)))
     (t (insert (format "%S" part))))))

(defun gptel-agent-harness--extract-content (content)
  "Dispatch CONTENT insertion based on its type.
Delegates to OpenAI, Gemini, or Anthropic-specific extractors.
Malformed CONTENT is rendered defensively and never signals."
  (cond
   ((stringp content)
    (gptel-agent-harness--extract-content-openai content))
   ((vectorp content)
    (gptel-agent-harness--extract-content-gemini content))
   ((proper-list-p content)
    (gptel-agent-harness--extract-content-anthropic content))
   (t (insert (format "%S" content)))))

(defun gptel-agent-harness--extract-tool-calls (tool-calls)
  "Insert TOOL-CALLS names and arguments into current buffer.
Handles both vector and list representations.
Non-plist tool-call entries are skipped defensively and never signal."
  (when (or (vectorp tool-calls) (proper-list-p tool-calls))
    (dolist (tc (if (vectorp tool-calls)
                    (append tool-calls nil)
                  tool-calls))
      (when (plistp tc)
        (let ((func (plist-get tc :function)))
          (when (plistp func)
            (let ((name (plist-get func :name))
                  (args (plist-get func :arguments)))
              (when (stringp name) (insert name "\n"))
              (when (stringp args) (insert args "\n")))))))))

(cl-defun gptel-agent-harness--context-tokens-from-data (fsm)
  "Estimate tokens from the full prompt payload of FSM.
Includes system prompt, all user/assistant/tool messages, and
tool definitions (schemas).
When `gptel-agent-harness-verbose' is non-nil, logs the
serialized content to *gptel-agent-harness-debug*."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (and (plistp data)
                        (or (plist-get data :messages)
                            (plist-get data :input)
                            (plist-get data :contents))))
         (system (and (plistp data)
                      (or (plist-get data :system)
                          (plist-get data :system_instruction)
                          (plist-get data :instructions)
                          (plist-get data :systemInstruction)
                          "")))
         (total 0)
         (debug-buf (when gptel-agent-harness-verbose
                      (get-buffer-create "*gptel-agent-harness-debug*"))))
    (unless (plistp data)
      (cl-return-from gptel-agent-harness--context-tokens-from-data 0))
    (when debug-buf
      (with-current-buffer debug-buf
        (erase-buffer)
        (insert "=== Context Token Estimation ===\n\n")))
    (with-temp-buffer
      (gptel-agent-harness--extract-system-content system)
      (setq total (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
      (when debug-buf
        (let ((text (buffer-string)))
          (with-current-buffer debug-buf
            (insert "--- [system] ---\n" text "\n\n"))))
      (when (and (vectorp messages)
                 (cl-every #'plistp messages))
        (cl-loop
         for msg across messages
         for role = (plist-get msg :role)
         for content = (or (plist-get msg :content)
                           (plist-get msg :parts))
         for reasoning = (plist-get msg :reasoning_content)
         for tool-calls = (plist-get msg :tool_calls)
         do (erase-buffer)
         (when (stringp reasoning)
           (insert reasoning "\n"))
         (gptel-agent-harness--extract-content content)
         (when tool-calls
           (gptel-agent-harness--extract-tool-calls tool-calls))
         (cl-incf total
                  (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
         (when debug-buf
           (let ((text (buffer-string)))
             (with-current-buffer debug-buf
               (insert (format "--- [%s] ---\n%s\n\n" role text)))))))
      (when-let* ((tools (or (plist-get data :tools)
                             (let ((tool-config (plist-get data :toolConfig)))
                               (and (plistp tool-config)
                                    (plist-get tool-config :tools))))))
        (erase-buffer)
        (insert (format "%S" tools))
        (cl-incf total
                 (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
        (when debug-buf
          (let ((text (buffer-string)))
            (with-current-buffer debug-buf
              (insert (format "--- [tools] (%d definitions) ---\n%s\n\n"
                              (if (sequencep tools) (length tools) 0)
                              text)))))))
    (when debug-buf
      (with-current-buffer debug-buf
        (insert (format "=== Total estimated tokens: %d ===\n" total)))
      (message "gptel-agent-harness: token estimation logged to *gptel-agent-harness-debug*"))
    total))

(defun gptel-agent-harness--context-ratio-for-fsm (fsm)
  "Return context usage ratio based on full prompt payload of FSM.
Applies the calibration factor from `gptel-agent-harness--token-calibration'."
  (let* ((calibration (or (gptel-agent-harness--with-fsm-buffer fsm
                            gptel-agent-harness--token-calibration)
                          1.0))
         (estimated (gptel-agent-harness--context-tokens-from-data fsm))
         (calibrated (* estimated calibration)))
    (/ calibrated (float (gptel-agent-harness--context-window fsm)))))

(defun gptel-agent-harness--update-token-calibration (&rest _)
  "Update token calibration factor using the LLM-reported input tokens.

Reads `gptel--token-usage' (set by gptel after each response) and
compares the actual input token count to the raw estimate stored
during the last context ratio computation.

The raw estimate covers the same content as actual input tokens:
system prompt, all messages (including previous assistant turns
and tool results), and tool definitions.  The current response's
output tokens are NOT included since they were not part of what
was estimated.

The new calibration factor is:

  actual_input / raw_estimated_tokens

This is called via `gptel-post-response-functions'."
  (when-let* ((usage (and (boundp 'gptel--token-usage) gptel--token-usage))
              (request-usage (car usage))
              (actual-input (plist-get request-usage :input))
              (raw-estimate gptel-agent-harness--last-raw-estimate))
    (when (and (numberp actual-input)
               (> actual-input 0)
               (numberp raw-estimate) (> raw-estimate 0))
      (let* ((new-ratio (/ (float actual-input) (float raw-estimate))))
        ;; Clamp to reasonable range to avoid pathological values
        (setq new-ratio (max 0.5 (min 3.0 new-ratio)))
        (setq gptel-agent-harness--token-calibration new-ratio)
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness: calibration updated — input:%d est:%d ratio:%.2f"
                   actual-input raw-estimate new-ratio))))))

(defun gptel-agent-harness--need-compaction-p (fsm)
  "Return non-nil when compaction is needed for FSM.
Uses the cached `gptel-agent-harness--context-ratio' if available."
  (and (gptel-agent-harness--agentic-p fsm)
       (gptel-agent-harness--top-level-p fsm)
       (gptel-agent-harness--with-fsm-buffer fsm
         (and (not gptel-agent-harness--compacting-p)
              gptel-agent-harness--context-ratio
              (> gptel-agent-harness--context-ratio
                 gptel-agent-harness-context-trigger)))))

;;;; Automatic Compaction
(defcustom gptel-agent-harness-compact-header
  "**[Compacted Summary]**\n\n"
  "Header inserted at the top of the buffer after compaction.
Helps distinguish the summary from original conversation text."
  :type 'string
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-compact-separator
  "\n\n---\n\n**[Context compacted]**\n\n---\n\n"
  "Separator inserted after compaction to visually indicate the boundary."
  :type 'string
  :group 'gptel-agent-harness)

(defun gptel-agent-harness--content-to-text (content)
  "Return the plain text of message CONTENT as a string, or nil.

CONTENT may be a plain string, or a vector/list of message parts as
produced by multimodal backends (OpenAI multipart vectors, Anthropic
content-block lists, Gemini :parts).  Text is gathered from :text
fields and bare strings; non-text parts (e.g. images) are ignored.
Returns nil when no text is found."
  (cond
   ((stringp content) content)
   ((null content) nil)
   ((vectorp content)
    (let ((texts nil))
      (mapc (lambda (part)
              (cond
               ((stringp part) (push part texts))
               ((and (plistp part) (stringp (plist-get part :text)))
                (push (plist-get part :text) texts))))
            (append content nil))
      (when texts
        (let ((s (mapconcat #'identity (nreverse texts) "")))
          (unless (string-empty-p s) s)))))
   ((proper-list-p content)
    (let ((texts nil))
      (mapc (lambda (part)
              (cond
               ((stringp part) (push part texts))
               ((and (plistp part) (stringp (plist-get part :text)))
                (push (plist-get part :text) texts))))
            content)
      (when texts
        (let ((s (mapconcat #'identity (nreverse texts) "")))
          (unless (string-empty-p s) s)))))
   (t nil)))

(defun gptel-agent-harness--last-user-request (fsm)
  "Return the last user message text from FSM, excluding nudge messages.

Returns a plain string suitable for re-sending, or nil if none found.
Multimodal message content (vectors/lists of parts, or Gemini :parts)
is reduced to its text via `gptel-agent-harness--content-to-text', so
the caller can safely `insert' the result."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (and (plistp data)
                        (or (plist-get data :messages)
                            (plist-get data :input)      ; OpenAI Responses API
                            (plist-get data :contents)))) ; Gemini
         (nudge gptel-agent-harness-nudge-message))
    (when (vectorp messages)
      (cl-loop for i downfrom (1- (length messages)) to 0
               for msg = (aref messages i)
               for text = (and (plistp msg)
                               (equal (plist-get msg :role) "user")
                               (gptel-agent-harness--content-to-text
                                (or (plist-get msg :content)
                                    (plist-get msg :parts))))
               when (and text (not (equal text nudge)))
               return text))))

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

(cl-defun gptel-agent-harness--compact (fsm)
  "Abort and run context compaction for FSM.
Drops the current round, aborts the session, calls `compact-buffer'
\(the proven manual compaction logic), then resumes with the recent
user requests.
Return non-nil if compaction was initiated, nil otherwise."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (unless (and buf (buffer-live-p buf))
      (when gptel-agent-harness-verbose
        (message "gptel-agent-harness: compact skipped — buffer not live"))
      (cl-return-from gptel-agent-harness--compact nil))
    (with-current-buffer buf
      (let ((request (gptel-agent-harness--last-user-request fsm)))
        (unless request
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness: compact skipped — no user request to resume"))
          (cl-return-from gptel-agent-harness--compact nil))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness: compacting context %.1f%%"
                   (* 100 (gptel-agent-harness--context-ratio-for-fsm fsm))))
        ;; Mark compaction in progress BEFORE aborting, so the terminal
        ;; transition handler won't nudge the aborted FSM back to life.
        (setq gptel-agent-harness--compacting-p t)
        ;; Drop current round (last response onward).
        (save-excursion
          (goto-char (point-max))
          (when-let* ((props (text-property-search-backward 'gptel 'response t))
                      (resp-start (prop-match-beginning props)))
            (delete-region resp-start (point-max))))
        ;; Abort current session.
        (gptel-abort buf)
        (gptel-agent-harness--strip-compact-prefix)
        (setq-local gptel-agent-compact-prompt
                    (gptel-agent-harness--read-compact-prompt))
        (let ((resume-buf buf)
              (resume-request request))
          (condition-case err
              (gptel-agent-harness-commands-compact
               (lambda (&optional info)
                 (when (buffer-live-p resume-buf)
                   (with-current-buffer resume-buf
                     (kill-local-variable 'gptel-agent-compact-prompt)
                     (setq gptel-agent-harness--nudge-count 0)
                     (if (and info (plist-get info :error))
                         (progn
                           (setq gptel-agent-harness--compacting-p nil)
                           (when gptel-agent-harness-verbose
                             (message "gptel-agent-harness: compaction failed, not resuming")))
                       ;; Success: insert frame + resume requests, then send.
                       (condition-case resume-err
                           (progn
                             (gptel-agent-harness--insert-compact-frame)
                             (goto-char (point-max))
                             (insert resume-request "\n")
                             ;; Clear compacting-p AFTER gptel-send returns, so
                             ;; the WAIT transition during send still sees the
                             ;; flag and won't re-trigger compaction.
                             (gptel-send)
                             (setq gptel-agent-harness--compacting-p nil))
                         (error
                          (setq gptel-agent-harness--compacting-p nil)
                          (when gptel-agent-harness-verbose
                            (message "gptel-agent-harness: resume failed — %s"
                                     (error-message-string resume-err))))))))))
            (error
             (kill-local-variable 'gptel-agent-compact-prompt)
             (setq gptel-agent-harness--compacting-p nil)
             (when gptel-agent-harness-verbose
               (message "gptel-agent-harness: compact failed to start — %s"
                        (error-message-string err)))
             (cl-return-from gptel-agent-harness--compact nil))))
        ;; Compaction request initiated.
        t))))

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
           (calibrated (* raw-estimate calibration))
           (ratio (/ calibrated (float (gptel-agent-harness--context-window fsm)))))
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
            (funcall orig-fn machine new-state)))
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
      ;; Tool execution means real progress
      ((or 'TOOL 'TPRE)
       (funcall orig-fn machine new-state)
       (when (gptel-agent-harness--top-level-p machine)
         (gptel-agent-harness--reset-nudges machine)))
      ;; Everything else
      (_
       (funcall orig-fn machine new-state)))))

;;;; Mode-line Context Ratio Display

(defcustom gptel-agent-harness-show-context-ratio t
  "Whether to show context usage ratio in the mode-line."
  :type 'boolean
  :group 'gptel-agent-harness)

(defun gptel-agent-harness--mode-indicator ()
  "Return a propertized string showing the current build/plan mode."
  (let* ((plan-p (eq gptel-agent-harness--mode 'plan))
         (queued (and plan-p gptel-agent-harness--pending-prompts))
         (text (if plan-p " [Plan]" " [Build]")))
    (propertize text 'face (if plan-p 'warning 'success)
                'help-echo (if plan-p
                               (if queued
                                   "Agent mode: plan — plan prompts queued for the next request"
                                 "Agent mode: plan — read-only phase; only the plan file is writable")
                             "Agent mode: build"))))

(defun gptel-agent-harness--context-ratio-indicator ()
  "Return a propertized string showing context usage ratio.
Returns empty string if ratio is not yet computed or display is disabled."
  (if (and gptel-agent-harness-show-context-ratio
           gptel-agent-harness--context-ratio)
      (let* ((pct (round (* 100 gptel-agent-harness--context-ratio)))
             (threshold-pct (round (* 100 gptel-agent-harness-context-trigger)))
             (face (cond
                    ((>= pct 80) 'error)
                    ((and (>= pct 50) (< pct 80)) 'warning)
                    (t 'success)))
             ;; Use %%%% so `format' produces "%%", which mode-line
             ;; renders as a literal "%" (since % is a mode-line format spec).
             (text (format " [Ctx:%d%%%%/%d%%%%]" pct threshold-pct)))
        (propertize text 'face face
                    'help-echo (format "Context window usage: %d%%\nCompaction threshold: %d%%"
                                       pct
                                       threshold-pct)))
    ""))

(defvar-local gptel-agent-harness--mode-line-construct
  '(:eval (concat (gptel-agent-harness--mode-indicator)
                  (gptel-agent-harness--context-ratio-indicator)))
  "Mode-line construct showing agent mode and context usage ratio in gptel buffers.")
(put 'gptel-agent-harness--mode-line-construct 'risky-local-variable t)

(defun gptel-agent-harness--setup-mode-line ()
  "Add agent mode and context ratio indicators to mode-line.
Also hides `which-function-mode' display as it provides no useful info
in gptel buffers but consumes mode-line space."
  (unless (or (memq 'gptel-agent-harness--mode-line-construct mode-line-format)
              (memq 'gptel-agent-harness--mode-line-construct mode-line-misc-info))
    (let ((tail (memq 'mode-line-misc-info mode-line-format)))
      (if tail
          ;; Insert our construct just before mode-line-misc-info in mode-line-format
          (let ((before (cl-ldiff mode-line-format tail)))
            (setq-local mode-line-format
                        (append before
                                (list 'gptel-agent-harness--mode-line-construct)
                                tail)))
        ;; Fallback: prepend to mode-line-misc-info
        (setq-local mode-line-misc-info
                    (append '(gptel-agent-harness--mode-line-construct)
                            mode-line-misc-info)))))
  ;; Hide which-func from this buffer's mode-line without disabling the global mode
  (setq-local which-func-mode nil))

(defun gptel-agent-harness--teardown-mode-line ()
  "Remove context ratio indicator from mode-line for the current buffer.
Restores `which-func-mode' to its global default."
  (when (local-variable-p 'mode-line-format)
    (setq-local mode-line-format
                (delq 'gptel-agent-harness--mode-line-construct
                      mode-line-format))
    ;; If mode-line-format is back to the global value, kill the local binding
    (when (equal mode-line-format (default-value 'mode-line-format))
      (kill-local-variable 'mode-line-format)))
  ;; Also clean from mode-line-misc-info in case fallback path was used
  (when (memq 'gptel-agent-harness--mode-line-construct mode-line-misc-info)
    (setq-local mode-line-misc-info
                (delq 'gptel-agent-harness--mode-line-construct
                      mode-line-misc-info))
    (when (equal mode-line-misc-info (default-value 'mode-line-misc-info))
      (kill-local-variable 'mode-line-misc-info)))
  (kill-local-variable 'which-func-mode))

;;;; Token Calibration Setup

(defun gptel-agent-harness--setup-calibration ()
  "Set up token calibration for the current gptel buffer.
Adds hook to `gptel-post-response-functions' buffer-locally."
  (add-hook 'gptel-post-response-functions
            #'gptel-agent-harness--update-token-calibration
            nil t))

(defun gptel-agent-harness--teardown-calibration ()
  "Remove token calibration from the current gptel buffer."
  (remove-hook 'gptel-post-response-functions
               #'gptel-agent-harness--update-token-calibration
               t))

;;;; Task Completion Rules Context

(defconst gptel-agent-harness-task-completion-rules-file
  (or (locate-file "rules/task-completion-rules.md" load-path)
      (error "Gptel-agent-harness rules not found"))
  "File path of the task completion rules markdown file.")

(declare-function gptel-add-file "gptel-context")
(declare-function gptel-context-remove "gptel-context")

(defun gptel-agent-harness--add-task-completion-rules ()
  "Add the task completion rules file to the gptel context.
No-op when the file is missing or `gptel-add-file' is unavailable.
Adding is idempotent (`gptel-add-file' dedupes by path)."
  (when (and (file-exists-p gptel-agent-harness-task-completion-rules-file)
             (fboundp 'gptel-add-file))
    (gptel-add-file gptel-agent-harness-task-completion-rules-file)
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness: added task completion rules to context"))))

(defun gptel-agent-harness--remove-task-completion-rules ()
  "Remove the task completion rules file from the gptel context.
No-op when the file is not in `gptel-context' or
`gptel-context-remove' is unavailable."
  (when (and (boundp 'gptel-context)
             (assoc gptel-agent-harness-task-completion-rules-file
                    gptel-context #'equal)
             (require 'gptel-context nil t)
             (fboundp 'gptel-context-remove))
    (gptel-context-remove gptel-agent-harness-task-completion-rules-file)
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness: removed task completion rules from context"))))

;;;; Minor Mode

;;;###autoload
(define-minor-mode
  gptel-agent-harness-mode
  "Enable gptel-agent-harness mode.

Provides completion and context supervision."
  :global t
  :lighter " AgentHarness"
  (if gptel-agent-harness-mode
      (progn
        (gptel-agent-harness-tools-enable)
        (gptel-agent-harness-agent-enable)
        (gptel-agent-harness-fsm-enable)
        (advice-add 'gptel--fsm-transition
                    :around #'gptel-agent-harness--transition-advice)
        (when (boundp 'gptel-mode-map)
          (define-key gptel-mode-map (kbd "C-c C-k") #'gptel-abort))
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-calibration)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-plan-cleanup)
        (gptel-agent-harness--add-task-completion-rules)
        ;; Set up for already-open gptel buffers
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when gptel-mode
              (gptel-agent-harness--setup-mode-line)
              (gptel-agent-harness--setup-calibration)
              (gptel-agent-harness--setup-session)
              (gptel-agent-harness--setup-plan-cleanup))))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (gptel-agent-harness-agent-disable)
    (gptel-agent-harness-tools-disable)
    (gptel-agent-harness-fsm-disable)
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-harness--transition-advice)
    (when (boundp 'gptel-mode-map)
      (define-key gptel-mode-map (kbd "C-c C-k") nil))
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-calibration)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-plan-cleanup)
    (gptel-agent-harness--remove-task-completion-rules)
    ;; Clean up from all gptel buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when gptel-mode
          (gptel-agent-harness--teardown-mode-line)
          (gptel-agent-harness--teardown-calibration)
          (gptel-agent-harness--teardown-session)
          (gptel-agent-harness--teardown-plan-cleanup)
          (gptel-agent-harness--cleanup-plan-file)
          (setq gptel-agent-harness--context-ratio nil)
          (setq gptel-agent-harness--token-calibration 1.0)
          (setq gptel-agent-harness--last-raw-estimate nil)
          (setq gptel-agent-harness--mode 'build)
          (setq gptel-agent-harness--pending-prompts nil)
          (setq gptel-agent-harness--plan-file nil)
          (force-mode-line-update))))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness disabled"))))

(provide 'gptel-agent-harness)
;;; gptel-agent-harness.el ends here
