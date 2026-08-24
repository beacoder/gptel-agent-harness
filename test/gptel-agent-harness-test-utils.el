;;; gptel-agent-harness-test-utils.el --- Shared test stubs and helpers -*- lexical-binding: t -*-
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
;; Shared infrastructure for the gptel-agent-harness ERT suite (this
;; directory): a minimal gptel API surface for batch runs without the
;; real packages, plus the common helpers (temp buffers/dirs, fake
;; FSMs, gptel session buffers).
;;
;; Every topic test file starts with `(require
;; 'gptel-agent-harness-test-utils)'.  The suite entry point is
;; gptel-agent-harness-test.el in this directory; loading it (or any
;; single topic file) and running ERT with the selector
;; "^gptel-agent-harness" runs the whole suite:
;;
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -L /path/to/gptel-agent-harness/test \
;;     -l gptel-agent-harness-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness")'
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness)

;; Ensure gptel backends are available (needed for `gptel' function in
;; review/commands tests when running in batch mode).
(require 'gptel-openai nil t)

(defconst gptel-agent-harness-test--lv-header
  (concat ";; Local " "Variables:")
  "Literal local-variables header used by the session save/restore tests.

Built by concatenation on purpose.  Emacs scans the last 3000 characters
of a file for this text and tries to parse the first occurrence as the
file's own local-variables block; a test that spelled it out verbatim
would make every byte-compile of this file warn \"Local variables list
is not properly terminated\".")

;;;; Stubs — minimal gptel API surface needed for testing
;; These provide a minimal gptel API surface when the real packages
;; are not available.  We use `fset' to avoid package-lint prefix errors.
;; Idempotent: if the real package is loaded first, nothing is stubbed.

(eval-and-compile
  (unless (fboundp 'gptel-make-tool)
    (fset 'gptel-make-tool (lambda (&rest args) (apply #'list args))))
  (unless (fboundp 'gptel-tool-name)
    (fset 'gptel-tool-name (lambda (tool) (plist-get tool :name))))
  (unless (boundp 'gptel-tools) (defvar gptel-tools nil))
  (unless (boundp 'gptel-model) (defvar gptel-model nil))
  (unless (boundp 'gptel-mode) (defvar gptel-mode nil))
  (unless (boundp 'gptel-post-response-functions) (defvar gptel-post-response-functions nil))
  (unless (boundp 'gptel--backend-name) (defvar gptel--backend-name nil))
  (unless (boundp 'gptel-system-prompt) (defvar gptel-system-prompt nil))
  (unless (boundp 'gptel-temperature) (defvar gptel-temperature nil))
  (unless (boundp 'gptel-max-tokens) (defvar gptel-max-tokens nil))
  (unless (boundp 'gptel--num-messages-to-send) (defvar gptel--num-messages-to-send nil))
  (unless (boundp 'gptel--token-usage) (defvar gptel--token-usage nil))
  (unless (fboundp 'markdown-mode)
    (fset 'markdown-mode (lambda () (setq major-mode 'markdown-mode))))
  (unless (fboundp 'gptel-mode)
    (fset 'gptel-mode
          (lambda (&optional arg)
            (setq-local gptel-mode (if (null arg) t (if (eq arg -1) nil t))))))
  (unless (fboundp 'gptel-fsm-info)
    (fset 'gptel-fsm-info (lambda (fsm) (plist-get fsm :info))))
  (unless (fboundp 'gptel--fsm-next)
    (fset 'gptel--fsm-next (lambda (_machine) nil)))
  (unless (fboundp 'gptel-make-fsm)
    (fset 'gptel-make-fsm
          (lambda (&rest args) (list :info (plist-get args :info)))))
  (unless (fboundp 'gptel-fsm-handlers)
    (fset 'gptel-fsm-handlers (lambda (fsm) (plist-get fsm :handlers))))
  (with-no-warnings
    (unless (boundp 'gptel-send--handlers)
      (setq gptel-send--handlers 'gptel-send--handlers)))
  (unless (fboundp 'gptel--inject-prompt)
    (fset 'gptel--inject-prompt
          (lambda (_backend data msg)
            (let* ((msgs (or (plist-get data :messages) []))
                   (new-msgs (vconcat msgs (vector msg))))
              (plist-put data :messages new-msgs)))))
  (unless (fboundp 'gptel-abort)
    (fset 'gptel-abort (lambda (&optional _buf) nil)))
  (unless (fboundp 'gptel-agent-compact)
    (fset 'gptel-agent-compact
          (lambda (_prompt callback)
            (when (functionp callback)
              (funcall callback)))))
  (unless (fboundp 'gptel-send)
    (fset 'gptel-send (lambda () nil)))
  (unless (fboundp 'gptel--fsm-transition)
    (fset 'gptel--fsm-transition (lambda (_machine &optional _new-state) nil)))
  ;; Stubs for gptel-agent-harness-commands module
  (unless (boundp 'gptel-agent-mode) (defvar gptel-agent-mode nil))
  (unless (fboundp 'gptel)
    (fset 'gptel (lambda (buf-name &optional _prompt _initial _interactive)
                   (get-buffer-create buf-name))))
  (unless (fboundp 'gptel-get-tool)
    (fset 'gptel-get-tool (lambda (name) (intern (format "gptel-agent-harness-test--tool-%s" name)))))
  (unless (fboundp 'gptel-agent-update)
    (fset 'gptel-agent-update (lambda () nil)))
  (unless (fboundp 'gptel--update-status)
    (fset 'gptel--update-status (lambda (&rest _) nil)))
  (unless (fboundp 'gptel-get-preset)
    (fset 'gptel-get-preset (lambda (_name) nil)))
  (unless (fboundp 'gptel--apply-preset)
    (fset 'gptel--apply-preset (lambda (_preset &optional _setter) nil))))

;;;; Test Helpers

(defmacro gptel-agent-harness-test--with-buffer (buf-var &rest body)
  "Create a temp buffer bound to BUF-VAR, execute BODY, kill buffer."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,buf-var (generate-new-buffer " *harness-test*")))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,buf-var)
         (with-current-buffer ,buf-var
           (gptel-agent-harness--cleanup-plan-file))
         (kill-buffer ,buf-var)))))

(defmacro gptel-agent-harness-test--with-temp-dir (dir-var &rest body)
  "Create a temp directory bound to DIR-VAR, execute BODY, clean up."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,dir-var (make-temp-file "gptel-sess-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,dir-var)
         (delete-directory ,dir-var t)))))

(defun gptel-agent-harness-test--make-fsm (buf &rest plist)
  "Create a fake FSM with BUF.
PLIST keys `:tools' and `:handlers' are placed in both the FSM info
and the `:data' payload so all functions (token estimation, agentic-p,
top-level-p) see them."
  (let* ((tools (plist-get plist :tools))
         (handlers (plist-get plist :handlers))
         (info-plist `(:buffer ,buf :data ,(copy-sequence plist))))
    (when tools (plist-put info-plist :tools tools))
    (gptel-make-fsm :info info-plist
                    :handlers (or handlers 'test-handlers))))

(defun gptel-agent-harness-test--setup-gptel-buffer (buf &optional proj-dir)
  "Set up BUF as a gptel buffer with optional PROJ-DIR."
  (with-current-buffer buf
    (setq-local gptel-mode t)
    (when proj-dir
      (setq-local gptel-agent-harness--project-dir proj-dir))))

;; Declared special so `let' bindings are dynamic (completion frameworks
;; check these with `bound-and-true-p'; see
;; `gptel-agent-harness--preview-candidate-at-point').  The `boundp'
;; guard (same pattern as the gptel stubs above) keeps package-lint from
;; flagging the unprefixed vertico internals.
(unless (boundp 'vertico--index) (defvar vertico--index nil))
(unless (boundp 'vertico--candidates) (defvar vertico--candidates nil))

(defun gptel-agent-harness-test--position-aware-inject-prompt
    (_backend data new-prompt &optional position)
  "Test stub for `gptel--inject-prompt' honoring POSITION.

DATA is the request payload plist, NEW-PROMPT is the message or
message list to inject, and POSITION is the insertion index."
  (let* ((msgs (or (plist-get data :messages) []))
         (new (if (keywordp (car-safe new-prompt))
                  (list new-prompt)
                new-prompt))
         (pos (or position (length msgs))))
    (plist-put data :messages
               (vconcat (substring msgs 0 pos) new (substring msgs pos)))))

(provide 'gptel-agent-harness-test-utils)

;; Local Variables:
;; package-lint-main-file: "test/gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-test-utils.el ends here
