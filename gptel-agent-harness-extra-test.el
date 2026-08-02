;;; gptel-agent-harness-extra-test.el --- Extra tests for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: gptel-agent-harness:deepseek-v4-flash
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
;; ERT tests for gptel-agent-harness modules that do not belong in
;; gptel-agent-harness-test.el: the safety layer
;; (gptel-agent-harness-safety.el), the enhanced tools
;; (gptel-agent-harness-tools.el: glob/grep/Question), and the result
;; cache (gptel-agent-harness-cache.el).  More module tests can be
;; added here as the suite grows.
;;
;; Split from gptel-agent-harness-test.el (which keeps the core
;; supervision/context/session/commands tests) so the suite stays
;; manageable.  Load both files and run with:
;;   Emacs --batch -L /path/to/gptel \
;;     -L /path/to/gptel-agent \
;;     -L /path/to/gptel-agent-harness \
;;     -l gptel-agent-harness-test \
;;     -l gptel-agent-harness-extra-test \
;;     --eval '(ert-run-tests-batch "^gptel-agent-harness")'
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-agent-harness)
(require 'gptel-agent-harness-safety)

;; Ensure gptel backends are available (needed for `gptel' function in
;; commands tests when running in batch mode).
(require 'gptel-openai nil t)

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
    (fset 'gptel--update-status (lambda (&rest _) nil))))

;;;; Test Helpers

(defmacro gptel-agent-harness-test--with-buffer (buf-var &rest body)
  "Create a temp buffer bound to BUF-VAR, execute BODY, kill buffer."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,buf-var (generate-new-buffer " *harness-test*")))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,buf-var)
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

;;;; Forbidden Path Guard Tests

(ert-deftest gptel-agent-harness-test-safety-path-forbidden-p ()
  "Test forbidden-path matching against the default `/mnt/' pattern."
  (should (gptel-agent-harness-safety--path-forbidden-p "/mnt/secret"))
  (should (gptel-agent-harness-safety--path-forbidden-p "/mnt/data/file.txt"))
  (should-not (gptel-agent-harness-safety--path-forbidden-p "/tmp/foo"))
  (should-not (gptel-agent-harness-safety--path-forbidden-p nil))
  (should-not (gptel-agent-harness-safety--path-forbidden-p 42)))

(ert-deftest gptel-agent-harness-test-safety-check-path-signals ()
  "Test `--check-path' errors on forbidden paths, passes on safe ones."
  (should-error (gptel-agent-harness-safety--check-path "/mnt/x" "Read")
                :type 'error)
  (should-not (gptel-agent-harness-safety--check-path "/tmp/x" "Read")))

(ert-deftest gptel-agent-harness-test-safety-read-guard-blocks ()
  "Read guard rejects a forbidden path without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--read-guard
      (lambda (&rest _) (setq called t)) "/mnt/foo.txt" nil nil)
     :type 'error)
    (should-not called))
  ;; Safe path passes through
  (let ((result (gptel-agent-harness-safety--read-guard
                 (lambda (f &rest _) (format "read %s" f))
                 "/tmp/foo.txt" nil nil)))
    (should (equal result "read /tmp/foo.txt"))))

(ert-deftest gptel-agent-harness-test-safety-glob-guard-blocks ()
  "Glob guard rejects a forbidden search PATH without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--glob-guard
      (lambda (&rest _) (setq called t)) "*" "/mnt/" nil)
     :type 'error)
    (should-not called))
  (let ((result (gptel-agent-harness-safety--glob-guard
                 (lambda (_pattern path &rest _) (format "glob %s" path))
                 "*" "/tmp" nil)))
    (should (equal result "glob /tmp"))))

(ert-deftest gptel-agent-harness-test-safety-grep-guard-blocks ()
  "Grep guard rejects a forbidden search PATH without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--grep-guard
      (lambda (&rest _) (setq called t)) "pat" "/mnt/" nil nil)
     :type 'error)
    (should-not called)))

(ert-deftest gptel-agent-harness-test-safety-edit-guard-blocks ()
  "Edit guard rejects a forbidden PATH without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--edit-guard
      (lambda (&rest _) (setq called t)) "/mnt/x.txt" "a" "b" nil)
     :type 'error)
    (should-not called)))

(ert-deftest gptel-agent-harness-test-safety-insert-guard-blocks ()
  "Insert guard rejects a forbidden PATH without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--insert-guard
      (lambda (&rest _) (setq called t)) "/mnt/x.txt" 1 "x")
     :type 'error)
    (should-not called)))

