;;; gptel-agent-harness-display.el --- Mode-line display and context rules -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
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
;; Mode-line display and task completion rules context management.
;;
;;; Code:

(require 'cl-lib)
(require 'gptel-agent)
(require 'gptel-agent-harness-config)
(require 'gptel-agent-harness-fsm)

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
  (or (locate-file "prompts/task-completion-rules.md" load-path)
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

;;;###autoload
(defun gptel-agent-harness-display-enable ()
  "Enable display for the current buffer."
  (gptel-agent-harness--setup-mode-line)
  (gptel-agent-harness--setup-calibration)
  (gptel-agent-harness--add-task-completion-rules))

(defun gptel-agent-harness-display-disable ()
  "Disable display for the current buffer."
  (gptel-agent-harness--teardown-mode-line)
  (gptel-agent-harness--teardown-calibration)
  (gptel-agent-harness--remove-task-completion-rules))

(provide 'gptel-agent-harness-display)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-display.el ends here
