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
;;
;; This file is the package entry point: it defines the global
;; `gptel-agent-harness-mode' minor mode and wires up the feature
;; modules, each in its own file:
;;
;; - gptel-agent-harness-config.el      — user options and prompt files
;; - gptel-agent-harness-fsm-helpers.el — FSM helpers, internal state, token estimation
;; - gptel-agent-harness-compact.el     — automatic context compaction
;; - gptel-agent-harness-display.el     — mode-line display, token calibration, context rules
;; - gptel-agent-harness-supervisor.el  — FSM supervisor, build/plan mode
;; - gptel-agent-harness-tools.el       — enhanced tools
;; - gptel-agent-harness-agent.el       — OpenCode-like agent
;; - gptel-agent-harness-session.el     — session persistence and restore
;; - gptel-agent-harness-commands.el    — built-in and custom commands
;; - gptel-agent-harness-fsm.el         — FSM hardening advice

;;; Code:

(require 'gptel-agent)
(require 'gptel-agent-harness-config)
(require 'gptel-agent-harness-fsm-helpers)
(require 'gptel-agent-harness-compact)
(require 'gptel-agent-harness-display)
(require 'gptel-agent-harness-supervisor)
(require 'gptel-agent-harness-tools)
(require 'gptel-agent-harness-agent)
(require 'gptel-agent-harness-session)
(require 'gptel-agent-harness-commands)
(require 'gptel-agent-harness-fsm)
(require 'cl-lib)

;;;; Minor Mode

;;;###autoload
(define-minor-mode
  gptel-agent-harness-mode
  "Enable gptel-agent-harness mode.

Provides completion and context supervision."
  :global t
  :group 'gptel-agent-harness
  :lighter " AgentHarness"
  (if gptel-agent-harness-mode
      (progn
        ;; Global setup — module enables that need no buffer context.
        (gptel-agent-harness-config-enable)
        (gptel-agent-harness-fsm-helpers-enable)
        (gptel-agent-harness-compact-enable)
        (gptel-agent-harness-commands-enable)
        (gptel-agent-harness-tools-enable)
        (gptel-agent-harness-agent-enable)
        (gptel-agent-harness-fsm-enable)
        (gptel-agent-harness-supervisor-enable)
        (when (boundp 'gptel-mode-map)
          (define-key gptel-mode-map (kbd "C-c C-k") #'gptel-abort))
        ;; Per-buffer setup for future gptel buffers.
        (add-hook 'gptel-mode-hook #'gptel-agent-harness-display-enable)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness-supervisor-enable)
        (add-hook 'gptel-mode-hook #'gptel-agent-harness-session-enable)
        ;; Set up for already-open gptel buffers
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when gptel-mode
              (gptel-agent-harness-display-enable)
              (gptel-agent-harness-supervisor-enable)
              (gptel-agent-harness-session-enable))))
        (when gptel-agent-harness-verbose
          (message "gptel-agent-harness enabled")))
    ;; disable
    (gptel-agent-harness-config-disable)
    (gptel-agent-harness-fsm-helpers-disable)
    (gptel-agent-harness-compact-disable)
    (gptel-agent-harness-commands-disable)
    (gptel-agent-harness-tools-disable)
    (gptel-agent-harness-agent-disable)
    (gptel-agent-harness-fsm-disable)
    (gptel-agent-harness-supervisor-disable)
    (when (boundp 'gptel-mode-map)
      (define-key gptel-mode-map (kbd "C-c C-k") nil))
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness-display-enable)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness-supervisor-enable)
    (remove-hook 'gptel-mode-hook #'gptel-agent-harness-session-enable)
    ;; Clean up from all gptel buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when gptel-mode
          (gptel-agent-harness-display-disable)
          (gptel-agent-harness-supervisor-disable)
          (gptel-agent-harness-session-disable)
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
