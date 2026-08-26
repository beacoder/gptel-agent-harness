;;; gptel-agent-harness-compact.el --- Context compaction utilities -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
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
;; Context compaction utilities for gptel-agent-harness.
;;
;;; Code:

(require 'cl-lib)
(require 'gptel-agent)
(require 'gptel-agent-harness-config)
(require 'gptel-agent-harness-fsm-helpers)
(require 'gptel-agent-harness-commands)

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

(defun gptel-agent-harness--user-prompt-texts (fsm)
  "Return all user prompt texts from FSM messages, oldest first.

Extracts the text of every user-role message (multimodal content is
reduced via `gptel-agent-harness--content-to-text') and applies the
shared exclusion rules of
`gptel-agent-harness-commands--filter-user-prompts'."
  (let* ((info (gptel-fsm-info fsm))
         (data (plist-get info :data))
         (messages (and (plistp data)
                        (or (plist-get data :messages)
                            (plist-get data :input)
                            (plist-get data :contents)))))
    (when (vectorp messages)
      (let ((texts nil))
        (cl-loop for msg in (append messages nil)
                 when (and (plistp msg)
                           (equal (plist-get msg :role) "user"))
                 do (let ((text (gptel-agent-harness--content-to-text
                                 (or (plist-get msg :content)
                                     (plist-get msg :parts)))))
                      (when text (push text texts))))
        (gptel-agent-harness-commands--filter-user-prompts
         (nreverse texts))))))

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

(defun gptel-agent-harness--drop-current-round ()
  "Delete the current (last) assistant round from the current buffer.

Walks backward from `point-max' to find the start of the last
assistant round (a contiguous block of response, tool-call, and
ignore regions not followed by user text) and deletes from there to
`point-max'.  Return non-nil if a round was deleted, nil otherwise."
  (save-excursion
    ;; Walk backward from the end to find the start of the current
    ;; (incomplete) round.  A round is a contiguous block of
    ;; response/tool/ignore regions.  It ends (going backward) when
    ;; we hit non-blank user text or buffer start.
    (let ((pos (point-max))
          (round-start nil))
      (while (> pos (point-min))
        (let* ((prev-end pos)
               (prev-start (previous-single-property-change
                            pos 'gptel nil (point-min)))
               (val (get-text-property prev-start 'gptel)))
          (if (or (eq val 'response)
                  (eq val 'ignore)
                  (and (consp val) (eq (car val) 'tool)))
              ;; Part of the round — record as potential start
              (progn
                (setq round-start prev-start)
                (setq pos prev-start))
            ;; User text region — check if it's just blank
            (let ((text (buffer-substring-no-properties
                         prev-start prev-end)))
              (if (string-blank-p text)
                  ;; Blank user text between round regions — skip
                  (progn
                    (setq round-start prev-start)
                    (setq pos prev-start))
                ;; Real user text — the round starts after this
                (setq pos (point-min)))))))
      (when round-start
        (delete-region round-start (point-max))
        t))))

(defun gptel-agent-harness--salvage-buffer (fsm)
  "Drop the incomplete round from FSM's buffer.

Deletes the last assistant round (a contiguous block of response,
tool-call, and ignore regions not followed by user text) so the next
`gptel-send' starts from a clean conversation state.

Only acts on top-level agentic FSMs with a live buffer.  Does nothing
when compaction is in progress (compaction handles its own cleanup)."
  (when (and (gptel-agent-harness--agentic-p fsm)
             (gptel-agent-harness--top-level-p fsm))
    (gptel-agent-harness--with-fsm-buffer fsm
      (unless gptel-agent-harness--compacting-p
        (when (gptel-agent-harness--drop-current-round)
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness: salvaged buffer — dropped incomplete round")))))))

(cl-defun gptel-agent-harness--compact (fsm)
  "Abort and run context compaction for FSM.
Drops the current round, aborts the session, calls `compact-buffer'
\(the proven manual compaction logic), then resumes with all user
prompts (excluding nudges and mode-switch messages) restored.
Return non-nil if compaction was initiated, nil otherwise."
  (let ((buf (gptel-agent-harness--buffer fsm)))
    (unless (and buf (buffer-live-p buf))
      (when gptel-agent-harness-verbose
        (message "gptel-agent-harness: compact skipped — buffer not live"))
      (cl-return-from gptel-agent-harness--compact nil))
    (with-current-buffer buf
      (let ((prompts (gptel-agent-harness--user-prompt-texts fsm)))
        (unless prompts
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness: compact skipped — no user prompts to resume"))
          (cl-return-from gptel-agent-harness--compact nil))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness: compacting context %.1f%%"
                   (* 100 (gptel-agent-harness--context-ratio-for-fsm fsm))))
        ;; Mark compaction in progress BEFORE aborting, so the terminal
        ;; transition handler won't nudge the aborted FSM back to life.
        (setq gptel-agent-harness--compacting-p t)
        ;; Drop current round (last response/tool block onward).
        (gptel-agent-harness--drop-current-round)
        ;; Abort current session.
        (gptel-abort buf)
        (gptel-agent-harness--strip-compact-prefix)
        (setq-local gptel-agent-compact-prompt
                    (gptel-agent-harness--read-compact-prompt))
        (let ((resume-buf buf)
              (resume-prompts prompts))
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
                       ;; Success: insert frame + all user prompts, then send.
                       (condition-case resume-err
                           (progn
                             (gptel-agent-harness--insert-compact-frame)
                             (goto-char (point-max))
                             ;; Insert all preserved user prompts, separated
                             ;; by double newlines for readability.
                             (dolist (prompt resume-prompts)
                               (insert prompt "\n\n"))
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

(provide 'gptel-agent-harness-compact)

;;;###autoload
(defun gptel-agent-harness-compact-enable ()
  "Enable compaction for the current buffer."
  ;; No-op: compaction is loaded globally, no per-buffer setup needed
  nil)

(defun gptel-agent-harness-compact-disable ()
  "Disable compaction for the current buffer."
  ;; No-op: compaction is loaded globally, no per-buffer teardown needed
  nil)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-compact.el ends here