(ert-deftest gptel-agent-harness-test-safety-write-guard-blocks ()
  "Write guard rejects a forbidden target without calling ORIG-FN."
  (let ((called nil))
    (should-error
     (gptel-agent-harness-safety--write-guard
      (lambda (&rest _) (setq called t)) "/mnt/" "x.txt" "content")
     :type 'error)
    (should-not called)))

;;;; Plan-Mode Read-Only Guard Tests

(defmacro gptel-agent-harness-test-safety--with-plan-mode (plan-p plan-file &rest body)
  "Run BODY with plan-mode state bound.
PLAN-P non-nil sets `gptel-agent-harness--mode' to `plan', PLAN-FILE
sets `gptel-agent-harness--plan-file' (both buffer-local)."
  (declare (indent 2) (debug (form form body)))
  `(gptel-agent-harness-test--with-buffer buf
     (with-current-buffer buf
       (setq-local gptel-agent-harness--mode (if ,plan-p 'plan 'build))
       (setq-local gptel-agent-harness--plan-file ,plan-file))
     (with-current-buffer buf
       ,@body)))

(ert-deftest gptel-agent-harness-test-safety-plan-mode-blocks-writes ()
  "Plan mode refuses Edit/Write/Insert/Mkdir except on the plan file."
  (let ((plan-file "/tmp/proj/PLAN.md"))
    (gptel-agent-harness-test-safety--with-plan-mode t plan-file
      ;; Edit on a non-plan file is blocked.
      (let ((called nil))
        (should-error
         (gptel-agent-harness-safety--edit-guard
          (lambda (&rest _) (setq called t)) "/tmp/proj/src.el" "a" "b" nil)
         :type 'error)
        (should-not called))
      ;; Write on a non-plan file is blocked.
      (let ((called nil))
        (should-error
         (gptel-agent-harness-safety--write-guard
          (lambda (&rest _) (setq called t)) "/tmp/proj/" "src.el" "x")
         :type 'error)
        (should-not called))
      ;; Insert on a non-plan file is blocked.
      (let ((called nil))
        (should-error
         (gptel-agent-harness-safety--insert-guard
          (lambda (&rest _) (setq called t)) "/tmp/proj/src.el" 1 "x")
         :type 'error)
        (should-not called))
      ;; Mkdir is always blocked in plan mode.
      (let ((called nil))
        (should-error
         (gptel-agent-harness-safety--mkdir-guard
          (lambda (&rest _) (setq called t)) "/tmp/proj" "newdir")
         :type 'error)
        (should-not called))
      ;; The plan file itself remains writable.
      (let ((called nil))
        (gptel-agent-harness-safety--edit-guard
         (lambda (&rest _) (setq called t)) plan-file "a" "b" nil)
        (should called))
      (let ((called nil))
        (gptel-agent-harness-safety--write-guard
         (lambda (&rest _) (setq called t)) "/tmp/proj/" "PLAN.md" "x")
        (should called)))))

(ert-deftest gptel-agent-harness-test-safety-build-mode-allows-writes ()
  "Build mode does not restrict write tools."
  (gptel-agent-harness-test-safety--with-plan-mode nil nil
    (let ((called nil))
      (gptel-agent-harness-safety--edit-guard
       (lambda (&rest _) (setq called t)) "/tmp/proj/src.el" "a" "b" nil)
      (should called))
    (let ((called nil))
      (gptel-agent-harness-safety--mkdir-guard
       (lambda (&rest _) (setq called t)) "/tmp/proj" "newdir")
      (should called))))

(ert-deftest gptel-agent-harness-test-safety-plan-mode-blocks-bash ()
  "Plan mode allows read-only Bash but refuses mutating commands."
  (gptel-agent-harness-test-safety--with-plan-mode t "/tmp/proj/PLAN.md"
    ;; Read-only inspection commands are allowed.
    (dolist (cmd '("ls /tmp" "git status" "git diff HEAD" "cat /etc/hostname"
                   "grep -r foo /tmp" "cd /tmp && ls"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should (car result))
        (should-not (cdr result))))
    ;; Forbidden paths are still refused even when the command is read-only.
    (let ((result (gptel-agent-harness-test-safety--run-bash-advice "cat /mnt/secret")))
      (should-not (car result))
      (should (string-match-p "forbidden" (or (cdr result) ""))))
    ;; Mutating commands are refused, with a plan-mode message.
    (dolist (cmd '("rm -rf /tmp/cache" "touch /tmp/x" "mkdir -p /tmp/x"
                   "echo hi > /tmp/x" "git commit -m x" "git push origin main"
                   "git -C /tmp commit -m x" "git --no-pager push"
                   "sudo apt-get update"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should-not (car result))
        (should (string-match-p "plan mode" (or (cdr result) "")))))
    ;; Unknown/arbitrary commands are refused (not on the whitelist).
    (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                   "some-custom-tool --do-thing")))
      (should-not (car result))
      (should (string-match-p "plan mode" (or (cdr result) ""))))))

(ert-deftest gptel-agent-harness-test-safety-build-mode-allows-bash ()
  "Build mode Bash commands pass through the plan-mode check."
  (gptel-agent-harness-test-safety--with-plan-mode nil nil
    (let ((result (gptel-agent-harness-test-safety--run-bash-advice "ls /tmp")))
      (should (car result))
      (should-not (cdr result)))))

