;;; gptel-agent-harness-fsm.el --- FSM hardening advice for gptel-agent-harness -*- lexical-binding: t -*-
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
;; Narrow `:around' advice on upstream gptel FSM functions so that
;; invalid tool-result data can never abort the gptel state machine.
;;
;; gptel's `gptel--fsm-transition' (gptel-request.el) sets the new state
;; and runs its handlers without any `condition-case'.  An error in a
;; state handler therefore escapes and leaves the FSM wedged
;; mid-transition.  This module installs four narrow advices that turn
;; such errors into benign tool-result error strings and always let the
;; FSM complete its transition:
;;
;; - U1  `gptel--map-tool-args': non-plist tool `:args' (valid JSON but
;;        a string/vector/number) would throw `wrong-type-argument
;;        listp' inside the TOOL handler.  The advice normalizes
;;        non-plist args to nil so the error lands in gptel's sync
;;        condition-case or the U2 net instead.  (nil is used rather than
;;        signalling so that, in a multi-tool batch, one malformed call
;;        does not abort the whole loop and take its well-formed siblings
;;        down with it.)
;; - U2  `gptel--handle-tool-use': wraps the whole handler; on error
;;        (malformed `:args', async tool setup failures) it fails every
;;        pending tool call with an error string so the FSM transitions
;;        TOOL -> TRET instead of wedging in TOOL.
;; - U3  `gptel--process-tool-call': makes result processing idempotent.
;;        If U2 fails an async tool call that is still in flight, that
;;        call's real callback fires later and would process the same
;;        call a second time — double-decrementing the pending count and
;;        firing a spurious `gptel--fsm-transition' that advances the FSM
;;        past its intended state.  The advice skips any call that
;;        already has a `:result', so the first result wins and duplicates
;;        are no-ops.
;; - U4  `gptel--handle-tool-result': wraps the handler.  Before running
;;        it, sanitizes every tool call's `:result' to a string: a nil
;;        result (an async tool whose result was never recorded, or a
;;        call that never ran) is otherwise copied verbatim into the
;;        outgoing tool message by `gptel--parse-tool-results' and
;;        JSON-encoded as an empty object `{}', which the OpenAI, Ollama,
;;        Gemini, Bedrock and Responses APIs reject with "content must be
;;        a str".  On handler error it records a string `:error' and
;;        transitions the FSM so it is not left stuck in TRET.
;;
;; Upstream ELPA files are NOT modified.  All advice is installed and
;; removed by `gptel-agent-harness-fsm-enable' / `-disable', which are
;; called by `gptel-agent-harness-mode' in gptel-agent-harness.el.
;;
;; Usage:
;;   (require 'gptel-agent-harness-fsm)
;;   (gptel-agent-harness-fsm-enable)
;;
;;; Code:

(require 'gptel)
(require 'gptel-agent)
(require 'cl-lib)

;; Silence byte-compiler — defined in gptel-agent-harness.el
(defvar gptel-agent-harness-verbose)

;;;; U1 — normalize non-plist tool arguments

(defun gptel-agent-harness-fsm--map-tool-args-advice (orig-fn tool-spec args)
  "Around advice for `gptel--map-tool-args'.

ORIG-FN is the original `gptel--map-tool-args'.  TOOL-SPEC is the
`gptel-tool' and ARGS is the tool-call argument plist.  When ARGS is
not a plist (e.g. a string/vector/number from a malformed tool call),
returns nil instead of letting `gptel--map-tool-args' throw
`wrong-type-argument listp' inside the TOOL handler."
  (when (plistp args)
    (funcall orig-fn tool-spec args)))

;;;; U2 — fail pending tool calls on handler error

(defun gptel-agent-harness-fsm--fail-pending-tool-calls (fsm err)
  "Fail every pending tool call in FSM with error ERR.

For each `:tool-use' entry without a `:result', resolves its tool-spec
and calls `gptel--process-tool-call' with an error string.  This
recomputes the pending count and transitions TOOL -> TRET when it
reaches zero, so the FSM is never left stuck in TOOL.  Each call is
wrapped in `ignore-errors' so one bad entry cannot abort the loop."
  (let ((info (gptel-fsm-info fsm))
        (msg (format "Error: tool call failed — %s" (error-message-string err))))
    (dolist (tool-call (cl-remove-if (lambda (tc) (plist-get tc :result))
                                     (plist-get info :tool-use)))
      (ignore-errors
        (let* ((name (plist-get tool-call :name))
               (tool-spec (cl-find-if (lambda (ts) (equal (gptel-tool-name ts) name))
                                      (plist-get info :tools))))
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness-fsm: failing pending tool call %s"
                     (or name "<unknown>")))
          (gptel--process-tool-call fsm tool-spec tool-call msg))))))

