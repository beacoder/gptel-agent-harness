;;; gptel-agent-harness.el --- Agent execution harness for gptel-agent -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "29.1") (compat "30.1.0.0") (gptel-agent "0.0.1"))
;; Package-Author: Huming Chen
;; Package-Keywords: programming, convenience, ai, agent
;; Package-Description: Agent execution harness for gptel-agent.
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
;; Usage:
;;   (require 'gptel-agent-harness)
;;   (gptel-agent-harness-mode 1)
;;
;;; Code:

(require 'gptel-agent)
(require 'gptel-agent-harness-tools)
(require 'gptel-agent-harness-agent)
(require 'gptel-agent-harness-session)
(require 'gptel-agent-harness-commands)
(require 'gptel-agent-harness-cache)
(require 'cl-lib)

;;;; User Options
(defgroup gptel-agent-harness nil
  "Agent execution harness for gptel."
  :group 'gptel
  :prefix "gptel-agent-harness-")

(defcustom gptel-agent-harness-verbose nil
  "Log harness actions."
  :type 'boolean)

;;;; Completion Supervision
(defcustom gptel-agent-harness-max-nudges 2
  "Maximum consecutive completion nudges.

Reset whenever the LLM performs tool calls."
  :type 'integer)

(defcustom gptel-agent-harness-nudge-message
  "Review the original user request and the Task Completion Rules \
in the context. Verify whether all completion criteria are satisfied. \
If not, continue by making tool calls. Do not stop until the rules are fully met."
  "Message injected when the agent tries to stop."
  :type 'string)

;;;; Context Management
(defcustom gptel-agent-harness-context-trigger 0.70
  "Compact when context usage exceeds this ratio."
  :type 'float)

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
  :type '(alist
          :key-type string
          :value-type integer))

(defconst gptel-agent-harness-compact-prompt-file
  (expand-file-name
   "prompts/compact.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Gptel-agent-harness not found"))))
  "File path for the context compaction prompt.")

(defun gptel-agent-harness--read-compact-prompt ()
  "Read the compact prompt from `gptel-agent-harness-compact-prompt-file'."
  (if (file-exists-p gptel-agent-harness-compact-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness-compact-prompt-file)
        (buffer-string))
    (error "Compact prompt file not found: %s" gptel-agent-harness-compact-prompt-file)))

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
  "Return non-nil when nudge budget remains for FSM."
  (< (gptel-agent-harness--get-nudges fsm)
     gptel-agent-harness-max-nudges))

;;;; Completion Actions
(defun gptel-agent-harness--nudge (fsm)
  "Inject nudge message into FSM prompt data and bump counter."
  (let ((info (gptel-fsm-info fsm)))
    (gptel-agent-harness--inc-nudges fsm)
    (gptel--inject-prompt
     (plist-get info :backend)
     (plist-get info :data)
     (list :role "user" :content gptel-agent-harness-nudge-message))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness: completion nudge %d/%d — asking LLM to review task"
               (gptel-agent-harness--get-nudges fsm)
               gptel-agent-harness-max-nudges))))

;;;; Context Window Management
(defun gptel-agent-harness--model-name ()
  "Return current model name."
  (cond ((symbolp gptel-model)
         (symbol-name gptel-model))
        ((stringp gptel-model)
         gptel-model)
        (t "")))

(defun gptel-agent-harness--context-window ()
  "Return current model context window."
  (let ((model (gptel-agent-harness--model-name)))
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
Handles string, plist with :parts, vector, and list forms."
  (cond
   ((stringp system) (insert system))
   ((and (listp system) (plist-get system :parts))
    (let ((parts (plist-get system :parts)))
      (cl-loop for part across (if (vectorp parts) parts (vconcat parts))
               do (insert (or (plist-get part :text) (format "%S" part)) "\n"))))
   ((vectorp system)
    (cl-loop for part across system
             do (insert (or (plist-get part :text) (format "%S" part)) "\n")))
   ((listp system)
    (dolist (s system)
      (insert (or (and (stringp s) s)
                  (plist-get s :text)
                  (format "%s" s))
              "\n")))))

(defun gptel-agent-harness--extract-content-openai (content)
  "Insert OpenAI-style string CONTENT into current buffer."
  (insert content))

(defun gptel-agent-harness--extract-content-gemini (content)
  "Insert Gemini-style vector CONTENT into current buffer.
Iterates over parts, extracting :thinking and :text fields."
  (cl-loop for part across content
           do (insert (or (and (stringp part) part)
                          (and (stringp (plist-get part :thinking))
                               (plist-get part :thinking))
                          (and (stringp (plist-get part :text))
                               (plist-get part :text))
                          (format "%S" part)))))

(defun gptel-agent-harness--extract-content-anthropic (content)
  "Insert Anthropic-style list CONTENT into current buffer.
Handles :thinking, :text, and :arguments blocks."
  (dolist (part content)
    (cond
     ((stringp part) (insert part))
     ((and (plist-get part :thinking)
           (stringp (plist-get part :thinking)))
      (insert (plist-get part :thinking)))
     ((and (plist-get part :text)
           (stringp (plist-get part :text)))
      (insert (plist-get part :text)))
     ((and (plist-get part :arguments)
           (stringp (plist-get part :arguments)))
      (insert (plist-get part :arguments)))
     (t (insert (format "%S" part))))))

(defun gptel-agent-harness--extract-content (content)
  "Dispatch CONTENT insertion based on its type.
Delegates to OpenAI, Gemini, or Anthropic-specific extractors."
  (cond
   ((stringp content)
    (gptel-agent-harness--extract-content-openai content))
   ((vectorp content)
    (gptel-agent-harness--extract-content-gemini content))
   ((listp content)
    (gptel-agent-harness--extract-content-anthropic content))
   (t (insert (format "%S" content)))))

(defun gptel-agent-harness--extract-tool-calls (tool-calls)
  "Insert TOOL-CALLS names and arguments into current buffer.
Handles both vector and list representations."
  (dolist (tc (if (vectorp tool-calls)
                  (append tool-calls nil)
                tool-calls))
    (let ((func (plist-get tc :function)))
      (when func
        (let ((name (plist-get func :name))
              (args (plist-get func :arguments)))
          (when name (insert name "\n"))
          (when args (insert args "\n")))))))

(defun gptel-agent-harness--context-tokens-from-data (fsm)
  "Estimate tokens from the full prompt payload of FSM.
Includes system prompt, all user/assistant/tool messages, and
tool definitions (schemas).
When `gptel-agent-harness-verbose' is non-nil, logs the
serialized content to *gptel-agent-harness-debug*."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (or (plist-get data :messages)
                       (plist-get data :input)
                       (plist-get data :contents)))
         (system (or (plist-get data :system)
                     (plist-get data :system_instruction)
                     (plist-get data :instructions)
                     (plist-get data :systemInstruction)
                     ""))
         (total 0)
         (debug-buf (when gptel-agent-harness-verbose
                      (get-buffer-create "*gptel-agent-harness-debug*"))))
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
      (when messages
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
                             (plist-get (plist-get data :toolConfig) :tools))))
        (erase-buffer)
        (insert (format "%S" tools))
        (cl-incf total
                 (gptel-agent-harness--estimate-tokens (point-min) (point-max)))
        (when debug-buf
          (let ((text (buffer-string)))
            (with-current-buffer debug-buf
              (insert (format "--- [tools] (%d definitions) ---\n%s\n\n"
                              (length tools) text)))))))
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
    (/ calibrated (float (gptel-agent-harness--context-window)))))

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

(defun gptel-agent-harness--last-user-request (fsm)
  "Return the last user message from FSM, excluding nudge messages.
Returns the content string, or nil if none found."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (or (plist-get data :messages)
                       (plist-get data :input)      ; OpenAI Responses API
                       (plist-get data :contents))) ; Gemini
         (nudge gptel-agent-harness-nudge-message))
    (cl-loop for i downfrom (1- (length messages)) to 0
             for msg = (aref messages i)
             when (and (equal (plist-get msg :role) "user")
                       (not (equal (plist-get msg :content) nudge)))
             return (plist-get msg :content))))

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
                             (gptel-agent-harness-cache--reset-epoch)
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
           (ratio (/ calibrated (float (gptel-agent-harness--context-window)))))
      (gptel-agent-harness--with-fsm-buffer fsm
        (setq gptel-agent-harness--context-ratio ratio)
        (setq gptel-agent-harness--last-raw-estimate raw-estimate)
        (force-mode-line-update)))))


;;;; Extracted transition handlers

(defun gptel-agent-harness--handle-wait-state (orig-fn machine new-state)
  "Handle WAIT state transition for MACHINE.

Checks context usage ratio and triggers compaction when the
threshold is exceeded.  Returns non-nil if compaction was started,
meaning the caller should skip its own transition, and nil otherwise.

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
      ;; skip the normal transition when compaction starts.
      (unless (gptel-agent-harness--compact machine)
        (funcall orig-fn machine new-state))
    (funcall orig-fn machine new-state)))

(defun gptel-agent-harness--handle-terminal-state (orig-fn machine new-state)
  "Handle terminal (DONE/ERRS) state transition for MACHINE.

Either nudges the LLM to keep going (redirecting to WAIT) or lets
the FSM terminate.  When compaction is in progress, always lets the
FSM terminate without interference.

ORIG-FN is the original `gptel--fsm-transition' function.
MACHINE is the FSM machine state.
NEW-STATE is the state to transition to."
  (condition-case err
      (gptel-agent-harness--update-context-ratio machine)
    (error
     (when gptel-agent-harness-verbose
       (message "gptel-agent-harness: context ratio error (terminal) — %s"
                (error-message-string err)))))
  ;; If compaction is in progress, let the FSM terminate without
  ;; interference — don't clear the flag or nudge.  The aborted
  ;; FSM must die quietly while compaction handles the resume.
  (if (gptel-agent-harness--with-fsm-buffer machine
        gptel-agent-harness--compacting-p)
      (funcall orig-fn machine new-state)
    (if (and (gptel-agent-harness--agentic-p machine)
             (gptel-agent-harness--top-level-p machine)
             (gptel-agent-harness--can-nudge-p machine))
        (progn
          (gptel-agent-harness--nudge machine)
          (funcall orig-fn machine 'WAIT))
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
  '(:eval (gptel-agent-harness--context-ratio-indicator))
  "Mode-line construct showing context usage ratio in gptel buffers.")
(put 'gptel-agent-harness--mode-line-construct 'risky-local-variable t)

(defun gptel-agent-harness--setup-mode-line ()
  "Add context ratio indicator to mode-line for the current gptel buffer.
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
        (gptel-agent-harness-cache-enable)
        (advice-add 'gptel--fsm-transition
                    :around #'gptel-agent-harness--transition-advice)
        (when (boundp 'gptel-mode-map)
          (define-key gptel-mode-map (kbd "C-c C-k") #'gptel-abort))
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-calibration)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness-cache--setup)
        ;; Set up for already-open gptel buffers
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when gptel-mode
              (gptel-agent-harness--setup-mode-line)
              (gptel-agent-harness--setup-calibration)
              (gptel-agent-harness--setup-session)
              (gptel-agent-harness-cache--setup))))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (gptel-agent-harness-agent-disable)
    (gptel-agent-harness-tools-disable)
    (gptel-agent-harness-cache-disable)
    (advice-remove 'gptel--fsm-transition
                   #'gptel-agent-harness--transition-advice)
    (when (boundp 'gptel-mode-map)
      (define-key gptel-mode-map (kbd "C-c C-k") nil))
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-mode-line)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-calibration)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness--setup-session)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness-cache--setup)
    ;; Clean up from all gptel buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when gptel-mode
          (gptel-agent-harness--teardown-mode-line)
          (gptel-agent-harness--teardown-calibration)
          (gptel-agent-harness--teardown-session)
          (gptel-agent-harness-cache--teardown)
          (setq gptel-agent-harness--context-ratio nil)
          (setq gptel-agent-harness--token-calibration 1.0)
          (setq gptel-agent-harness--last-raw-estimate nil)
          (force-mode-line-update))))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness disabled"))))

;; (require 'ert) — tests have moved to gptel-agent-harness-test.el

(provide 'gptel-agent-harness)
;;; gptel-agent-harness.el ends here