(ert-deftest gptel-agent-harness-test-set-mode-refuses-forbidden-plan-file ()
  "Switching to plan mode refuses to create the plan file under a forbidden path."
  (let ((gptel-agent-harness-safety-forbidden-paths '("/tmp/hm-forbidden/")))
    (gptel-agent-harness-test--with-buffer buf
      (with-current-buffer buf
        (setq-local gptel-agent-harness--project-dir "/tmp/hm-forbidden/proj")
        (should-error (gptel-agent-harness-set-mode 'plan) :type 'error)
        (should-not (file-exists-p "/tmp/hm-forbidden/proj/PLAN.md"))
        (should-not (eq gptel-agent-harness--mode 'plan))))))

;;;; Bash Approval Tier Tests

(defun gptel-agent-harness-test-safety--run-bash-advice (command &optional ask-fn)
  "Run COMMAND through the Bash advice with a fake ORIG-FN.
ASK-FN replaces `gptel-agent-harness-safety--ask-approval' when
provided.  Returns (RAN . ERROR-MSG): RAN non-nil if ORIG-FN was
invoked, ERROR-MSG the callback string otherwise."
  (let (ran err)
    (cl-letf (((symbol-function 'gptel-agent-harness-safety--ask-approval)
               (or ask-fn (lambda (_cmd) ((error "Ask called unexpectedly"))))))
      (gptel-agent-harness-safety--execute-bash-advice
       (lambda (_cb _cmd) (setq ran t) nil)
       (lambda (msg) (setq err msg))
       command))
    (cons ran err)))

(ert-deftest gptel-agent-harness-test-safety-catastrophic-always-blocked ()
  "Catastrophic commands are refused even with approval nil and confirm-tool-calls nil."
  (let ((gptel-agent-harness-safety-bash-approval nil)
        (gptel-confirm-tool-calls nil))
    (dolist (cmd '("rm -rf /" "rm -rf /*" "rm -fr /" "sudo rm -r -f /"
                   "mkfs.ext4 /dev/sda1" "dd if=/dev/zero of=/dev/sda"
                   "shutdown -h now" "reboot" "echo x > /dev/sda"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should-not (car result))
        (should (string-match-p "blocked" (or (cdr result) "")))))))

(ert-deftest gptel-agent-harness-test-safety-bash-forbidden-path-blocked ()
  "Bash commands referencing a forbidden path are always refused."
  (let ((result (gptel-agent-harness-test-safety--run-bash-advice "cat /mnt/secret")))
    (should-not (car result))
    (should (string-match-p "forbidden" (or (cdr result) "")))))

(ert-deftest gptel-agent-harness-test-safety-dangerous-no-prompt-when-confirm-nil ()
  "Dangerous commands run without prompting when confirm-tool-calls is nil."
  (let ((gptel-agent-harness-safety-bash-approval 'confirm)
        (gptel-confirm-tool-calls nil))
    (dolist (cmd '("rm -rf /tmp/cache" "git push --force origin main"
                   "git reset --hard HEAD" "chmod -R 777 /tmp/x"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should (car result))
        (should-not (cdr result))))))

(ert-deftest gptel-agent-harness-test-safety-dangerous-asks-when-confirm ()
  "Dangerous commands ask the user when confirm-tool-calls is non-nil."
  (let ((gptel-agent-harness-safety-bash-approval 'confirm)
        (gptel-confirm-tool-calls t))
    ;; yes → run
    (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                   "rm -rf /tmp/cache" (lambda (_cmd) t))))
      (should (car result))
      (should-not (cdr result)))
    ;; no → reject
    (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                   "rm -rf /tmp/cache" (lambda (_cmd) nil))))
      (should-not (car result))
      (should (cdr result)))))

(ert-deftest gptel-agent-harness-test-safety-block-policy ()
  "Block policy refuses dangerous and destructive commands without asking."
  (let ((gptel-agent-harness-safety-bash-approval 'block))
    (dolist (cmd '("rm -rf /tmp/cache" "sudo apt-get update" "pkill -f node"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should-not (car result))
        (should (cdr result))))))

(ert-deftest gptel-agent-harness-test-safety-destructive-never-prompts ()
  "Destructive-but-common commands (sudo/pkill/killall) never prompt."
  (let ((gptel-agent-harness-safety-bash-approval 'confirm)
        (gptel-confirm-tool-calls t))
    (dolist (cmd '("sudo apt-get update" "sudo make install"
                   "pkill -f node" "killall emacs"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should (car result))
        (should-not (cdr result))))))

(ert-deftest gptel-agent-harness-test-safety-normal-bash-runs ()
  "Normal commands pass through unchanged."
  (let ((gptel-agent-harness-safety-bash-approval 'confirm)
        (gptel-confirm-tool-calls t))
    (dolist (cmd '("ls -la" "grep -i error app.log | tail -20" "make -j4"))
      (let ((result (gptel-agent-harness-test-safety--run-bash-advice cmd)))
        (should (car result))
        (should-not (cdr result))))))

;;;; Session Allow/Deny Tests

(ert-deftest gptel-agent-harness-test-safety-session-allow-remembered ()
  "Choosing `allow' runs the command and skips future prompts for it."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (let ((gptel-agent-harness-safety-bash-approval 'confirm)
            (gptel-confirm-tool-calls t))
        ;; allow once → runs and is remembered
        (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                       "git reset --hard HEAD" (lambda (_cmd) 'allow))))
          (should (car result))
          (should-not (cdr result))
          (should (member "git reset --hard HEAD"
                          gptel-agent-harness-safety--session-allow)))
        ;; second call: no ask, runs
        (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                       "git reset --hard HEAD" (lambda (_cmd) ((error "Asked again"))))))
          (should (car result))
          (should-not (cdr result)))))))

(ert-deftest gptel-agent-harness-test-safety-session-deny-remembered ()
  "Choosing `deny' rejects the command and skips future prompts for it."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (let ((gptel-agent-harness-safety-bash-approval 'confirm)
            (gptel-confirm-tool-calls t))
        (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                       "chmod -R 777 /tmp/x" (lambda (_cmd) 'deny))))
          (should-not (car result))
          (should (cdr result))
          (should (member "chmod -R 777 /tmp/x"
                          gptel-agent-harness-safety--session-deny)))
        ;; second call: no ask, rejected
        (let ((result (gptel-agent-harness-test-safety--run-bash-advice
                       "chmod -R 777 /tmp/x" (lambda (_cmd) ((error "Asked again"))))))
          (should-not (car result))
          (should (cdr result)))))))

(ert-deftest gptel-agent-harness-test-safety-clear-session ()
  "`gptel-agent-harness-safety-clear-session' resets allow/deny state."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness-safety--session-allow '("cmd-a"))
      (setq gptel-agent-harness-safety--session-deny '("cmd-b"))
      (gptel-agent-harness-safety-clear-session)
      (should-not gptel-agent-harness-safety--session-allow)
      (should-not gptel-agent-harness-safety--session-deny))))

;;;; Bash Timeout Tests

(ert-deftest gptel-agent-harness-test-safety-timeout-callback ()
  "`--timeout-callback' kills a live process and reports via CALLBACK."
  (let ((proc (make-process :name "safety-timeout-test"
                            :command (list "sleep" "30")
                            :noquery t)))
    (sleep-for 0.1)
    (let ((msg nil))
      (gptel-agent-harness-safety--timeout-callback
       proc (lambda (m) (setq msg m)) "sleep 30" 1)
      (should (string-match-p "timed out" (or msg "")))
      (should-not (process-live-p proc)))))

(ert-deftest gptel-agent-harness-test-safety-bash-timeout-kills-process ()
  "A hung Bash command is killed after the configured timeout."
  (let ((gptel-agent-harness-safety-bash-timeout 1)
        (done nil) (result nil))
    (gptel-agent-harness-safety--execute-bash-advice
     (lambda (cb cmd) (gptel-agent--execute-bash cb cmd))
     (lambda (msg) (setq result msg done t))
     "sleep 10")
    (let ((t0 (float-time)))
      (while (and (not done) (< (- (float-time) t0) 8))
        (accept-process-output nil 0.1)))
    (should done)
    (should (string-match-p "timed out" (or result "")))))

(ert-deftest gptel-agent-harness-test-safety-bash-timeout-disabled ()
  "A nil timeout does not wrap the process."
  (let ((gptel-agent-harness-safety-bash-timeout nil)
        (done nil) (result nil))
    (gptel-agent-harness-safety--execute-bash-advice
     (lambda (cb cmd) (gptel-agent--execute-bash cb cmd))
     (lambda (msg) (setq result msg done t))
     "echo no-timeout")
    (let ((t0 (float-time)))
      (while (and (not done) (< (- (float-time) t0) 5))
        (accept-process-output nil 0.1)))
    (should done)
    (should (string-match-p "no-timeout" (or result "")))))

;;;; Edit Undo Tests

(ert-deftest gptel-agent-harness-test-safety-undo-restores-edit ()
  "Undo restores the pre-Edit snapshot byte-for-byte."
  (gptel-agent-harness-test--with-buffer buf
    (gptel-agent-harness-test--with-temp-dir dir
      (let ((f (expand-file-name "file.txt" dir)))
        (with-temp-file f (insert "original\n"))
        (with-current-buffer buf
          (gptel-agent-harness-safety--snapshot-file f "Edit"))
        (with-temp-file f (insert "changed\n"))
        (with-current-buffer buf
          (gptel-agent-harness-undo-last-edit))
        (should (string=
                 (with-temp-buffer (insert-file-contents f) (buffer-string))
                 "original\n"))))))

(ert-deftest gptel-agent-harness-test-safety-undo-removes-new-file ()
  "Undo of a Write that created a new file removes it."
  (gptel-agent-harness-test--with-buffer buf
    (gptel-agent-harness-test--with-temp-dir dir
      (let ((f (expand-file-name "new.txt" dir)))
        (with-current-buffer buf
          (gptel-agent-harness-safety--record-absent f "Write"))
        (with-temp-file f (insert "hello"))
        (should (file-exists-p f))
        (with-current-buffer buf
          (gptel-agent-harness-undo-last-edit))
        (should-not (file-exists-p f))))))

(ert-deftest gptel-agent-harness-test-safety-undo-keeps-entry-on-failure ()
  "A failed restore keeps the entry on the stack so it can be retried."
  (gptel-agent-harness-test--with-buffer buf
    (gptel-agent-harness-test--with-temp-dir dir
      (with-current-buffer buf
        (let ((f (expand-file-name "file.txt" dir))
              (bak (expand-file-name "backup-dir" dir)))
          (make-directory bak)
          (setq gptel-agent-harness-safety--undo-stack
                (list (list :path f :backup bak :existed t
                            :tool "Edit" :time (float-time))))
          (gptel-agent-harness-undo-last-edit)
          (should (= (length gptel-agent-harness-safety--undo-stack) 1)))))))

(ert-deftest gptel-agent-harness-test-safety-undo-drops-missing-backup ()
  "An entry whose backup file is gone is dropped."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness-safety--undo-stack
            (list (list :path "/tmp/nonexistent-file"
                        :backup "/tmp/nonexistent-backup" :existed t
                        :tool "Edit" :time (float-time))))
      (gptel-agent-harness-undo-last-edit)
      (should (null gptel-agent-harness-safety--undo-stack)))))