(defun gptel-agent-harness-fsm--handle-tool-use-advice (orig-fn fsm)
  "Around advice for `gptel--handle-tool-use'.

ORIG-FN is the original `gptel--handle-tool-use' and FSM is the request
state.  Runs ORIG-FN inside `condition-case'; on error (malformed
`:args', async tool setup failures) fails all pending tool calls so the
FSM transitions out of TOOL instead of wedging."
  (condition-case err
      (funcall orig-fn fsm)
    (error
     (when gptel-agent-harness-verbose
       (message "gptel-agent-harness-fsm: tool-use error — %s"
                (error-message-string err)))
     (gptel-agent-harness-fsm--fail-pending-tool-calls fsm err))))

;;;; U3 — make tool-call result processing idempotent

(defun gptel-agent-harness-fsm--process-tool-call-advice
    (orig-fn fsm tool-spec tool-call result)
  "Around advice for `gptel--process-tool-call'.

ORIG-FN is the original `gptel--process-tool-call'.  FSM is the request
state, TOOL-SPEC the `gptel-tool', TOOL-CALL the call plist and RESULT
its result.

Skips processing when TOOL-CALL already has a `:result'.  Without this
guard, when U2's `gptel-agent-harness-fsm--fail-pending-tool-calls'
fails an async tool call that is still in flight, that call's real
callback fires later and processes the same call a second time.  Each
call decrements the pending count and, on reaching zero, fires
`gptel--fsm-transition'; a duplicate therefore double-decrements the
count and advances the FSM past its intended state.  The guard makes the
first result win and turns any later duplicate into a no-op.  This also
protects the normal (non-error) path against any accidental
double-processing of the same tool call."
  (if (plist-get tool-call :result)
      (when gptel-agent-harness-verbose
        (message "gptel-agent-harness-fsm: ignoring duplicate result for tool call %s"
                 (or (plist-get tool-call :name) "<unknown>")))
    (funcall orig-fn fsm tool-spec tool-call result)))

;;;; U4 — sanitize tool results and never leave the FSM stuck in TRET

(defun gptel-agent-harness-fsm--sanitize-tool-results (fsm)
  "Ensure every tool call in FSM has a string `:result'.

`gptel--parse-tool-results' for the OpenAI, Ollama, Gemini, Bedrock and
Responses backends copies each call's `:result' verbatim into the
outgoing tool message.  A nil `:result' — an async tool whose result was
never recorded, or a call that never ran — is then JSON-encoded by
`json-serialize' as an empty object `{}', which those APIs reject with
\"content must be a str with results or errors for the tool call\".

This coerces a nil result to a clear placeholder string and any other
non-string result to its printed form.  A legitimately empty result (the
string \"\") is left untouched, so a command with no output is still
reported faithfully.  Each entry is mutated in place, mirroring
`gptel--process-tool-call'."
  (let ((info (gptel-fsm-info fsm)))
    (dolist (tool-call (plist-get info :tool-use))
      (when (consp tool-call)
        (let ((result (plist-get tool-call :result)))
          (cond
           ((stringp result))           ; already a string (including "")
           ((null result)
            (when gptel-agent-harness-verbose
              (message "gptel-agent-harness-fsm: missing result for tool call %s, substituting placeholder"
                       (or (plist-get tool-call :name) "<unknown>")))
            (plist-put tool-call :result
                       "Error: tool produced no result (it may have been interrupted or failed to return)."))
           (t
            (plist-put tool-call :result (gptel--to-string result)))))))))

(defun gptel-agent-harness-fsm--handle-tool-result-advice (orig-fn fsm)
  "Around advice for `gptel--handle-tool-result'.

ORIG-FN is the original `gptel--handle-tool-result' and FSM is the
request state.  First runs `gptel-agent-harness-fsm--sanitize-tool-results'
so a missing/non-string `:result' can never be encoded as an invalid
`{}' tool-message content.  Then runs ORIG-FN inside `condition-case';
on error records a string `:error' and transitions the FSM so it is not
left stuck in TRET.  The `:error' is stored as a STRING because
`gptel--handle-error' only handles string or plist `:error' values."
  (condition-case err
      (progn
        (gptel-agent-harness-fsm--sanitize-tool-results fsm)
        (funcall orig-fn fsm))
    (error
     (when gptel-agent-harness-verbose
       (message "gptel-agent-harness-fsm: tool-result error — %s"
                (error-message-string err)))
     (let ((info (gptel-fsm-info fsm)))
       (plist-put info :error (format "Error: %s" (error-message-string err))))
     (gptel--fsm-transition fsm))))

;;;; Enable / Disable

(defun gptel-agent-harness-fsm-enable ()
  "Install the FSM-hardening advice on upstream gptel functions."
  (when (fboundp 'gptel--map-tool-args)
    (advice-add 'gptel--map-tool-args
                :around #'gptel-agent-harness-fsm--map-tool-args-advice))
  (when (fboundp 'gptel--handle-tool-use)
    (advice-add 'gptel--handle-tool-use
                :around #'gptel-agent-harness-fsm--handle-tool-use-advice))
  (when (fboundp 'gptel--process-tool-call)
    (advice-add 'gptel--process-tool-call
                :around #'gptel-agent-harness-fsm--process-tool-call-advice))
  (when (fboundp 'gptel--handle-tool-result)
    (advice-add 'gptel--handle-tool-result
                :around #'gptel-agent-harness-fsm--handle-tool-result-advice)))

(defun gptel-agent-harness-fsm-disable ()
  "Remove the FSM-hardening advice from upstream gptel functions."
  (advice-remove 'gptel--map-tool-args
                 #'gptel-agent-harness-fsm--map-tool-args-advice)
  (advice-remove 'gptel--handle-tool-use
                 #'gptel-agent-harness-fsm--handle-tool-use-advice)
  (advice-remove 'gptel--process-tool-call
                 #'gptel-agent-harness-fsm--process-tool-call-advice)
  (advice-remove 'gptel--handle-tool-result
                 #'gptel-agent-harness-fsm--handle-tool-result-advice))

(provide 'gptel-agent-harness-fsm)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-fsm.el ends here
