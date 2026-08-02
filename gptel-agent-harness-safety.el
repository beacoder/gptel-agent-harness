;;; gptel-agent-harness-safety.el --- Safety layer for gptel-agent-harness -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; Assisted-by: gptel-agent-harness:deepseek-v4-flash
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
;; Safety layer for gptel-agent-harness:
;;
;; - Forbidden paths: tool operations (Read/Glob/Grep/Edit/Insert/Write)
;;   on paths matching `gptel-agent-harness-safety-forbidden-paths' are
;;   rejected with an error before any side effect.
;;
;; - Bash timeout: asynchronous Bash commands are killed after
;;   `gptel-agent-harness-safety-bash-timeout' seconds instead of
;;   hanging the FSM forever.
;;
;; - Bash approval: commands matching
;;   `gptel-agent-harness-safety-bash-dangerous-patterns' are
;;   confirmed with the user (`confirm') or denied outright (`block').
;;   When `gptel-confirm-tool-calls' is nil, the user's opt-out of
;;   confirmation is respected: no approval prompts are shown, and
;;   only commands matching
;;   `gptel-agent-harness-safety-bash-catastrophic-patterns' (root
;;   wipe, mkfs, shutdown, ...) are refused.  Commands matching
;;   `gptel-agent-harness-safety-bash-destructive-patterns' (sudo,
;;   pkill, killall) never prompt; they run unless the approval policy
;;   is `block'.  Approval answers can be remembered per session
;;   buffer (`allow'/`deny') so a decision is not asked twice;
;;   `gptel-agent-harness-safety-clear-session' resets that state.
;;
;; - Edit undo: every Edit/Write/Insert tool call snapshots the target
;;   file before modification.  `gptel-agent-harness-undo-last-edit'
;;   restores the most recent snapshot (per session buffer).
;;
;; Activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-safety)
;;
;;; Code:

(require 'cl-lib)
(require 'rmc)
(require 'gptel-agent)

;; Forward declarations — defined in gptel-agent-harness.el
(defvar gptel-agent-harness-verbose)
(defvar gptel-agent-harness--mode)
(defvar gptel-agent-harness--plan-file)

;; Forward declarations — defined in gptel-request.el (via gptel)
(defvar gptel-confirm-tool-calls)

;;;; User Options

(defcustom gptel-agent-harness-safety-forbidden-paths
  '("/mnt/")
  "Regexps matching paths that tools must never touch.
Read/Glob/Grep/Edit/Insert/Write operations whose expanded path
matches any of these are rejected with an error.  Bash commands
containing a match are also blocked."
  :type '(repeat regexp)
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-bash-timeout 120
  "Maximum seconds a Bash tool call may run before being killed.
0 or nil disables the timeout."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Seconds"))
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-bash-approval 'confirm
  "Approval policy for dangerous Bash commands.
nil   - no approval, dangerous commands run as-is.
confirm - prompt the user before running a dangerous command.  The
  prompt is skipped when `gptel-confirm-tool-calls' is nil, honoring
  the user's opt-out of confirmation (catastrophic commands are still
  refused unconditionally).
block - refuse dangerous commands without asking.
Catastrophic commands (see
`gptel-agent-harness-safety-bash-catastrophic-patterns') are always
refused regardless of this setting."
  :type '(choice (const :tag "No approval" nil)
                 (const :tag "Confirm dangerous commands" confirm)
                 (const :tag "Block dangerous commands" block))
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-bash-dangerous-patterns
  '("\\brm\\s-+-rf?\\b"
    "\\bgit\\s-+push\\b.*--force\\b"
    "\\bgit\\s-+reset\\b.*--hard\\b"
    "\\bchmod\\s-+-R\\s-*[0-7][0-7][0-7]\\b"
    "\\bchown\\s-+-R\\b"
    "\\bsu\\s-+-"
    "\\btar\\s-+.*--remove-files\\b")
  "Regexps matched against the whole Bash command string.
