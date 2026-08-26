;;; gptel-agent-harness-tools.el --- Improved glob/grep tools for gptel-agent-harness -*- lexical-binding: t -*-
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
;; Improved glob and grep tools for gptel-agent-harness:
;;
;; - `gptel-agent-harness-tools--glob': Uses `git ls-files' for fast,
;;   .gitignore-aware file listing in git repos, falling back to `tree'
;;   outside of git.
;;
;; - `gptel-agent-harness-tools--grep': Like the upstream grep but passes
;;   the regex via `-e' flag to git-grep for robustness.
;;
;; These are activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-tools)
;;
;;; Code:

(require 'gptel-agent)
(require 'cl-lib)

;;;; Internal State

(defvar gptel-agent-harness--default-tools
  '("Agent" "TodoWrite" "Glob" "Grep" "Read" "Insert" "Edit" "Write" "Mkdir" "Bash" "Skill" "Question")
  "Default tool names for `gptel-agent-harness-commands-initialize' and `-review'.")

;;;; Glob Tool — git ls-files with tree fallback

(defun gptel-agent-harness-tools--glob (pattern &optional path depth)

  "Find files matching PATTERN using `git ls-files' or `tree'.

Inside a git repository, uses `git ls-files' which is significantly
faster and respects .gitignore.  Falls back to `tree' outside git.

PATTERN is a glob pattern to match filenames against.
PATH is the optional directory to search (defaults to current directory).
DEPTH limits recursion depth when provided (non-negative integer).

`tree' is only required for the fallback: inside a git repository the
git strategy never invokes it, so its absence must not fail the tool
there.

Returns a string listing matching files with full paths.  If the
output is too large, it is truncated by `gptel-agent--truncate-buffer'."
  (when (string-empty-p pattern)
    (error "Error: pattern must not be empty"))
  (if path
      (unless (and (file-readable-p path) (file-directory-p path))
        (error "Error: path %s is not readable" path))
    (setq path "."))
  (let* ((full-path (directory-file-name (expand-file-name path)))
         (git-root
          (and (executable-find "git") (locate-dominating-file full-path ".git"))))
    (unless (or git-root (executable-find "tree"))
      (error "Error: Executable `tree` not found.  This tool cannot be used"))
    (with-temp-buffer
      (if git-root
          ;; --- Git Strategy ---
          (let* ((default-directory git-root)
                 (relative-dir (file-relative-name full-path git-root))
                 (pathspec (if (string= relative-dir ".")
                               pattern
                             (concat relative-dir "/" pattern)))
                 (exit-code
                  (call-process "git" nil t nil
                                "ls-files" "-z"
                                "--full-name"
                                "--cached"           ; Tracked files
                                "--others"           ; Untracked files
                                "--exclude-standard" ; Respect .gitignore
                                "--" pathspec)))
            (if (/= exit-code 0)
                (progn (goto-char (point-min))
                       (insert (format "Glob failed with exit code %d\n.STDOUT:\n\n"
                                       exit-code)))
              ;; Convert null-terminated strings to newline-separated full paths
              (goto-char (point-min))
              (while (search-forward "\0" nil t)
                (replace-match "\n"))
              ;; Filter by depth if specified
              (when (natnump depth)
                (let ((base-depth (if (string= relative-dir ".")
                                      0
                                    (1+ (cl-count ?/ relative-dir)))))
                  (goto-char (point-min))
                  (while (not (eobp))
                    (if (and (not (looking-at-p "^$"))
                             (>= (cl-count ?/ (buffer-substring
                                               (line-beginning-position)
                                               (line-end-position)))
                                 (+ base-depth depth)))
                        (delete-region (line-beginning-position)
                                       (min (1+ (line-end-position)) (point-max)))
                      (forward-line 1)))))
              ;; Prepend git-root to make paths absolute
              (goto-char (point-min))
              (let ((path-prefix (file-name-as-directory git-root)))
                (while (not (eobp))
                  (unless (looking-at-p "^$") ; Skip empty lines
                    (insert path-prefix))
                  (forward-line 1)))))
        ;; --- Tree Strategy (Fallback) ---
        (let* ((args (list "-l" "-f" "-i" "-I" ".git"
                           "--sort=mtime" "--ignore-case"
                           "--prune" "-P" pattern full-path))
               (args (if (natnump depth)
                         (nconc args (list "-L" (number-to-string depth)))
                       args))
               (exit-code (apply #'call-process "tree" nil t nil args)))
          (when (/= exit-code 0)
            (goto-char (point-min))
            (insert (format "Glob failed with exit code %d\n.STDOUT:\n\n"
                            exit-code)))))
      (gptel-agent--truncate-buffer "glob")
      (buffer-string))))

;;;; Grep Tool — git grep with -e flag

(defun gptel-agent-harness-tools--grep (regex path &optional glob context-lines)
  "Search for REGEX in file or directory at PATH.

Like the upstream `gptel-agent--grep' but passes REGEX via `-e'
flag to git-grep, which avoids misinterpretation of patterns
starting with a dash.

REGEX is a PCRE-format regular expression to search for.
PATH can be a file or directory to search in.

Optional arguments:
GLOB restricts the search to files matching the glob pattern.
CONTEXT-LINES specifies the number of lines of context to show
  around each match (0-15 inclusive, defaults to 0).

Returns a string containing matches grouped by file, with line numbers
and optional context."
  (unless (file-readable-p path)
    (error "Error: File or directory %s is not readable" path))
  (let* ((full-path (expand-file-name (substitute-in-file-name path)))
         ;; Explicitly set remote to save ourselves multiple file-remote-p
         ;; checks inside `executable-find'
         (remote (file-remote-p default-directory))
         (git-root (and (executable-find "git" remote)
                        (locate-dominating-file full-path ".git")))
         (grepper (cond
                   (git-root "git")
                   ((executable-find "rg" remote) "rg")
                   ((executable-find "grep" remote) "grep")
                   (t (error "Error: ripgrep/grep/git-grep not available, \
this tool cannot be used")))))
    (with-temp-buffer
      (let* ((default-directory (or git-root default-directory))
             (args
              (cond
               ((string= "git" grepper)
                (let* ((rel-path (file-relative-name full-path git-root))
                       (pathspecs
                        (list (if (and glob (file-directory-p full-path))
                                  (file-name-concat rel-path glob)
                                rel-path))))
                  (delq nil
                        (nconc
                         (list "grep"
                               "--line-number"
                               "--no-color"
                               (and (natnump context-lines)
                                    (format "-C%d" context-lines))
                               "--max-count=1000"
                               "--untracked"
                               "-P" "-e" regex
                               "--")
                         pathspecs))))
               ((string= "rg" grepper)
                (delq nil (list "--sort=modified"
                                (and (natnump context-lines)
                                     (format "--context=%d" context-lines))
                                (and glob (format "--glob=%s" glob))
                                "--max-count=1000"
                                "--heading" "--line-number" "-e" regex
                                (file-local-name full-path))))
               ((string= "grep" grepper)
                (delq nil (list "--recursive"
                                (and (natnump context-lines)
                                     (format "--context=%d" context-lines))
                                (and glob (format "--include=%s" glob))
                                "--max-count=1000"
                                "--line-number" "--regexp" regex
                                (file-local-name full-path))))))
             (exit-code (apply #'process-file grepper nil '(t t) nil args)))
        (when (>= exit-code 2)
          (goto-char (point-min))
          (insert (format "Error: search failed with exit-code %d.  Tool output:\n\n"
                          exit-code)))
        (gptel-agent--truncate-buffer "grep")
        (buffer-string)))))

;;;; Question Tool — interactive user prompting

(defconst gptel-agent-harness-tools--custom-option
  "[Type your own answer]"
  "Label for the free-text option appended to choices.")

(defvar gptel-agent-harness-tools--question-tool nil
  "The registered Question tool object.")

(defun gptel-agent-harness-tools--ask-one (question options multiple custom)
  "Ask the user QUESTION with OPTIONS.

OPTIONS is a vector of label strings (or nil for free-text only).
If MULTIPLE is non-nil, allow selecting more than one option.
If CUSTOM is non-nil, append a free-text option to the choices.

Returns a list of selected label strings."
  (let* ((choices (when options
                    (append options nil)))  ; vector -> list
         (choices (if (and choices custom)
                      (append choices
                              (list gptel-agent-harness-tools--custom-option))
                    choices))
         (prompt (concat question " "))
         result)
    (cond
     ;; No options at all — just read a string
     ((null choices)
      (setq result (list (read-string prompt))))
     ;; Multiple selection
     (multiple
      (let ((selected (completing-read-multiple prompt choices nil t)))
        (setq result
              (mapcar
               (lambda (sel)
                 (if (string= sel gptel-agent-harness-tools--custom-option)
                     (read-string (format "%s (your answer): " question))
                   sel))
               selected))))
     ;; Single selection
     (t
      (let ((selected (completing-read prompt choices nil t)))
        (setq result
              (list
               (if (string= selected gptel-agent-harness-tools--custom-option)
                   (read-string (format "%s (your answer): " question))
                 selected))))))
    result))

(defun gptel-agent-harness-tools--ask-questions (questions)
  "Process QUESTIONS and return formatted answers string.

QUESTIONS is a JSON-decoded vector of question objects.  Each object
is a plist with keys:
  :question  - The question text (string, required)
  :options   - Vector of option labels (optional)
  :multiple  - Whether multi-select is allowed (boolean, optional)
  :custom    - Whether free-text is allowed (boolean, default t)"
  (let ((results nil)
        (questions-list (if (vectorp questions)
                            (append questions nil)
                          questions)))
    (dolist (q questions-list)
      (let* ((text (plist-get q :question))
             (options (plist-get q :options))
             (multiple (eq (plist-get q :multiple) t))
             (custom (let ((c (plist-get q :custom)))
                       (if (eq c :json-false) nil t)))  ; default to t
             (answers (gptel-agent-harness-tools--ask-one
                       text options multiple custom)))
        (push (cons text answers) results)))
    ;; Format output
    (mapconcat
     (lambda (pair)
       (format "\"%s\" = \"%s\""
               (car pair)
               (if (cdr pair)
                   (mapconcat #'identity (cdr pair) ", ")
                 "Unanswered")))
     (nreverse results)
     "\n")))

(defun gptel-agent-harness-tools--register-question ()
  "Register the Question tool with gptel."
  (unless gptel-agent-harness-tools--question-tool
    (setq gptel-agent-harness-tools--question-tool
          (gptel-make-tool
           :name "Question"
           :function #'gptel-agent-harness-tools--ask-questions
           :description
           "Ask the user one or more questions during execution.

Use this tool when you need to:
1. Gather user preferences or requirements
2. Clarify ambiguous instructions
3. Get decisions on implementation choices as you work
4. Offer choices to the user about what direction to take

Each question can have predefined options for the user to select from.
By default, a \"Type your own answer\" option is added; set `custom` to
false to disable it.  Set `multiple` to true to allow selecting more
than one option.

If no options are provided, the user will be prompted for free-text input.

If you recommend a specific option, make that the first option in the
list and add \"(Recommended)\" at the end of the label.

Returns the user's answers as quoted key-value pairs, one per line."
           :args '((:name "questions"
                    :type array
                    :description "Array of question objects to ask the user."
                    :items
                    (:type object
                     :properties
                     (:question
                      (:type string
                       :description "The question to ask the user.")
                      :options
                      (:type array
                       :description "Predefined options for the user to choose from. If omitted, user provides free-text."
                       :items (:type string))
                      :multiple
                      (:type boolean
                       :description "If true, the user can select multiple options. Default: false.")
                      :custom
                      (:type boolean
                       :description "If true (default), a free-text option is appended to the choices. Set to false to restrict to only the provided options."))
                     :required ["question"])))
           :category "gptel-agent"
           :confirm nil
           :include t))))

(defun gptel-agent-harness-tools--unregister-question ()
  "Unregister the Question tool from gptel."
  (when gptel-agent-harness-tools--question-tool
    (let* ((tool gptel-agent-harness-tools--question-tool)
           (category (or (gptel-tool-category tool) "misc"))
           (name (gptel-tool-name tool))
           (cat-entry (assoc category gptel--known-tools #'equal)))
      (when cat-entry
        (setf (alist-get name (cdr cat-entry) nil 'remove #'equal) nil)
        (unless (cdr cat-entry)
          (setq gptel--known-tools
                (assoc-delete-all category gptel--known-tools #'equal)))))
    (setq gptel-agent-harness-tools--question-tool nil)))

;;;; PlanExit Tool — request approval to leave plan mode

;; Forward declarations — defined in gptel-agent-harness-supervisor.el
;; and gptel-agent-harness-fsm-helpers.el, which are loaded before this
;; file via gptel-agent-harness.el.  All are resolved at call time.
(declare-function gptel-agent-harness-set-mode "gptel-agent-harness-supervisor" (mode))
(defvar gptel-agent-harness--mode)
(defvar gptel-agent-harness--pending-prompts)
(defvar gptel-agent-harness--plan-file)

(defcustom gptel-agent-harness-tools-plan-exit-approved-message
  "The plan at %s has been approved, you can now edit files. Execute the plan"
  "User message injected after the build-switch prompt when PlanExit is approved.

Queued as a second user prompt (following the build-switch prompt) so
that, on approval, the agent both learns it is now in build mode and is
told to execute the approved plan — mirroring OpenCode's synthetic
approval message.  The %s placeholder is replaced with the plan file
path (or a generic description when the path is unknown)."
  :type 'string
  :group 'gptel-agent-harness)

(defvar gptel-agent-harness-tools--plan-exit-tool nil
  "The registered PlanExit tool object.")

(defun gptel-agent-harness-tools--plan-exit-approved-p (prompt)
  "Ask the user PROMPT (a yes/no question); return non-nil on approval.
Uses `yes-or-no-p' in batch mode and a `read-multiple-choice' prompt
interactively."
  (if noninteractive
      (yes-or-no-p (concat prompt " "))
    (eq ?y (car (read-multiple-choice
                 prompt
                 '((?y "yes, switch to build")
                   (?n "no, stay in plan")))))))

(defun gptel-agent-harness-tools--plan-exit ()
  "Request user approval to leave plan mode and switch to build mode.

Runs in the session buffer (see `gptel--handle-tool-use'), so it reads
and mutates the buffer-local agent mode directly.

When the buffer is not in plan mode, this is a no-op.  Otherwise the
user is prompted (the prompt names the plan file); on approval,
`gptel-agent-harness-set-mode' switches the buffer to build mode — which
queues the build-switch prompt — and this then appends
`gptel-agent-harness-tools-plan-exit-approved-message' as a second
queued user prompt so the agent both enters build mode and is told to
execute the plan.  A message is returned telling the agent to proceed
with implementation.  On rejection, the buffer stays in plan mode and
the agent is told to keep planning."
  (if (not (and (boundp 'gptel-agent-harness--mode)
                (eq gptel-agent-harness--mode 'plan)))
      "Not in plan mode; PlanExit has no effect.  Continue as normal."
    (let* ((plan (and (boundp 'gptel-agent-harness--plan-file)
                      gptel-agent-harness--plan-file))
           (plan-desc (if plan (abbreviate-file-name plan) "the plan file")))
      (if (gptel-agent-harness-tools--plan-exit-approved-p
           (format "Plan at %s is complete.  Switch to build agent and start implementing?"
                   plan-desc))
          (progn
            ;; Queues the build-switch prompt into `--pending-prompts'.
            (gptel-agent-harness-set-mode 'build)
            ;; Append OpenCode's "execute the plan" message as a second
            ;; user prompt, injected right after the build-switch prompt.
            (setq gptel-agent-harness--pending-prompts
                  (append gptel-agent-harness--pending-prompts
                          (list (format
                                 gptel-agent-harness-tools-plan-exit-approved-message
                                 plan-desc))))
            "User approved switching to build agent.  You are now in build mode; \
proceed to execute the approved plan.")
        "User rejected switching to build.  Remain in plan mode: keep planning \
and refining the plan file, and do NOT edit any other files."))))

(defun gptel-agent-harness-tools--register-plan-exit ()
  "Register the PlanExit tool with gptel."
  (unless gptel-agent-harness-tools--plan-exit-tool
    (setq gptel-agent-harness-tools--plan-exit-tool
          (gptel-make-tool
           :name "PlanExit"
           :function #'gptel-agent-harness-tools--plan-exit
           :description
           "Use this tool when you have completed the planning phase and are
ready to exit plan mode.

This tool will ask the user whether they want to switch to the build
agent and start implementing the plan.  Do NOT use the Question tool to
ask \"Is this plan okay?\" — that is what this tool is for.

Call this tool:
- After you have written a complete plan to the plan file
- After you have clarified any questions with the user
- When you are confident the plan is ready for implementation

Do NOT call this tool:
- Before you have created or finalized the plan
- If you still have unanswered questions about the implementation
- If the user has indicated they want to continue planning

On approval, the session switches to build mode (file edits become
allowed) and you should proceed to execute the approved plan.  On
rejection, you remain in the read-only plan phase and should continue
refining the plan."
           :args nil
           :category "gptel-agent"
           :confirm nil
           :include t))))

(defun gptel-agent-harness-tools--unregister-plan-exit ()
  "Unregister the PlanExit tool from gptel."
  (when gptel-agent-harness-tools--plan-exit-tool
    (let* ((tool gptel-agent-harness-tools--plan-exit-tool)
           (category (or (gptel-tool-category tool) "misc"))
           (name (gptel-tool-name tool))
           (cat-entry (assoc category gptel--known-tools #'equal)))
      (when cat-entry
        (setf (alist-get name (cdr cat-entry) nil 'remove #'equal) nil)
        (unless (cdr cat-entry)
          (setq gptel--known-tools
                (assoc-delete-all category gptel--known-tools #'equal)))))
    (setq gptel-agent-harness-tools--plan-exit-tool nil)))

;;;; Activation / Deactivation (called by gptel-agent-harness-mode)

(defun gptel-agent-harness-tools-enable ()
  "Override `gptel-agent--glob' and `gptel-agent--grep' with improved versions.
Also register additional tools (Question, PlanExit).

The overrides are installed as `:override' advice, so no copy of the
original definition is needed: `advice-remove' in
`gptel-agent-harness-tools-disable' restores it.  Both calls are
idempotent — `advice-add' does not install the same function twice."
  (when (fboundp 'gptel-agent--glob)
    (advice-add 'gptel-agent--glob :override #'gptel-agent-harness-tools--glob))
  (when (fboundp 'gptel-agent--grep)
    (advice-add 'gptel-agent--grep :override #'gptel-agent-harness-tools--grep))
  (gptel-agent-harness-tools--register-question)
  (gptel-agent-harness-tools--register-plan-exit))

(defun gptel-agent-harness-tools-disable ()
  "Restore original `gptel-agent--glob' and `gptel-agent--grep'.
Also unregister additional tools (Question, PlanExit)."
  (advice-remove 'gptel-agent--glob #'gptel-agent-harness-tools--glob)
  (advice-remove 'gptel-agent--grep #'gptel-agent-harness-tools--grep)
  (gptel-agent-harness-tools--unregister-question)
  (gptel-agent-harness-tools--unregister-plan-exit))

(provide 'gptel-agent-harness-tools)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-tools.el ends here
