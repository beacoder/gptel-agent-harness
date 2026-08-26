;;; gptel-agent-harness-config.el --- User options and configuration -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
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
;; User options and configuration for gptel-agent-harness.
;;
;;; Code:

(require 'gptel-agent)

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

(provide 'gptel-agent-harness-config)

;;;###autoload
(defun gptel-agent-harness-config-enable ()
  "Enable config for the current buffer."
  ;; No-op: config is loaded globally, no per-buffer setup needed
  nil)

(defun gptel-agent-harness-config-disable ()
  "Disable config for the current buffer."
  ;; No-op: config is loaded globally, no per-buffer teardown needed
  nil)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-config.el ends here
