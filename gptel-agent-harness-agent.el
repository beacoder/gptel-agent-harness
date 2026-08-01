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

;; Silence byte-compiler — defined in gptel-agent.el
(defvar gptel-agent--agents)

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
             (gptel--apply-preset
              ',func-name
              (lambda (sym val) (set (make-local-variable sym) val))))))
       (cl-pushnew '(,func-name . ,agent-name)
                   gptel-agent-harness-agent--defined-agents
                   :test #'equal))))

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
  (advice-add 'gptel-agent-update :after #'gptel-agent-harness-agent--register-preset))

(defun gptel-agent-harness-agent-disable ()
  "Restore original `gptel-agent-dirs' and `gptel-agent' function."
  (when gptel-agent-harness-agent--orig-dirs
    (setq gptel-agent-dirs gptel-agent-harness-agent--orig-dirs)
    (setq gptel-agent-harness-agent--orig-dirs nil))
  (when gptel-agent-harness-agent--orig-fn
    (advice-remove 'gptel-agent #'gptel-opencode-agent)
    (setq gptel-agent-harness-agent--orig-fn nil))
  (advice-remove 'gptel-agent-update #'gptel-agent-harness-agent--register-preset))

(provide 'gptel-agent-harness-agent)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-agent.el ends here