Commands matching any pattern are subject to
`gptel-agent-harness-safety-bash-approval': prompted under `confirm'
\(only when `gptel-confirm-tool-calls' is non-nil) or refused under
`block'.  A command already allowed/denied for this session is not
asked about again.

Common-but-risky commands (`sudo', `pkill', `killall') are deliberately
kept out of this list — see
`gptel-agent-harness-safety-bash-destructive-patterns' — as are
irreversibly destructive operations (root wipe, mkfs, ...) — see
`gptel-agent-harness-safety-bash-catastrophic-patterns'."
  :type '(repeat regexp)
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-bash-destructive-patterns
  '("\\bkillall\\b"
    "\\bpkill\\b"
    "\\bsudo\\b")
  "Regexps for destructive but common Bash commands.

Commands matching these never prompt: they run under the `confirm'
approval policy (and when `gptel-confirm-tool-calls' is nil) and are
only refused when `gptel-agent-harness-safety-bash-approval' is
`block'."
  :type '(repeat regexp)
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-bash-catastrophic-patterns
  '("\\brm\\s-+-\\(?:[a-z]*r[a-z]*f[a-z]*\\|[a-z]*f[a-z]*r[a-z]*\\|r\\s-+-f[a-z]*\\|f\\s-+-r[a-z]*\\|[a-z]*r[a-z]*\\)\\s-+/\\(?:\\s-*$\\|\\*\\|\\.\\)"
    "\\bmkfs\\b"
    "\\bdd\\s-+if="
    "\\b:(){[^}]*}"
    "\\bshutdown\\b"
    "\\breboot\\b"
    ">\\s-*/dev/sd[a-z]"
    "\\bmv\\s-+/\\(?:\\s-\\|$\\)"
    "\\brmdir\\s-+/")
  "Regexps for irreversibly destructive Bash commands.

Commands matching any of these are always refused: no approval prompt
is shown and no setting can allow them.  This is the safety floor
that applies even when `gptel-confirm-tool-calls' is nil."
  :type '(repeat regexp)
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-plan-readonly-bash-commands
  '("ls" "dir" "find" "grep" "rg" "egrep" "fgrep" "cat" "head" "tail"
    "less" "more" "wc" "pwd" "echo" "printf" "date" "env" "printenv"
    "which" "type" "file" "stat" "du" "df" "uname" "hostname" "whoami"
    "id" "ps" "tree" "readlink" "realpath" "basename" "dirname"
    "hexdump" "od" "strings" "sort" "uniq" "cut" "awk" "jq" "yq" "git"
    "test" "true" "false" "seq")
  "Bash commands allowed during plan mode's read-only phase.

In plan mode the Bash tool refuses everything except commands whose
first word is in this list and which contain no mutating constructs
\(file redirection, `tee', `xargs', `sudo', mutating `git'
subcommands — see `gptel-agent-harness-safety--bash-mutating-p').
Read-only inspection (`ls', `grep', `cat', `git status', `git diff',
...) stays available for planning; everything else is blocked."
  :type '(repeat string)
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-undo-depth 50
  "Maximum number of file snapshots kept per session buffer."
  :type 'integer
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-safety-backup-dir
  (expand-file-name "gptel-agent-harness-undo/" temporary-file-directory)
  "Directory where file snapshots for undo are stored."
  :type 'directory
  :group 'gptel-agent-harness)

;;;; Internal State

