;;; gptel-agent-harness-test-agent.el --- Agent override tests -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: Kiro-cli:claude-opus-4-8, gptel-agent-harness:deepseek-v4-flash
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Keywords: programming, convenience, ai, agent
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
;; ERT tests for the agent module (gptel-agent-harness-agent): the
;; enable/disable override of gptel-agent, sub-agent model/backend
;; preset handling, the task callback guard, preset registration, and
;; `gptel-opencode-agent'.
;;
;; Part of the split suite in this directory; see
;; gptel-agent-harness-test.el for how to run it.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness-test-utils)

;;;; Agent Override Tests

(ert-deftest gptel-agent-harness-test-agent-enable-disable-idempotent ()
  "Test agent override: enable overrides dirs+fn, disable restores, idempotent."
  (let ((gptel-agent-harness-agent--orig-dirs nil)
        (gptel-agent-harness-agent--orig-fn nil)
        (orig-dirs gptel-agent-dirs)
        (orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep))
        (orig-agent (and (fboundp 'gptel-agent)
                         (symbol-function 'gptel-agent))))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          (gptel-agent-harness-agent-enable)
          ;; Dirs overridden
          (should (equal gptel-agent-dirs gptel-agent-harness-agent-dirs))
          (should (equal gptel-agent-harness-agent--orig-dirs orig-dirs))
          ;; Function overridden
          (should (advice-member-p #'gptel-opencode-agent 'gptel-agent))
          ;; Sub-agent model advice installed
          (should (advice-member-p
                   #'gptel-agent-harness-agent--apply-subagent-settings
                   'gptel-agent--task))
          ;; Sub-agent callback guard advice installed
          (should (advice-member-p
                   #'gptel-agent-harness-agent--task-callback-guard
                   'gptel-agent--task))
          ;; Second enable preserves originals
          (gptel-agent-harness-agent-enable)
          (should (equal gptel-agent-harness-agent--orig-dirs orig-dirs))
          ;; Disable restores everything and clears state
          (gptel-agent-harness-agent-disable)
          (gptel-agent-harness-tools-disable)
          (should (equal gptel-agent-dirs orig-dirs))
          (when orig-agent
            (should (eq (symbol-function 'gptel-agent) orig-agent)))
          (should-not (advice-member-p
                       #'gptel-agent-harness-agent--apply-subagent-settings
                       'gptel-agent--task))
          (should-not (advice-member-p
                       #'gptel-agent-harness-agent--task-callback-guard
                       'gptel-agent--task))
          (should-not (advice-member-p #'gptel-agent-harness-tools--glob
                                      'gptel-agent--glob))
          (should-not (advice-member-p #'gptel-agent-harness-tools--grep
                                      'gptel-agent--grep))
          (should-not gptel-agent-harness-agent--orig-dirs)
          (should-not gptel-agent-harness-agent--orig-fn))
      (setq gptel-agent-dirs orig-dirs)
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep)
      (when orig-agent (fset 'gptel-agent orig-agent))
      (setq gptel-agent-harness-agent--orig-dirs nil)
      (setq gptel-agent-harness-agent--orig-fn nil))))

(ert-deftest gptel-agent-harness-test-subagent-model-backend ()
  "Test `gptel-agent-harness-agent--apply-subagent-settings' binds model/backend."
  ;; Both set: harness keys appended AFTER existing preset so they win
  (let ((gptel-agent-harness-subagent-backend "cheap-backend")
        (gptel-agent-harness-subagent-model "cheap-model")
        (gptel-agent-preset '(:temperature 0.5))
        (captured :unset))
    (gptel-agent-harness-agent--apply-subagent-settings
     (lambda (&rest _) (setq captured gptel-agent-preset))
     nil "subagent" "desc" "prompt")
    (should (equal captured
                   '(:temperature 0.5 :backend "cheap-backend" :model "cheap-model"))))
  ;; Harness model wins over existing preset model: harness keys are
  ;; appended last, and gptel applies preset keys in order (last wins)
  (let ((gptel-agent-harness-subagent-backend nil)
        (gptel-agent-harness-subagent-model "cheap-model")
        (gptel-agent-preset '(:model "other-model"))
        (captured :unset))
    (gptel-agent-harness-agent--apply-subagent-settings
     (lambda (&rest _) (setq captured gptel-agent-preset))
     nil "subagent" "desc" "prompt")
    (should (equal captured '(:model "other-model" :model "cheap-model")))
    (when (fboundp 'gptel--apply-preset)
      (let ((applied nil))
        (gptel--apply-preset captured
                             (lambda (sym val)
                               (when (eq sym 'gptel-model)
                                 (setq applied val))))
        (should (equal applied "cheap-model")))))
  ;; Symbol backend converted to string
  (let ((gptel-agent-harness-subagent-backend 'cheap-backend)
        (gptel-agent-harness-subagent-model nil)
        (gptel-agent-preset nil)
        (captured :unset))
    (gptel-agent-harness-agent--apply-subagent-settings
     (lambda (&rest _) (setq captured gptel-agent-preset))
     nil "subagent" "desc" "prompt")
    (should (equal captured '(:backend "cheap-backend"))))
  ;; Empty strings are ignored
  (let ((gptel-agent-harness-subagent-backend "")
        (gptel-agent-harness-subagent-model "")
        (gptel-agent-preset nil)
        (captured :unset))
    (gptel-agent-harness-agent--apply-subagent-settings
     (lambda (&rest _) (setq captured gptel-agent-preset))
     nil "subagent" "desc" "prompt")
    (should (equal captured nil)))
  ;; Nothing set: passes through `gptel-agent-preset' unchanged (no copy)
  (let ((gptel-agent-harness-subagent-backend nil)
        (gptel-agent-harness-subagent-model nil)
        (gptel-agent-preset '(:temperature 0.5))
        (captured :unset))
    (gptel-agent-harness-agent--apply-subagent-settings
     (lambda (&rest _) (setq captured gptel-agent-preset))
     nil "subagent" "desc" "prompt")
    (should (eq captured gptel-agent-preset))))

(ert-deftest gptel-agent-harness-test-subagent-preset-not-mutated ()
  "Test merging never mutates a registered preset plist."
  (let* ((gptel-agent-harness-subagent-backend "cheap-backend")
         (gptel-agent-harness-subagent-model "cheap-model")
         (orig '(:model "preset-model"))
         (registered orig)
         (gptel-agent-preset 'registered)
         (captured :unset))
    (cl-letf (((symbol-function 'gptel-get-preset)
               (lambda (_name) registered)))
      (gptel-agent-harness-agent--apply-subagent-settings
       (lambda (&rest _) (setq captured gptel-agent-preset))
       nil "subagent" "desc" "prompt"))
    (should (equal captured
                   '(:model "preset-model"
                            :backend "cheap-backend"
                            :model "cheap-model")))
    (should (equal registered orig))))

(ert-deftest gptel-agent-harness-test-subagent-callback-guard ()
  "The sub-agent callback guard never signals and keeps the parent moving.
An unexpected response type (vector) calls MAIN-CB with an error string;
stream markers (t, `(reasoning . _)') are ignored; a normal string
passes through."
  (let ((main-cb-calls nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (let ((cb (plist-get args :callback)))
                   (funcall cb (vector 1 2) '(:info nil))))))
      (gptel-agent-harness-agent--task-callback-guard
       (lambda (main-cb _agent-type _desc _prompt)
         ;; Simulate gptel-agent--task: call gptel-request with a callback
         ;; whose pcase has no `_' fallback (raises on a vector).
         (gptel-request "prompt"
           :callback (lambda (resp _info)
                       (pcase resp
                         ((pred stringp) (funcall main-cb resp))
                         (_ (error "Pcase-no-match"))))))
       (lambda (result) (push result main-cb-calls))
       "subagent" "desc" "prompt"))
    (should (= 1 (length main-cb-calls)))
    (should (string-match-p "Error: Task \"desc\" returned an unexpected response"
                            (car main-cb-calls))))
  ;; Stream markers are ignored (main-cb not called)
  (let ((main-cb-calls nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (let ((cb (plist-get args :callback)))
                   (funcall cb t '(:info nil))
                   (funcall cb '(reasoning . "thinking") '(:info nil))))))
      (gptel-agent-harness-agent--task-callback-guard
       (lambda (main-cb _agent-type _desc _prompt)
         (gptel-request "prompt"
           :callback (lambda (resp _info)
                       (pcase resp
                         ((pred stringp) (funcall main-cb resp))
                         (_ (error "Pcase-no-match"))))))
       (lambda (result) (push result main-cb-calls))
       "subagent" "desc" "prompt"))
    (should (null main-cb-calls)))
  ;; Normal string response passes through
  (let ((main-cb-calls nil))
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (_prompt &rest args)
                 (let ((cb (plist-get args :callback)))
                   (funcall cb "output" '(:info nil))))))
      (gptel-agent-harness-agent--task-callback-guard
       (lambda (main-cb _agent-type _desc _prompt)
         (gptel-request "prompt"
           :callback (lambda (resp _info)
                       (pcase resp
                         ((pred stringp) (funcall main-cb resp))
                         (_ (error "Pcase-no-match"))))))
       (lambda (result) (push result main-cb-calls))
       "subagent" "desc" "prompt"))
    (should (equal main-cb-calls '("output")))))

(ert-deftest gptel-agent-harness-test-agent-register-preset ()
  "`--register-preset' registers presets for defined agents, once."
  (let ((gptel-agent-harness-agent--defined-agents
         '((my-agent-test . "my-agent-test")))
        (gptel-agent--agents (list (cons "my-agent-test"
                                         (list :model "test-model"))))
        (gptel--known-presets nil))
    (gptel-agent-harness-agent--register-preset)
    (should (assoc 'my-agent-test gptel--known-presets))
    (let ((n (length gptel--known-presets)))
      ;; Second call is a no-op.
      (gptel-agent-harness-agent--register-preset)
      (should (= (length gptel--known-presets) n)))))

(ert-deftest gptel-agent-harness-test-agent-apply-preset-buffer-local ()
  "`--apply-preset-buffer-local' applies a preset and manages confirm-tool-calls."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      ;; Symbol preset without :confirm-tool-calls → binding restored to global.
      (setq-local gptel-confirm-tool-calls t)
      (cl-letf (((symbol-function 'gptel-get-preset)
                 (lambda (_name) (list :model "m"))))
        (gptel-agent-harness-agent--apply-preset-buffer-local 'some-preset))
      (should-not (local-variable-p 'gptel-confirm-tool-calls))
      ;; Preset specifying :confirm-tool-calls keeps the buffer-local binding.
      (setq-local gptel-confirm-tool-calls nil)
      (cl-letf (((symbol-function 'gptel-get-preset)
                 (lambda (_name) (list :confirm-tool-calls t))))
        (gptel-agent-harness-agent--apply-preset-buffer-local 'some-preset))
      (should (local-variable-p 'gptel-confirm-tool-calls))
      ;; A raw plist preset is applied directly.
      (setq-local gptel-confirm-tool-calls t)
      (gptel-agent-harness-agent--apply-preset-buffer-local
       (list :model "direct"))
      (should-not (local-variable-p 'gptel-confirm-tool-calls)))))

(ert-deftest gptel-agent-harness-test-opencode-agent-function ()
  "`gptel-opencode-agent' spawns a gptel buffer with agent update."
  (gptel-agent-harness-test--with-temp-dir dir
    (let ((gptel-use-tools nil)
          (gptel-tools nil)
          (created nil)
          (updated nil))
      (cl-letf (((symbol-function 'gptel)
                 (lambda (buf-name &rest _)
                   (setq created buf-name)
                   (get-buffer-create buf-name)))
                ((symbol-function 'gptel-agent-update)
                 (lambda () (setq updated t)))
                ((symbol-function 'gptel-agent-harness-agent--apply-preset-buffer-local)
                 #'ignore))
        (gptel-opencode-agent dir)
        (should updated)
        (should (string-match-p "\\*gptel-opencode-agent:" created))
        (let ((buf (get-buffer created)))
          (should (buffer-live-p buf))
          (kill-buffer buf))))))

(provide 'gptel-agent-harness-test-agent)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-agent.el ends here
