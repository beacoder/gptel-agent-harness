;;; gptel-agent-harness-fsm-helpers.el --- FSM helpers and token estimation -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
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
;; FSM helper functions and token estimation utilities.
;;
;;; Code:

(require 'cl-lib)
(require 'gptel-agent)
(require 'gptel-agent-harness-config)

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
     ;; fallback to 128000.
     128000)))

(defun gptel-agent-harness--estimate-tokens (start end)
  "Estimate tokens between START and END.
Uses:
- Latin: ~4 chars/token
- CJK/full-width: ~2 chars/token"
  (let* ((len (- end start))
         (bmp (count-matches "[\u3000-\u9fff\uF900-\uFAFF\uFF00-\uFFEF]"
                             start end))
         (supp (count-matches (concat "[" (string #x20000) "-" (string #x2FA1F) "]")
                              start end))
         (cjk-count (+ bmp supp)))
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

(provide 'gptel-agent-harness-fsm-helpers)

;;;###autoload
(defun gptel-agent-harness-fsm-helpers-enable ()
  "Enable FSM helpers for the current buffer."
  ;; No-op: FSM helpers are loaded globally, no per-buffer setup needed
  nil)

(defun gptel-agent-harness-fsm-helpers-disable ()
  "Disable FSM helpers for the current buffer."
  ;; No-op: FSM helpers are loaded globally, no per-buffer teardown needed
  nil)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-fsm-helpers.el ends here