(defvar-local gptel-agent-harness-safety--undo-stack nil
  "Buffer-local undo stack of file snapshots.
Each entry is a plist:
  (:path STRING :backup STRING-OR-NIL :existed BOOL :tool STRING :time FLOAT)")

(defvar-local gptel-agent-harness-safety--session-allow nil
  "Bash commands the user allowed for this session buffer.
Each entry is the exact command string.  A command in this list runs
without being prompted again.")

(defvar-local gptel-agent-harness-safety--session-deny nil
  "Bash commands the user denied for this session buffer.
Each entry is the exact command string.  A command in this list is
rejected without being prompted again.")

;;;; Path Guards

(defun gptel-agent-harness-safety--path-forbidden-p (path)
  "Return the matching forbidden regexp for PATH, or nil."
  (when (stringp path)
    (let ((expanded (expand-file-name path)))
      (cl-loop for regexp in gptel-agent-harness-safety-forbidden-paths
               when (string-match-p regexp expanded)
               return regexp))))

(defun gptel-agent-harness-safety--check-path (path tool-name)
  "Signal an error if PATH is forbidden.
TOOL-NAME is used in the error message."
  (when-let* ((regexp (gptel-agent-harness-safety--path-forbidden-p path)))
    (error "Error: %s blocked by harness safety — path %s matches forbidden pattern %S"
           tool-name (abbreviate-file-name (expand-file-name path)) regexp)))

(defun gptel-agent-harness-safety--check-path-args (tool-name &rest paths)
  "Check each of PATHS against forbidden paths, using TOOL-NAME in errors."
  (dolist (path paths)
    (when (stringp path)
      (gptel-agent-harness-safety--check-path path tool-name))))

(defun gptel-agent-harness-safety--path-guard (orig-fn tool-name &rest args)
  "Around advice checking ARGS for forbidden paths, then calling ORIG-FN.
TOOL-NAME names the tool for error messages."
  (gptel-agent-harness-safety--check-path-args tool-name args)
  (apply orig-fn args))

(defun gptel-agent-harness-safety--read-guard (orig-fn filename &optional start-line end-line)
  "Path guard for `gptel-agent--read-file-lines'; passes through to ORIG-FN.
Checks FILENAME against forbidden paths before reading lines
START-LINE to END-LINE."
  (gptel-agent-harness-safety--check-path filename "Read")
  (funcall orig-fn filename start-line end-line))

(defun gptel-agent-harness-safety--glob-guard (orig-fn pattern &optional path depth)
  "Path guard for `gptel-agent--glob'; passes through to ORIG-FN.
Checks PATTERN's search PATH (and DEPTH) before listing files."
  (gptel-agent-harness-safety--check-path (or path ".") "Glob")
  (funcall orig-fn pattern path depth))

(defun gptel-agent-harness-safety--grep-guard (orig-fn regex path &optional glob context-lines)
  "Path guard for `gptel-agent--grep'; passes through to ORIG-FN.
Checks REGEX's search PATH, optional GLOB and CONTEXT-LINES."
  (gptel-agent-harness-safety--check-path path "Grep")
  (funcall orig-fn regex path glob context-lines))

;;;; Plan-Mode Read-Only Guards

(defun gptel-agent-harness-safety--plan-mode-active-p ()
  "Return non-nil when the current buffer is in plan mode."
  (and (bound-and-true-p gptel-agent-harness--mode)
       (eq gptel-agent-harness--mode 'plan)))

(defun gptel-agent-harness-safety--plan-file-p (path)
  "Return non-nil when PATH is the plan file of the current buffer."
  (when (and (stringp path)
             (bound-and-true-p gptel-agent-harness--plan-file)
             (stringp gptel-agent-harness--plan-file))
    (string= (expand-file-name path)
             (expand-file-name gptel-agent-harness--plan-file))))

(defun gptel-agent-harness-safety--check-read-only (path tool-name)
  "Signal an error if PATH is not writable while plan mode is active.
TOOL-NAME names the tool for the error message.  The plan file itself
remains writable, per the plan-mode contract; everything else is
read-only during plan mode."
  (when (and (gptel-agent-harness-safety--plan-mode-active-p)
             (not (gptel-agent-harness-safety--plan-file-p path)))
    (error "Error: %s blocked by plan mode — read-only phase. Only the plan file may be modified."
           tool-name)))

(defun gptel-agent-harness-safety--mkdir-guard (orig-fn parent name)
  "Plan-mode guard for `gptel-agent--make-directory'; passes through to ORIG-FN.
Refuses directory creation while plan mode is active."
  (let ((path (expand-file-name name parent)))
    (gptel-agent-harness-safety--check-path path "Mkdir")
    (gptel-agent-harness-safety--check-read-only path "Mkdir"))
  (funcall orig-fn parent name))

(defun gptel-agent-harness-safety--edit-guard (orig-fn path &optional old-str new-str-or-diff diffp)
  "Path guard for `gptel-agent--edit-files'; passes through to ORIG-FN.
Checks PATH, the file to edit with OLD-STR/NEW-STR-OR-DIFF (or DIFFP),
before applying the change.  Also refuses edits while plan mode is
active, except for the plan file itself."
  (gptel-agent-harness-safety--check-path path "Edit")
  (gptel-agent-harness-safety--check-read-only path "Edit")
  (gptel-agent-harness-safety--snapshot-file path "Edit")
  (funcall orig-fn path old-str new-str-or-diff diffp))

(defun gptel-agent-harness-safety--insert-guard (orig-fn path line-number new-str)
  "Path guard for `gptel-agent--insert-in-file'; passes through to ORIG-FN.
Checks PATH, the file receiving NEW-STR at LINE-NUMBER, before inserting.
Also refuses inserts while plan mode is active, except for the plan
file itself."
  (gptel-agent-harness-safety--check-path path "Insert")
  (gptel-agent-harness-safety--check-read-only path "Insert")
  (gptel-agent-harness-safety--snapshot-file path "Insert")
  (funcall orig-fn path line-number new-str))

(defun gptel-agent-harness-safety--write-guard (orig-fn path filename content)
  "Path guard for `gptel-agent--write-file'; passes through to ORIG-FN.
Checks the target (FILENAME in PATH) before writing CONTENT.  Also
refuses writes while plan mode is active, except for the plan file
itself."
  (let ((full-path (expand-file-name filename path)))
    (gptel-agent-harness-safety--check-path full-path "Write")
    (gptel-agent-harness-safety--check-read-only full-path "Write")
    (gptel-agent-harness-safety--snapshot-file full-path "Write")
    (gptel-agent-harness-safety--record-absent full-path "Write")
    (funcall orig-fn path filename content)))

;;;; Bash Timeout

(defun gptel-agent-harness-safety--timeout-callback (proc orig-cb command timeout)
  "Kill PROC if it is still running and call ORIG-CB with a timeout error.
COMMAND and TIMEOUT are used in the message."
  (when (and proc (process-live-p proc))
    (delete-process proc)
    (funcall orig-cb
             (format "Error: Bash command timed out after %d seconds and was killed.\nCommand:\n%s"
                     timeout command))))

(defun gptel-agent-harness-safety--execute-bash-advice
    (orig-fn callback command)
  "Around advice for `gptel-agent--execute-bash'.

Checks forbidden paths and dangerous patterns in COMMAND, then wraps
the process with a timeout that kills it and reports failure via
CALLBACK instead of hanging the FSM.  ORIG-FN runs the command when
it passes the checks.

Refusal tiers, in order:
- forbidden path in COMMAND — always refused;
- catastrophic pattern — always refused, no prompt, no override;
- destructive pattern (`sudo', `pkill', `killall', ...) — never
  prompts; refused only when `gptel-agent-harness-safety-bash-approval'
  is `block';
- dangerous pattern — subject to
  `gptel-agent-harness-safety-bash-approval': `block' refuses without
  asking, `confirm' asks the user unless `gptel-confirm-tool-calls'
  is nil (the user opted out of confirmation, so the command runs),
  nil runs.

Session-scoped allow/deny recorded at the approval prompt takes
precedence over asking again."
  (cond
   ((gptel-agent-harness-safety--path-forbidden-p command)
    (funcall callback
             (format "Error: Bash blocked by harness safety — command references forbidden path pattern %S"
                     (gptel-agent-harness-safety--path-forbidden-p command)))
    nil)
   ((gptel-agent-harness-safety--plan-mode-active-p)
    (if (gptel-agent-harness-safety--bash-read-only-p command)
        (gptel-agent-harness-safety--run-bash orig-fn callback command)
      (funcall callback
               "Error: Bash blocked by plan mode — read-only phase. Only read-only commands are allowed (e.g. ls, grep, cat, git status/diff); use Read/Glob/Grep to inspect instead.")
      nil))
   ((gptel-agent-harness-safety--bash-catastrophic-p command)
    (funcall callback
             "Error: Bash blocked by harness safety — command matches a catastrophic pattern and is never allowed.")
    nil)
   ((gptel-agent-harness-safety--bash-destructive-p command)
    (if (eq gptel-agent-harness-safety-bash-approval 'block)
        (progn
          (funcall callback
                   "Error: Bash blocked by harness approval policy — command matches a destructive pattern.")
          nil)
      (gptel-agent-harness-safety--run-bash orig-fn callback command)))
   ((gptel-agent-harness-safety--bash-dangerous-p command)
    (let ((verdict (gptel-agent-harness-safety--bash-verdict command)))
      (cond
       ((eq verdict 'allow)
        (gptel-agent-harness-safety--session-remember command 'allow)
        (gptel-agent-harness-safety--run-bash orig-fn callback command))
       ((eq verdict 'deny)
        (gptel-agent-harness-safety--session-remember command 'deny)
        (funcall callback
                 "Error: Bash command rejected by user approval (denied for this session).")
        nil)
       ((null verdict)
        (funcall callback
                 "Error: Bash command rejected by user approval.")
        nil)
       (t
        (gptel-agent-harness-safety--run-bash orig-fn callback command)))))
   (t
    (gptel-agent-harness-safety--run-bash orig-fn callback command))))

(defun gptel-agent-harness-safety--run-bash (orig-fn callback command)
  "Run COMMAND through ORIG-FN wrapped with the safety timeout.
Reports failure via CALLBACK when the timeout kills the process."
  (let ((proc (funcall orig-fn callback command)))
    (when (and gptel-agent-harness-safety-bash-timeout
               (> gptel-agent-harness-safety-bash-timeout 0)
               proc)
      (run-at-time gptel-agent-harness-safety-bash-timeout nil
                   #'gptel-agent-harness-safety--timeout-callback
                   proc callback command
                   gptel-agent-harness-safety-bash-timeout))
    proc))

(defun gptel-agent-harness-safety--bash-verdict (command)
  "Decide what to do with dangerous COMMAND.

Return t to run it, nil to reject it, `allow' to run it and remember
the decision for this session, or `deny' to reject it and remember
the decision for this session.

Session allow/deny entries take precedence, then
`gptel-agent-harness-safety-bash-approval': `block' refuses without
asking; `confirm' asks the user via
`gptel-agent-harness-safety--ask-approval' unless
`gptel-confirm-tool-calls' is nil, in which case the user opted out
of confirmation and the command runs; nil runs."
  (cond
   ((member command gptel-agent-harness-safety--session-allow) t)
   ((member command gptel-agent-harness-safety--session-deny) 'deny)
   ((eq gptel-agent-harness-safety-bash-approval 'block) nil)
   ((eq gptel-agent-harness-safety-bash-approval 'confirm)
    (if gptel-confirm-tool-calls
        (gptel-agent-harness-safety--ask-approval command)
      t))
   (t t)))

(defun gptel-agent-harness-safety--ask-approval (command)
  "Ask the user what to do with dangerous COMMAND.

Return t to run it once, nil to deny it once, `allow' to run it and
remember the decision for this session, or `deny' to reject it and
remember the decision for this session."
  (if noninteractive
      (yes-or-no-p
       (format "Dangerous Bash command:\n\n%s\n\nRun it?" command))
    (let ((answer (read-multiple-choice
                   (format "Dangerous Bash command:\n\n%s\n\nWhat should I do?" command)
                   '((?y "run once")
                     (?n "deny once")
                     (?a "always allow this command in this session")
                     (?d "always deny this command in this session")))))
      (pcase (car answer)
        (?y t)
        (?n nil)
        (?a 'allow)
        (?d 'deny)))))

(defun gptel-agent-harness-safety--session-remember (command verdict)
  "Remember COMMAND for this session as allowed or denied.
VERDICT is `allow' or `deny'."
  (let ((var (if (eq verdict 'allow)
                 'gptel-agent-harness-safety--session-allow
               'gptel-agent-harness-safety--session-deny)))
    (set var (cl-pushnew command (symbol-value var) :test #'equal))
    (when gptel-agent-harness-verbose
      (message "gptel-agent-harness-safety: %s for this session: %s"
               (if (eq verdict 'allow) "allowed" "denied") command))))

;;;###autoload
(defun gptel-agent-harness-safety-clear-session ()
  "Clear session-scoped Bash allow/deny entries for the current buffer."
  (interactive)
  (setq gptel-agent-harness-safety--session-allow nil
        gptel-agent-harness-safety--session-deny nil)
  (message "gptel-agent-harness-safety: session allow/deny cleared"))

(defun gptel-agent-harness-safety--bash-match-p (command patterns)
  "Return non-nil if COMMAND matches any regexp in PATTERNS."
  (when (stringp command)
    (cl-loop for regexp in patterns
             when (string-match-p regexp command)
             return t)))

(defun gptel-agent-harness-safety--bash-dangerous-p (command)
  "Return non-nil if COMMAND matches a dangerous pattern."
  (gptel-agent-harness-safety--bash-match-p
   command gptel-agent-harness-safety-bash-dangerous-patterns))

(defun gptel-agent-harness-safety--bash-destructive-p (command)
  "Return non-nil if COMMAND matches a destructive-but-common pattern."
  (gptel-agent-harness-safety--bash-match-p
   command gptel-agent-harness-safety-bash-destructive-patterns))

(defun gptel-agent-harness-safety--bash-catastrophic-p (command)
  "Return non-nil if COMMAND matches a catastrophic pattern."
  (gptel-agent-harness-safety--bash-match-p
   command gptel-agent-harness-safety-bash-catastrophic-patterns))

;;;; Plan-Mode Read-Only Bash

(defun gptel-agent-harness-safety--bash-mutating-p (command)
  "Return non-nil when COMMAND performs writes or state changes.

Detects file redirections (except fd-duplication like 2>&1), `tee',
`xargs', `sudo', and `git' invocations with a mutating subcommand
\(commit, push, checkout, reset, ... — flags between `git' and the
subcommand are tolerated).  The first-word whitelist in
`gptel-agent-harness-safety-plan-readonly-bash-commands' covers the
remaining read-only commands; everything else is refused in plan mode
regardless of this predicate."
  (let ((c (downcase command)))
    (or (string-match-p ">>" c)                 ; append
        (string-match-p ">\\([^&]\\|&[^0-9]\\)" c) ; write, but not 2>&1
        (string-match-p "\\btee\\b" c)
        (string-match-p "\\bxargs\\b" c)
        (string-match-p "\\bsudo\\b" c)
        (string-match-p (concat "\\bgit\\b[^;&|\n]*"
                                "\\b\\(?:add\\|commit\\|push\\|pull\\|fetch\\|"
                                "merge\\|rebase\\|reset\\|checkout\\|switch\\|"
                                "restore\\|clean\\|rm\\|mv\\|remote\\|config\\|"
                                "gc\\|branch\\|tag\\|stash\\)\\b")
                        c))))

(defun gptel-agent-harness-safety--bash-first-command (command)
  "Return the first command word of COMMAND, or nil.
Skips leading environment assignments (VAR=...), `cd' (and its
argument), `time', and shell separators so `cd dir && git status'
yields `git'."
  (let ((words (split-string command nil t))
        (skip-next nil))
    (catch 'found
      (dolist (w words)
        (cond
         (skip-next (setq skip-next nil))
         ((string= w "cd") (setq skip-next t))
         ((string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=\\S-*\\'" w) nil)
         ((member w '("&&" ";" "|" "||" "time")) nil)
         (t (throw 'found w))))
      nil)))

(defun gptel-agent-harness-safety--bash-read-only-p (command)
  "Return non-nil when COMMAND is acceptable during plan mode.
COMMAND must be free of mutating constructs and its first word must
be a known read-only command (absolute paths are matched by
basename)."
  (and (not (gptel-agent-harness-safety--bash-mutating-p command))
       (let* ((first (gptel-agent-harness-safety--bash-first-command command))
              (name (and first (file-name-nondirectory first))))
         (and name
              (member name gptel-agent-harness-safety-plan-readonly-bash-commands)))))

;;;; Edit Undo

(defun gptel-agent-harness-safety--ensure-backup-dir ()
  "Create `gptel-agent-harness-safety-backup-dir' if needed."
  (unless (file-directory-p gptel-agent-harness-safety-backup-dir)
    (make-directory gptel-agent-harness-safety-backup-dir t)))

(defun gptel-agent-harness-safety--snapshot-file (path tool-name)
  "Snapshot the file at PATH before TOOL-NAME modifies it.
Pushes a plist onto the buffer-local undo stack.  Files that do not
exist yet are recorded as :existed nil so undo can delete them."
  (when (and (stringp path) (file-regular-p path))
    (gptel-agent-harness-safety--ensure-backup-dir)
    (let* ((backup (expand-file-name
                    (make-temp-name
                     (format "snap-%s-" (file-name-nondirectory path)))
                    gptel-agent-harness-safety-backup-dir))
           (entry (list :path (expand-file-name path)
                        :backup backup
                        :existed t
                        :tool tool-name
                        :time (float-time))))
      (condition-case nil
          (copy-file path backup t 'preserve-permissions)
        (error nil))
      (push entry gptel-agent-harness-safety--undo-stack)
      (when (> (length gptel-agent-harness-safety--undo-stack)
               gptel-agent-harness-safety-undo-depth)
        ;; Drop the OLDEST entry (tail) and its backup file.
        (let ((old (car (last gptel-agent-harness-safety--undo-stack))))
          (setq gptel-agent-harness-safety--undo-stack
                (butlast gptel-agent-harness-safety--undo-stack))
          (when-let* ((b (plist-get old :backup)))
            (ignore-errors (delete-file b)))))
      (when gptel-agent-harness-verbose
        (message "gptel-agent-harness-safety: snapshot %s (%s)"
                 (abbreviate-file-name (expand-file-name path)) tool-name)))))

(defun gptel-agent-harness-safety--record-absent (path tool-name)
  "Record PATH (which does not exist yet) on the undo stack.
Lets `gptel-agent-harness-undo-last-edit' remove files created by a
Write tool call.  TOOL-NAME is recorded for the undo history."
  (when (and (stringp path)
             (not (file-exists-p path))
             (not (file-directory-p path)))
    (push (list :path (expand-file-name path)
                :backup nil
                :existed nil
                :tool tool-name
                :time (float-time))
          gptel-agent-harness-safety--undo-stack)
    (when (> (length gptel-agent-harness-safety--undo-stack)
             gptel-agent-harness-safety-undo-depth)
      (setq gptel-agent-harness-safety--undo-stack
            (butlast gptel-agent-harness-safety--undo-stack)))))

;;;###autoload
(defun gptel-agent-harness-undo-last-edit ()
  "Restore the most recent file snapshot taken before an Edit/Write/Insert.
Works per gptel session buffer.  A second call restores the next-older
snapshot, and so on.  If a restore fails the snapshot is kept on the
stack so the call can be retried."
  (interactive)
  (if (null gptel-agent-harness-safety--undo-stack)
      (message "gptel-agent-harness-safety: nothing to undo")
    (let* ((entry (car gptel-agent-harness-safety--undo-stack))
           (path (plist-get entry :path))
           (backup (plist-get entry :backup))
           (existed (plist-get entry :existed))
           (tool (plist-get entry :tool))
           (drop (lambda ()
                   (pop gptel-agent-harness-safety--undo-stack)
                   (when backup (ignore-errors (delete-file backup))))))
      (cond
       ((and existed backup (file-exists-p backup))
        (condition-case err
            (progn
              (copy-file backup path t 'preserve-permissions)
              (funcall drop)
              (message "gptel-agent-harness-safety: restored %s (undo %s)"
                       (abbreviate-file-name path) tool))
          (error
           (message "gptel-agent-harness-safety: restore failed — %s"
                    (error-message-string err)))))
       ((not existed)
        (condition-case err
            (progn
              (when (file-exists-p path) (delete-file path))
              (funcall drop)
              (message "gptel-agent-harness-safety: removed %s (created by %s)"
                       (abbreviate-file-name path) tool))
          (error
           (message "gptel-agent-harness-safety: removal failed — %s"
                    (error-message-string err)))))
       (t
        ;; Backup file is gone — entry can never be restored, drop it.
        (pop gptel-agent-harness-safety--undo-stack)
        (message "gptel-agent-harness-safety: backup for %s missing, cannot restore"
                 (abbreviate-file-name path)))))))

;;;###autoload
(defun gptel-agent-harness-undo-history ()
  "Show the file snapshot history for the current session buffer."
  (interactive)
  (if (null gptel-agent-harness-safety--undo-stack)
      (message "gptel-agent-harness-safety: no snapshots recorded")
    (let ((lines
           (mapcar
            (lambda (entry)
              (format "%s  %-6s  %s"
                      (format-time-string "%H:%M:%S" (plist-get entry :time))
                      (plist-get entry :tool)
                      (abbreviate-file-name (plist-get entry :path))))
            (reverse gptel-agent-harness-safety--undo-stack))))
      (message "gptel-agent-harness-safety: %d snapshot(s):\n%s"
               (length lines) (mapconcat #'identity lines "\n")))))

(defun gptel-agent-harness-safety--cleanup-backups ()
  "Delete all backup files referenced by the current buffer's undo stack."
  (dolist (entry gptel-agent-harness-safety--undo-stack)
    (when-let* ((backup (plist-get entry :backup)))
      (ignore-errors (delete-file backup))))
  (setq gptel-agent-harness-safety--undo-stack nil))

;;;; Enable / Disable

(defun gptel-agent-harness-safety-enable ()
  "Activate the safety layer.
Installs path guards, Bash timeout/approval, and edit snapshots.
Advice is added with depth -100, before the caching layer at depth
-90, so forbidden paths are rejected even on cache hits."
  ;; Path guards (innermost of all :around advice)
  (advice-add 'gptel-agent--read-file-lines
              :around #'gptel-agent-harness-safety--read-guard '((depth . -100)))
  (advice-add 'gptel-agent--glob
              :around #'gptel-agent-harness-safety--glob-guard '((depth . -100)))
  (advice-add 'gptel-agent--grep
              :around #'gptel-agent-harness-safety--grep-guard '((depth . -100)))
  (advice-add 'gptel-agent--edit-files
              :around #'gptel-agent-harness-safety--edit-guard '((depth . -100)))
  (advice-add 'gptel-agent--insert-in-file
              :around #'gptel-agent-harness-safety--insert-guard '((depth . -100)))
  (advice-add 'gptel-agent--write-file
              :around #'gptel-agent-harness-safety--write-guard '((depth . -100)))
  (advice-add 'gptel-agent--make-directory
              :around #'gptel-agent-harness-safety--mkdir-guard '((depth . -100)))
  (advice-add 'gptel-agent--execute-bash
              :around #'gptel-agent-harness-safety--execute-bash-advice))

(defun gptel-agent-harness-safety-disable ()
  "Deactivate the safety layer."
  (advice-remove 'gptel-agent--read-file-lines
                 #'gptel-agent-harness-safety--read-guard)
  (advice-remove 'gptel-agent--glob
                 #'gptel-agent-harness-safety--glob-guard)
  (advice-remove 'gptel-agent--grep
                 #'gptel-agent-harness-safety--grep-guard)
  (advice-remove 'gptel-agent--edit-files
                 #'gptel-agent-harness-safety--edit-guard)
  (advice-remove 'gptel-agent--insert-in-file
                 #'gptel-agent-harness-safety--insert-guard)
  (advice-remove 'gptel-agent--write-file
                 #'gptel-agent-harness-safety--write-guard)
  (advice-remove 'gptel-agent--make-directory
                 #'gptel-agent-harness-safety--mkdir-guard)
  (advice-remove 'gptel-agent--execute-bash
                 #'gptel-agent-harness-safety--execute-bash-advice))

(provide 'gptel-agent-harness-safety)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-safety.el ends here
