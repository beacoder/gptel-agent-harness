;;; gptel-agent-harness-agent.el --- Agent definition for gptel-agent-harness -*- lexical-binding: t -*-
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
;; Agent definitions for gptel-agent-harness:
;;
;; - `gptel-opencode-agent': Agent which has opencode like behavior and capabilities
;; - `gptel-opencode-subagent' SubAgent used by `gptel-opencode-agent'
;;
;; When activated, overrides `gptel-agent-dirs' and the `gptel-agent'
;; command to use `gptel-opencode-agent' as the default.
;;
;; Activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-agent)
;;
;;; Code:

(require 'gptel-agent)
(require 'gptel)
(require 'cl-lib)
(require 'project)

;; Silence byte-compiler — defined in gptel-agent.el
(defvar gptel-agent--agents)

;; Silence byte-compiler — defined in gptel-agent-harness-config.el
(defvar gptel-agent-harness-verbose)

;;;; Internal State

(defvar gptel-agent-harness-agent--orig-dirs nil
  "Original `gptel-agent-dirs' value, saved before override.")

(defvar gptel-agent-harness-agent--orig-fn nil
  "Original `gptel-agent' function, saved before override.")

;;;; Agent Directory

(defcustom gptel-agent-harness-agent-dirs
  (list (expand-file-name
         "agents"
         (file-name-directory
          (or (locate-library "gptel-agent-harness")
              (error "Failed to find gptel-agent-harness")))))
  "Directories containing agent definition files for the harness.
Replaces `gptel-agent-dirs' when the harness is enabled."
  :type '(repeat directory)
  :group 'gptel-agent-harness)

;;;; Sub-agent Backend/Model

(defcustom gptel-agent-harness-subagent-backend nil
  "Backend used for sub-agent requests, or nil to inherit the main agent's.

Sub-agents are spawned by the `Agent' tool.  When non-nil, they use
this backend instead of the one active in the main agent buffer, so a
cheaper backend can serve delegated work.  The value is a backend
name as registered with gptel (e.g. \"DeepSeek\").  Takes precedence
over `gptel-agent-preset'; an explicit backend in the sub-agent
definition file's frontmatter still wins."
  :type '(choice (const :tag "Inherit main agent backend" nil)
                 (string :tag "Backend name"))
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-subagent-model nil
  "Model used for sub-agent requests, or nil to inherit the main agent's.

Sub-agents are spawned by the `Agent' tool.  When non-nil, they use
this (typically smaller/cheaper) model instead of the one active in
the main agent buffer.  Takes precedence over `gptel-agent-preset';
an explicit model in the sub-agent definition file's frontmatter
still wins."
  :type '(choice (const :tag "Inherit main agent model" nil)
                 (string :tag "Model name")
                 (symbol :tag "Model symbol"))
  :group 'gptel-agent-harness)

(defun gptel-agent-harness-agent--subagent-spec ()
  "Return the harness sub-agent preset spec, or nil if unset.

Builds a plist with `:backend'/`:model' keys from
`gptel-agent-harness-subagent-backend'/`gptel-agent-harness-subagent-model'.
Symbol backends are converted to strings (backend names are stored as
strings in gptel's backend registry) and empty strings are ignored."
  (let ((backend gptel-agent-harness-subagent-backend)
        (model gptel-agent-harness-subagent-model))
    (when (and backend (symbolp backend))
      (setq backend (symbol-name backend)))
    (when (stringp backend)
      (setq backend (and (not (string-empty-p backend)) backend)))
    (when (stringp model)
      (setq model (and (not (string-empty-p model)) model)))
    (when (or backend model)
      (nconc (and backend (list :backend backend))
             (and model (list :model model))))))

(defun gptel-agent-harness-agent--apply-subagent-settings
    (orig-fn main-cb agent-type description prompt)
  "Apply harness sub-agent backend/model around ORIG-FN.

ORIG-FN is `gptel-agent--task'.  When
`gptel-agent-harness-subagent-backend' or
`gptel-agent-harness-subagent-model' is set, binds `gptel-agent-preset'
to a spec that forces those values onto every sub-agent request.
The harness keys are appended after any existing `gptel-agent-preset'
settings so they take precedence (`gptel--apply-preset' applies keys
in order, last one wins), and the existing preset is copied before
merging so registered presets are never mutated.  When neither
option is set, calls ORIG-FN unchanged.

MAIN-CB is the callback to return a value to the main loop,
AGENT-TYPE is the name of the agent, DESCRIPTION is a short
description of the task, and PROMPT is the task instruction for the
sub-agent; all are passed through to ORIG-FN unchanged."
  (let ((gptel-agent-preset gptel-agent-preset))
    (when-let* ((spec (gptel-agent-harness-agent--subagent-spec)))
      (setq gptel-agent-preset
            (nconc (and gptel-agent-preset
                        (if (symbolp gptel-agent-preset)
                            ;; Resolve preset name; nil if not found.
                            (copy-sequence (gptel-get-preset gptel-agent-preset))
                          ;; Only merge proper plists; other types (e.g.
                          ;; strings, dotted lists) are not valid preset
                          ;; specs here.
                          (and (proper-list-p gptel-agent-preset)
                               (copy-sequence gptel-agent-preset))))
                   spec)))
    (funcall orig-fn main-cb agent-type description prompt)))

;;;; Sub-agent Callback Guard

(defun gptel-agent-harness-agent--guard-subagent-callback
    (callback main-cb description)
  "Return a guarded wrapper around CALLBACK that never signals.

CALLBACK is gptel-request's `:callback' for a sub-agent request and
MAIN-CB is the callback that returns a value to the parent loop.
DESCRIPTION is the sub-agent task description, used in error messages.

The upstream callback's `pcase' (gptel-agent-tools.el) has no `_'
fallback, so an unexpected response type (e.g. t streaming markers,
`(cons \\='reasoning ...)' thinking blocks, or a vector) raises
`pcase-no-match' and the parent FSM is left stuck in TOOL forever.  The
wrapper runs CALLBACK inside `condition-case'; on error it calls
MAIN-CB with an error string so the parent FSM keeps moving.  Non-final
stream markers (t and `(reasoning . _)') are ignored, matching
upstream semantics."
  (lambda (resp info)
    (condition-case err
        (funcall callback resp info)
      (error
       (when gptel-agent-harness-verbose
         (message "gptel-agent-harness-agent: sub-agent callback error — %s"
                  (error-message-string err)))
       (unless (or (eq resp t)
                   (and (consp resp) (eq (car resp) 'reasoning)))
         (funcall main-cb
                  (format "Error: Task \"%s\" returned an unexpected response %S — %s"
                          description resp (error-message-string err))))))))

(defun gptel-agent-harness-agent--task-callback-guard
    (orig-fn main-cb agent-type description prompt)
  "Around advice for `gptel-agent--task' guarding the sub-agent callback.

ORIG-FN is `gptel-agent--task'.  MAIN-CB, AGENT-TYPE, DESCRIPTION and
PROMPT are passed through unchanged.  Rebinds `gptel-request' so its
`:callback' argument is wrapped by
`gptel-agent-harness-agent--guard-subagent-callback', preventing a
`pcase-no-match' from leaving the parent FSM stuck in TOOL."
  (let ((orig-request (symbol-function 'gptel-request)))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (prompt &rest args)
                 (let ((callback (plist-get args :callback)))
                   (if (functionp callback)
                       (apply orig-request prompt
                              (plist-put args :callback
                                         (gptel-agent-harness-agent--guard-subagent-callback
                                          callback main-cb description)))
                     (apply orig-request prompt args))))))
      (funcall orig-fn main-cb agent-type description prompt))))

;;;; Agent Registry

(defvar gptel-agent-harness-agent--defined-agents nil
  "List of (FUNC-NAME . AGENT-NAME) for agents defined via the harness macro.")

;;;; Agent Definition Macro

(defmacro gptel-agent-harness-agent--define (name mcp-servers)
  "Define a gptel agent function with gptel-name as NAME connected to MCP-SERVERS."
  (let ((func-name (intern (format "gptel-%s" name)))
        (agent-name (format "gptel-%s" name)))
    `(progn
       (defun ,func-name (&optional project-dir)
         (interactive
          (list (if-let* ((proj (project-current)))
                    (project-root proj)
                  default-directory)))
         (when ',mcp-servers
           (require 'gptel-integrations)
           (gptel-mcp-connect ',mcp-servers)
           (while (not (gptel-mcp--get-tools ',mcp-servers))
             (sleep-for 0.1)))
         (let ((gptel-use-tools t)
               (gptel-tools gptel-tools)
               (gptel-buf
                (gptel (generate-new-buffer-name
                        (format ,(format "*%s:%%s*" agent-name)
                                (file-name-nondirectory
                                 (directory-file-name project-dir))))
                       nil
                       (and (use-region-p)
                            (buffer-substring (region-beginning) (region-end)))
                       'interactive)))
           (with-current-buffer gptel-buf
             (setq default-directory project-dir)
             (gptel-agent-update)
             (gptel-agent-harness-agent--apply-preset-buffer-local ',func-name))))
       (cl-pushnew '(,func-name . ,agent-name)
                   gptel-agent-harness-agent--defined-agents
                   :test #'equal))))

(defun gptel-agent-harness-agent--apply-preset-buffer-local (preset)
  "Apply PRESET buffer-locally, respecting global `gptel-confirm-tool-calls'.
If PRESET does not explicitly set confirm-tool-calls, kill the buffer-local
binding so the global value takes effect."
  (when (or (not (memq (type-of preset) '(symbol string)))
            (gptel-get-preset preset))
    (gptel--apply-preset
     preset (lambda (sym val) (set (make-local-variable sym) val)))
    (let ((spec (if (memq (type-of preset) '(symbol string))
                    (gptel-get-preset preset)
                  preset)))
      (unless (and (listp spec) (plist-member spec :confirm-tool-calls))
        (kill-local-variable 'gptel-confirm-tool-calls)))))

;; Define `gptel-opencode-agent' at load time.
(gptel-agent-harness-agent--define opencode-agent nil)

;;;; Preset Registration (via advice on gptel-agent-update)

(defun gptel-agent-harness-agent--register-preset (&rest _)
  "Register presets for all harness-defined agents after definitions are loaded.
Intended as :after advice on `gptel-agent-update'.
Only registers presets that haven't been registered yet."
  (dolist (entry gptel-agent-harness-agent--defined-agents)
    (let ((func-name (car entry))
          (agent-name (cdr entry)))
      (when-let* ((gptel-agent-plist
                   (assoc-default agent-name gptel-agent--agents nil nil)))
        (unless (assoc func-name gptel--known-presets)
          (apply #'gptel-make-preset func-name gptel-agent-plist))))))

;;;; Activation / Deactivation (called by gptel-agent-harness-mode)

(defun gptel-agent-harness-agent-enable ()
  "Override `gptel-agent-dirs' and set `gptel-opencode-agent' as default."
  (unless gptel-agent-harness-agent--orig-dirs
    (setq gptel-agent-harness-agent--orig-dirs gptel-agent-dirs))
  (setq gptel-agent-dirs gptel-agent-harness-agent-dirs)
  (when (fboundp 'gptel-agent)
    (unless gptel-agent-harness-agent--orig-fn
      (setq gptel-agent-harness-agent--orig-fn (symbol-function 'gptel-agent)))
    (advice-add 'gptel-agent :override #'gptel-opencode-agent))
  (when (fboundp 'gptel-agent--task)
    (advice-add 'gptel-agent--task
                :around #'gptel-agent-harness-agent--apply-subagent-settings)
    (advice-add 'gptel-agent--task
                :around #'gptel-agent-harness-agent--task-callback-guard))
  (advice-add 'gptel-agent-update :after #'gptel-agent-harness-agent--register-preset))

(defun gptel-agent-harness-agent-disable ()
  "Restore original `gptel-agent-dirs' and `gptel-agent' function."
  (when gptel-agent-harness-agent--orig-dirs
    (setq gptel-agent-dirs gptel-agent-harness-agent--orig-dirs)
    (setq gptel-agent-harness-agent--orig-dirs nil))
  (when gptel-agent-harness-agent--orig-fn
    (advice-remove 'gptel-agent #'gptel-opencode-agent)
    (setq gptel-agent-harness-agent--orig-fn nil))
  (advice-remove 'gptel-agent--task
                 #'gptel-agent-harness-agent--apply-subagent-settings)
  (advice-remove 'gptel-agent--task
                 #'gptel-agent-harness-agent--task-callback-guard)
  (advice-remove 'gptel-agent-update #'gptel-agent-harness-agent--register-preset))

(provide 'gptel-agent-harness-agent)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-agent.el ends here