(ert-deftest gptel-agent-harness-test-safety-undo-empty-stack ()
  "Undo with an empty stack is a no-op."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (setq gptel-agent-harness-safety--undo-stack nil)
      (should (string-match-p
               "nothing to undo"
               (or (gptel-agent-harness-undo-last-edit) ""))))))

;;;; Safety Enable/Disable Tests

(ert-deftest gptel-agent-harness-test-safety-enable-adds-advice ()
  "`gptel-agent-harness-safety-enable' installs all guards."
  (unwind-protect
      (progn
        (gptel-agent-harness-safety-enable)
        (should (advice-member-p #'gptel-agent-harness-safety--read-guard
                                 'gptel-agent--read-file-lines))
        (should (advice-member-p #'gptel-agent-harness-safety--glob-guard
                                 'gptel-agent--glob))
        (should (advice-member-p #'gptel-agent-harness-safety--grep-guard
                                 'gptel-agent--grep))
        (should (advice-member-p #'gptel-agent-harness-safety--edit-guard
                                 'gptel-agent--edit-files))
        (should (advice-member-p #'gptel-agent-harness-safety--insert-guard
                                 'gptel-agent--insert-in-file))
        (should (advice-member-p #'gptel-agent-harness-safety--write-guard
                                 'gptel-agent--write-file))
        (should (advice-member-p #'gptel-agent-harness-safety--execute-bash-advice
                                 'gptel-agent--execute-bash)))
    (gptel-agent-harness-safety-disable)))

(ert-deftest gptel-agent-harness-test-safety-disable-removes-advice ()
  "`gptel-agent-harness-safety-disable' removes all guards."
  (gptel-agent-harness-safety-enable)
  (gptel-agent-harness-safety-disable)
  (should-not (advice-member-p #'gptel-agent-harness-safety--read-guard
                               'gptel-agent--read-file-lines))
  (should-not (advice-member-p #'gptel-agent-harness-safety--glob-guard
                               'gptel-agent--glob))
  (should-not (advice-member-p #'gptel-agent-harness-safety--grep-guard
                               'gptel-agent--grep))
  (should-not (advice-member-p #'gptel-agent-harness-safety--edit-guard
                               'gptel-agent--edit-files))
  (should-not (advice-member-p #'gptel-agent-harness-safety--insert-guard
                               'gptel-agent--insert-in-file))
  (should-not (advice-member-p #'gptel-agent-harness-safety--write-guard
                               'gptel-agent--write-file))
  (should-not (advice-member-p #'gptel-agent-harness-safety--execute-bash-advice
                               'gptel-agent--execute-bash)))

(ert-deftest gptel-agent-harness-test-safety-enabled-blocks-real-call ()
  "With safety enabled, a real Read on a forbidden path errors."
  (gptel-agent-harness-test--with-temp-dir dir
    (let* ((forbidden (expand-file-name "secret" dir))
           (gptel-agent-harness-safety-forbidden-paths
            (list (regexp-quote forbidden)))
           (blocked (expand-file-name "data.txt" forbidden))
           (safe (expand-file-name "data.txt" dir)))
      (make-directory forbidden)
      (with-temp-file blocked (insert "x"))
      (with-temp-file safe (insert "x"))
      (unwind-protect
          (progn
            (gptel-agent-harness-safety-enable)
            (should-error (gptel-agent--read-file-lines blocked nil nil)
                          :type 'error)
            (should-not
             (condition-case nil
                 (progn (gptel-agent--read-file-lines safe nil nil) nil)
               (error t))))
        (gptel-agent-harness-safety-disable)))))

;;;; Tool Override Tests (gptel-agent-harness-tools)

(ert-deftest gptel-agent-harness-test-tools-enable-disable-idempotent ()
  "Test tools enable/disable: overrides, restores, and idempotency."
  (let ((gptel-agent-harness-tools--orig-glob nil)
        (gptel-agent-harness-tools--orig-grep nil)
        (orig-glob (symbol-function 'gptel-agent--glob))
        (orig-grep (symbol-function 'gptel-agent--grep)))
    (unwind-protect
        (progn
          (gptel-agent-harness-tools-enable)
          ;; After enable, glob/grep should NOT be the originals
          (should-not (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should-not (eq (symbol-function 'gptel-agent--grep) orig-grep))
          ;; The originals should be saved
          (should (eq gptel-agent-harness-tools--orig-glob orig-glob))
          (should (eq gptel-agent-harness-tools--orig-grep orig-grep))
          ;; Second enable should not lose the originals
          (gptel-agent-harness-tools-enable)
          (should (eq gptel-agent-harness-tools--orig-glob orig-glob))
          (should (eq gptel-agent-harness-tools--orig-grep orig-grep))
          ;; Disable should restore
          (gptel-agent-harness-tools-disable)
          (should (eq (symbol-function 'gptel-agent--glob) orig-glob))
          (should (eq (symbol-function 'gptel-agent--grep) orig-grep)))
      ;; Safety restore
      (fset 'gptel-agent--glob orig-glob)
      (fset 'gptel-agent--grep orig-grep)
      (setq gptel-agent-harness-tools--orig-glob nil)
      (setq gptel-agent-harness-tools--orig-grep nil))))

;;;; Question Tool Tests

(ert-deftest gptel-agent-harness-test-question-ask-one-single-select ()
  "Test single-select question via `completing-read'."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _) (car choices))))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Pick one:" ["alpha" "beta" "gamma"] nil t)))
      (should (equal result '("alpha"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-multi-select ()
  "Test multi-select question via `completing-read-multiple'."
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (_prompt choices &rest _)
               (list (nth 0 choices) (nth 1 choices)))))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Pick many:" ["alpha" "beta" "gamma"] t t)))
      (should (equal result '("alpha" "beta"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-free-text ()
  "Test free-text fallback when no options provided."
  (cl-letf (((symbol-function 'read-string)
             (lambda (_prompt &rest _) "my custom answer")))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "What do you think?" nil nil nil)))
      (should (equal result '("my custom answer"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-custom-option ()
  "Test selecting the custom free-text option triggers `read-string'."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _)
               ;; Simulate user selecting the custom option (last item)
               (car (last choices))))
            ((symbol-function 'read-string)
             (lambda (_prompt &rest _) "typed answer")))
    (let ((result (gptel-agent-harness-tools--ask-one
                   "Choose:" ["opt1" "opt2"] nil t)))
      (should (equal result '("typed answer"))))))

(ert-deftest gptel-agent-harness-test-question-ask-one-no-custom ()
  "Test that custom=nil does not append the free-text option."
  (let ((offered-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq offered-choices choices)
                 (car choices))))
      (gptel-agent-harness-tools--ask-one
       "Choose:" ["opt1" "opt2"] nil nil)
      (should (equal offered-choices '("opt1" "opt2")))
      (should-not (member gptel-agent-harness-tools--custom-option
                          offered-choices)))))

(ert-deftest gptel-agent-harness-test-question-ask-questions-multiple ()
  "Test processing multiple questions returns formatted output."
  (let ((call-count 0))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (cl-incf call-count)
                 (car choices)))
              ((symbol-function 'read-string)
               (lambda (_prompt &rest _) "free text")))
      (let* ((questions (vector
                         (list :question "Q1?" :options ["a" "b"])
                         (list :question "Q2?")))  ; no options → free text
             (result (gptel-agent-harness-tools--ask-questions questions)))
        (should (string-match-p "\"Q1\\?\" = \"a\"" result))
        (should (string-match-p "\"Q2\\?\" = \"free text\"" result))))))

(ert-deftest gptel-agent-harness-test-question-custom-json-false ()
  "Test that :custom :json-false disables the custom option."
  (let ((offered-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq offered-choices choices)
                 (car choices))))
      (let* ((questions (vector
                         (list :question "Pick:" :options ["x" "y"]
                               :custom :json-false)))
             (result (gptel-agent-harness-tools--ask-questions questions)))
        (should (string-match-p "\"Pick:\" = \"x\"" result))
        (should-not (member gptel-agent-harness-tools--custom-option
                            offered-choices))))))

(ert-deftest gptel-agent-harness-test-question-register-unregister ()
  "Test Question tool registration and unregistration."
  (let ((gptel-agent-harness-tools--question-tool nil)
        (gptel--known-tools nil))
    ;; Register
    (gptel-agent-harness-tools--register-question)
    (should gptel-agent-harness-tools--question-tool)
    (should (assoc "gptel-agent" gptel--known-tools #'equal))
    ;; Unregister
    (gptel-agent-harness-tools--unregister-question)
    (should-not gptel-agent-harness-tools--question-tool)))

;;;; Glob Tool Tests

(ert-deftest gptel-agent-harness-test-glob-error-cases ()
  "Test glob signals errors for empty pattern and non-readable path."
  (should-error (gptel-agent-harness-tools--glob "")
                :type 'error)
  (should-error (gptel-agent-harness-tools--glob "*.txt" "/nonexistent/path/xyz")
                :type 'error))

(ert-deftest gptel-agent-harness-test-glob-respects-gitignore ()
  "Test glob respects .gitignore patterns."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name ".gitignore" temp-dir)
        (insert "ignored.txt\n"))
      (with-temp-file (expand-file-name "tracked.txt" temp-dir)
        (insert "tracked"))
      (with-temp-file (expand-file-name "ignored.txt" temp-dir)
        (insert "ignored"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      (let ((result (gptel-agent-harness-tools--glob "*.txt" temp-dir)))
        (should (string-match-p "tracked\\.txt" result))
        (should-not (string-match-p "ignored\\.txt" result))))))

;;;; Grep Tool Tests

(ert-deftest gptel-agent-harness-test-grep-nonexistent-path-errors ()
  "Test grep with non-readable path signals an error."
  (should-error (gptel-agent-harness-tools--grep "pattern" "/nonexistent/xyz")
                :type 'error))

(ert-deftest gptel-agent-harness-test-grep-in-git-repo ()
  "Test grep finds matches using git-grep in a git repo."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "foo.txt" temp-dir)
        (insert "line one\nfoo bar baz\nline three\n"))
      (with-temp-file (expand-file-name "bar.txt" temp-dir)
        (insert "nothing here\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Search for "foo" in the whole directory
      (let ((result (gptel-agent-harness-tools--grep "foo" temp-dir)))
        (should (string-match-p "foo bar baz" result))
        (should-not (string-match-p "nothing here" result)))
      ;; Search in a specific file
      (let ((result (gptel-agent-harness-tools--grep
                     "line" (expand-file-name "foo.txt" temp-dir))))
        (should (string-match-p "line one" result))
        (should (string-match-p "line three" result))))))

(ert-deftest gptel-agent-harness-test-grep-with-glob-filter ()
  "Test grep respects the glob filter parameter."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "match.el" temp-dir)
        (insert "target-pattern-here\n"))
      (with-temp-file (expand-file-name "match.txt" temp-dir)
        (insert "target-pattern-here\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Search with glob restricting to .el files only
      (let ((result (gptel-agent-harness-tools--grep
                     "target-pattern" temp-dir "*.el")))
        (should (string-match-p "match\\.el" result))
        (should-not (string-match-p "match\\.txt" result))))))

(ert-deftest gptel-agent-harness-test-grep-dash-pattern ()
  "Test grep handles patterns starting with a dash via -e flag."
  (gptel-agent-harness-test--with-temp-dir temp-dir
    (let ((default-directory temp-dir))
      (call-process "git" nil nil nil "init" temp-dir)
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.email" "test@test.com")
      (call-process "git" nil nil nil "-C" temp-dir "config" "user.name" "Test")
      (with-temp-file (expand-file-name "test.txt" temp-dir)
        (insert "normal line\n--flag-like-pattern\nanother line\n"))
      (call-process "git" nil nil nil "-C" temp-dir "add" ".")
      (call-process "git" nil nil nil "-C" temp-dir "commit" "-m" "init")
      ;; Pattern starting with dash should not be misinterpreted as a flag
      (let ((result (gptel-agent-harness-tools--grep
                     "--flag-like" (expand-file-name "test.txt" temp-dir))))
        (should (string-match-p "flag-like-pattern" result))))))

;;;; Cache Module Tests (gptel-agent-harness-cache)

(ert-deftest gptel-agent-harness-test-cache-make-key-canonicalizes ()
  "Test cache key canonicalizes paths but leaves non-paths alone."
  (let ((default-directory "/home/user/project/"))
    ;; Absolute path is preserved
    (let ((key (gptel-agent-harness-cache--make-key 'read '("/tmp/foo.el" 1 50))))
      (should (equal key '(read "/tmp/foo.el" 1 50))))
    ;; Relative path starting with . is expanded
    (let ((key (gptel-agent-harness-cache--make-key 'glob '("*.el" "./src" nil))))
      (should (equal (nth 2 key) "/home/user/project/src")))
    ;; Tilde path is expanded
    (let ((key (gptel-agent-harness-cache--make-key 'read '("~/foo.el" nil nil))))
      (should (string-prefix-p (expand-file-name "~") (nth 1 key))))
    ;; Non-path strings (patterns) are left alone
    (let ((key (gptel-agent-harness-cache--make-key 'grep '("defun.*foo" "/tmp" nil nil))))
      (should (equal (nth 1 key) "defun.*foo")))
    ;; nil values pass through
    (let ((key (gptel-agent-harness-cache--make-key 'read '("/tmp/f.el" nil nil))))
      (should (equal key '(read "/tmp/f.el" nil nil))))))

(ert-deftest gptel-agent-harness-test-cache-store-and-lookup ()
  "Test basic store and lookup operations."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-test-" nil ".el" "content"))
             (key '(read "/tmp/test.el" 1 10)))
        (unwind-protect
            (progn
              ;; Store
              (gptel-agent-harness-cache--store key "file content" temp-file)
              ;; Lookup succeeds
              (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                             "file content"))
              ;; Lookup with wrong key fails
              (should-not (gptel-agent-harness-cache--lookup
                           '(read "/tmp/other.el" 1 10) temp-file)))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-mtime-invalidation ()
  "Test that file modification invalidates cache entry."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((temp-file (make-temp-file "cache-mtime-" nil ".el" "original")))
        (unwind-protect
            (let ((key '(read "test" 1 10)))
              ;; Store with current mtime
              (gptel-agent-harness-cache--store key "original content" temp-file)
              (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                             "original content"))
              ;; Modify the file (changes mtime)
              (sleep-for 0.1)
              (with-temp-file temp-file (insert "modified"))
              ;; Lookup should now return nil (stale)
              (should-not (gptel-agent-harness-cache--lookup key temp-file)))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-ttl-invalidation ()
  "Test that TTL expiry invalidates directory-based cache entries."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-ttl 1)
             (key '(glob "*.el" "/tmp" nil)))
        ;; Store (path is a directory, so TTL is used)
        (gptel-agent-harness-cache--store key "file1.el\nfile2.el" "/tmp")
        (should (equal (gptel-agent-harness-cache--lookup key "/tmp")
                       "file1.el\nfile2.el"))
        ;; Wait for TTL to expire
        (sleep-for 1.1)
        ;; Should be invalidated
        (should-not (gptel-agent-harness-cache--lookup key "/tmp"))))))

(ert-deftest gptel-agent-harness-test-cache-deleted-file-invalidation ()
  "Test that a deleted file invalidates its cache entry."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((temp-file (make-temp-file "cache-del-" nil ".el" "content")))
        (let ((key '(read "test" nil nil)))
          ;; Store
          (gptel-agent-harness-cache--store key "file content" temp-file)
          (should (equal (gptel-agent-harness-cache--lookup key temp-file)
                         "file content"))
          ;; Delete the file
          (delete-file temp-file)
          ;; Should be invalid
          (should-not (gptel-agent-harness-cache--lookup key temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-dedup-same-epoch ()
  "Test deduplication returns short message on repeat access within epoch."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-dedup-" nil ".el" "content"))
             (key '(read "/tmp/f.el" 1 50))
             (gptel-agent-harness-verbose nil))
        (unwind-protect
            (progn
              ;; Store and first get - full result
              (gptel-agent-harness-cache--store key "full file content" temp-file)
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (equal result "full file content")))
              ;; Second get - dedup message
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (string-match-p "\\[Cached: Read" result))
                (should (string-match-p "17 chars" result))))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-epoch-reset ()
  "Test epoch reset clears seen set but preserves cache entries."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((temp-file (make-temp-file "cache-epoch-" nil ".el" "data"))
             (key '(read "/tmp/f.el" 1 50))
             (gptel-agent-harness-verbose nil))
        (unwind-protect
            (progn
              ;; Store and access (marks as seen)
              (gptel-agent-harness-cache--store key "the data" temp-file)
              (gptel-agent-harness-cache--get key temp-file)
              ;; Confirm it's in seen
              (should (gethash key gptel-agent-harness-cache--seen))
              ;; Reset epoch
              (gptel-agent-harness-cache--reset-epoch)
              ;; Seen is cleared
              (should-not (gethash key gptel-agent-harness-cache--seen))
              ;; Cache entry persists - next get returns full result
              (let ((result (gptel-agent-harness-cache--get key temp-file)))
                (should (equal result "the data"))))
          (delete-file temp-file))))))

(ert-deftest gptel-agent-harness-test-cache-write-through-invalidation ()
  "Editing a file invalidates related cache entries (and their seen state).

Covers: exact-file match; a containing directory whether or not the
cached path carries a trailing slash (`expand-file-name' strips it in
real use); an ancestor directory that contains the file; and that
unrelated / sibling entries are preserved."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((file "/tmp/project/src/foo.el")
             ;; Invalidated:
             (key-read (list 'read file 1 50))                       ; exact file
             (key-grep-slash (list 'grep "pattern" "/tmp/project/src/" nil nil)) ; dir, trailing slash
             (key-grep-nodir (list 'grep "pattern" "/tmp/project/src" nil nil))  ; dir, no slash (real)
             (key-glob-ancestor (list 'glob "*.el" "/tmp/project" nil))          ; ancestor dir
             ;; Preserved:
             (key-grep-sibling (list 'grep "pattern" "/tmp/project/other" nil nil)) ; sibling dir
             (key-read-sibling (list 'read "/tmp/project/src/bar.el" 1 10))         ; sibling file
             (key-unrelated (list 'read "/tmp/other/bar.el" 1 10))                  ; unrelated
             (invalidated (list key-read key-grep-slash key-grep-nodir
                                key-glob-ancestor))
             (preserved (list key-grep-sibling key-read-sibling key-unrelated)))
        (dolist (k (append invalidated preserved))
          (puthash k (list :result "r" :mtime nil :timestamp (float-time))
                   gptel-agent-harness-cache--table)
          (puthash k t gptel-agent-harness-cache--seen))
        (gptel-agent-harness-cache--invalidate-path file)
        (dolist (k invalidated)
          (should-not (gethash k gptel-agent-harness-cache--table))
          (should-not (gethash k gptel-agent-harness-cache--seen)))
        (dolist (k preserved)
          (should (gethash k gptel-agent-harness-cache--table))
          (should (gethash k gptel-agent-harness-cache--seen)))))))

(ert-deftest gptel-agent-harness-test-cache-cacheable-p ()
  "Test `--cacheable-p' filters empty and error results."
  (should (gptel-agent-harness-cache--cacheable-p "file content here"))
  (should (gptel-agent-harness-cache--cacheable-p "1:match\n2:match"))
  (should-not (gptel-agent-harness-cache--cacheable-p ""))
  (should-not (gptel-agent-harness-cache--cacheable-p nil))
  (should-not (gptel-agent-harness-cache--cacheable-p "Error: File not readable"))
  (should-not (gptel-agent-harness-cache--cacheable-p
               "Glob failed with exit code 1\n.STDOUT:\n\n")))

(ert-deftest gptel-agent-harness-test-cache-eviction ()
  "Test oldest entry is evicted when cache reaches max capacity."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let ((gptel-agent-harness-cache-max-entries 3))
        (gptel-agent-harness-cache--store '(a) "result-a" "/tmp")
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(b) "result-b" "/tmp")
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(c) "result-c" "/tmp")
        (should (= (hash-table-count gptel-agent-harness-cache--table) 3))
        ;; Add one more - oldest (a) should be evicted
        (sleep-for 0.01)
        (gptel-agent-harness-cache--store '(d) "result-d" "/tmp")
        (should (= (hash-table-count gptel-agent-harness-cache--table) 3))
        (should-not (gethash '(a) gptel-agent-harness-cache--table))
        (should (gethash '(b) gptel-agent-harness-cache--table))
        (should (gethash '(c) gptel-agent-harness-cache--table))
        (should (gethash '(d) gptel-agent-harness-cache--table))))))

(ert-deftest gptel-agent-harness-test-cache-stats ()
  "Test cache statistics are tracked correctly."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-verbose nil)
             (temp-file (make-temp-file "cache-stats-" nil ".el" "x"))
             (key '(read "/tmp/stats.el" 1 10)))
        (unwind-protect
            (progn
              ;; Reset stats
              (dolist (k '(:hits :misses :dedups :invalidations))
                (puthash k 0 gptel-agent-harness-cache--stats))
              ;; Store + first get = hit
              (gptel-agent-harness-cache--store key "content" temp-file)
              (gptel-agent-harness-cache--get key temp-file)
              (should (= (gethash :hits gptel-agent-harness-cache--stats) 1))
              ;; Second get = dedup
              (gptel-agent-harness-cache--get key temp-file)
              (should (= (gethash :dedups gptel-agent-harness-cache--stats) 1))
              ;; Modify file = invalidation on next lookup
              (sleep-for 0.1)
              (with-temp-file temp-file (insert "changed"))
              (gptel-agent-harness-cache--lookup key temp-file)
              (should (= (gethash :invalidations gptel-agent-harness-cache--stats) 1)))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-advice ()
  "Read/glob/grep advice each cache results and deduplicate repeats.
The `gptel-agent-harness-cache-enabled' flag is honored (disabled means
no caching).  Each advice is exercised twice: the first call misses and
invokes the wrapped fn; the second call dedups without re-invoking it."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (temp-file (make-temp-file "cache-adv-" nil ".el" "line1\nline2\n")))
        (unwind-protect
            (progn
              ;; (advice-fn args return-value first-call-match)
              (dolist (case
                       (list
                        (list #'gptel-agent-harness-cache--read-advice
                              (list temp-file 1 10) "content of file" "content of")
                        (list #'gptel-agent-harness-cache--glob-advice
                              (list "*.el" "/tmp" nil)
                              "/tmp/a.el\n/tmp/b.el\n" "a\\.el")
                        (list #'gptel-agent-harness-cache--grep-advice
                              (list "match" "/tmp/file.el" nil nil)
                              "5:match here\n" "match here")))
                (cl-destructuring-bind (advice args ret first-match) case
                  (let* ((call-count 0)
                         (fake (lambda (&rest _) (cl-incf call-count) ret)))
                    ;; First call: miss → real content, wrapped fn invoked once
                    (let ((r (apply advice fake args)))
                      (should (string-match-p first-match r))
                      (should (= call-count 1)))
                    ;; Second call: dedup → cached marker, wrapped fn not invoked
                    (let ((r (apply advice fake args)))
                      (should (string-match-p "\\[Cached:" r))
                      (should (= call-count 1))))))
              ;; Disabled flag: wrapped fn always invoked, no caching/dedup
              (let* ((gptel-agent-harness-cache-enabled nil)
                     (call-count 0)
                     (fake (lambda (&rest _) (cl-incf call-count) "content of file")))
                (gptel-agent-harness-cache--read-advice fake temp-file 1 10)
                (gptel-agent-harness-cache--read-advice fake temp-file 1 10)
                (should (= call-count 2))))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(ert-deftest gptel-agent-harness-test-cache-skips-error-results ()
  "Test that error results from tool calls are not cached."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      (gptel-agent-harness-cache--ensure-tables)
      (let* ((gptel-agent-harness-cache-enabled t)
             (gptel-agent-harness-verbose nil)
             (call-count 0)
             (fake-glob (lambda (_pattern &optional _path _depth)
                          (cl-incf call-count)
                          "Glob failed with exit code 1\n.STDOUT:\n\n")))
        ;; First call: error result, not cached
        (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)
        (should (= call-count 1))
        ;; Second call: still invokes orig-fn (not cached)
        (gptel-agent-harness-cache--glob-advice fake-glob "*.el" "/tmp" nil)
        (should (= call-count 2))))))

(ert-deftest gptel-agent-harness-test-cache-lifecycle ()
  "Test cache setup creates tables, clear empties them, teardown nils them."
  (gptel-agent-harness-test--with-buffer buf
    (with-current-buffer buf
      ;; Setup
      (should-not gptel-agent-harness-cache--table)
      (should-not gptel-agent-harness-cache--seen)
      (gptel-agent-harness-cache--setup)
      (should (hash-table-p gptel-agent-harness-cache--table))
      (should (hash-table-p gptel-agent-harness-cache--seen))
      ;; Populate and clear
      (puthash '(test) '(:result "x" :timestamp 0) gptel-agent-harness-cache--table)
      (puthash '(test) t gptel-agent-harness-cache--seen)
      (should (= (hash-table-count gptel-agent-harness-cache--table) 1))
      (should (= (hash-table-count gptel-agent-harness-cache--seen) 1))
      (gptel-agent-harness-cache-clear)
      (should (= (hash-table-count gptel-agent-harness-cache--table) 0))
      (should (= (hash-table-count gptel-agent-harness-cache--seen) 0))
      ;; Teardown
      (gptel-agent-harness-cache--teardown)
      (should-not gptel-agent-harness-cache--table)
      (should-not gptel-agent-harness-cache--seen))))

(ert-deftest gptel-agent-harness-test-cache-enable-disable ()
  "Test enable adds advice, disable removes it."
  (unwind-protect
      (progn
        (gptel-agent-harness-cache-enable)
        (should (advice-member-p #'gptel-agent-harness-cache--read-advice
                                 'gptel-agent--read-file-lines))
        (should (advice-member-p #'gptel-agent-harness-cache--glob-advice
                                 'gptel-agent--glob))
        (should (advice-member-p #'gptel-agent-harness-cache--grep-advice
                                 'gptel-agent--grep))
        (should (advice-member-p #'gptel-agent-harness-cache--after-edit
                                 'gptel-agent--edit-files))
        (should (advice-member-p #'gptel-agent-harness-cache--after-write
                                 'gptel-agent--write-file))
        (should (advice-member-p #'gptel-agent-harness-cache--after-insert
                                 'gptel-agent--insert-in-file))
        (gptel-agent-harness-cache-disable)
        (should-not (advice-member-p #'gptel-agent-harness-cache--read-advice
                                     'gptel-agent--read-file-lines))
        (should-not (advice-member-p #'gptel-agent-harness-cache--glob-advice
                                     'gptel-agent--glob))
        (should-not (advice-member-p #'gptel-agent-harness-cache--grep-advice
                                     'gptel-agent--grep)))
    (gptel-agent-harness-cache-disable)))

(provide 'gptel-agent-harness-extra-test)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness-test.el"
;; End:
;;; gptel-agent-harness-extra-test.el ends here
