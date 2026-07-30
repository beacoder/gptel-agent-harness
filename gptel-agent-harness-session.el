;;; gptel-agent-harness-session.el --- Session management for gptel-agent-harness -*- lexical-binding: t; package-lint-main-file: "gptel-agent-harness.el" -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
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
;; Session management for gptel-agent-harness:
;;
;; - Auto-save gptel agent buffers after each LLM response
;; - Generate meaningful titles for sessions via LLM
;; - Restore sessions with live preview during file selection
;;
;; Activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-session)
;;
;;; Code:

(require 'gptel)
(require 'gptel-agent)
(require 'cl-lib)

;; Defined in gptel-agent-harness.el, loaded after this file.
(defvar gptel-agent-harness-verbose)

;; Defined in gptel-request.el (loaded transitively via gptel).
(defvar gptel--known-backends)

;;;; User Options

(defcustom gptel-agent-harness-session-dir
  (expand-file-name "gptel-sessions/" user-emacs-directory)
  "Directory where gptel agent sessions are auto-saved."
  :type 'directory
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-auto-save-session t
  "When non-nil, auto-save gptel agent buffers after each LLM response."
  :type 'boolean
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-preview-lines 40
  "Number of lines to show in session preview buffer.
Set to 0 or nil to show the entire file."
  :type '(choice integer (const nil))
  :group 'gptel-agent-harness)

;;;; Internal State

(defvar-local gptel-agent-harness--project-dir nil
  "Project directory associated with this gptel agent buffer.
Used for session restore to set `default-directory'.")

;; Declare variables safe-local-variable so session restore can set them.
(dolist (entry '((gptel-agent-harness--project-dir . stringp)
                 (gptel-model                      . always)
                 (gptel--backend-name              . stringp)
                 (gptel-system-prompt              . stringp)
                 (gptel-temperature                . numberp)
                 (gptel-max-tokens                 . integerp)
                 (gptel--num-messages-to-send      . integerp)
                 (gptel--tool-names                . listp)))
  (put (car entry) 'safe-local-variable (cdr entry)))

(defvar-local gptel-agent-harness--session-file-cache nil
  "Cached session file path for this buffer.
Set once on first auto-save, reused for subsequent saves.")

(defvar-local gptel-agent-harness--session-title nil
  "Generated title for this session, or nil if not yet generated.")

(defvar-local gptel-agent-harness--session-title-pending nil
  "Non-nil when a title generation request is in flight.")

;;;; Title Generation

(defconst gptel-agent-harness--title-prompt-file
  (expand-file-name
   "prompts/title.txt"
   (file-name-directory (or (locate-library "gptel-agent-harness")
                            (error "Gptel-agent-harness not found"))))
  "File path for the session title generation prompt.")

(defun gptel-agent-harness--read-title-prompt ()
  "Read the title prompt from `gptel-agent-harness--title-prompt-file'."
  (if (file-exists-p gptel-agent-harness--title-prompt-file)
      (with-temp-buffer
        (insert-file-contents gptel-agent-harness--title-prompt-file)
        (buffer-string))
    (error "Title prompt file not found: %s"
           gptel-agent-harness--title-prompt-file)))

(defun gptel-agent-harness--sanitize-title (title)
  "Sanitize TITLE for use as a filename component.
Removes/replaces characters unsafe for filesystems."
  (let ((clean (string-trim title)))
    ;; Replace newlines/carriage returns with space
    (setq clean (replace-regexp-in-string "[\n\r]+" " " clean))
    ;; Remove quotes if the LLM wraps the title
    (when (and (string-prefix-p "\"" clean) (string-suffix-p "\"" clean))
      (setq clean (substring clean 1 -1)))
    ;; Replace filesystem-unsafe chars with hyphen
    (setq clean (replace-regexp-in-string "[/\\\\:*?\"<>|]" "-" clean))
    ;; Collapse multiple hyphens/spaces
    (setq clean (replace-regexp-in-string "[-_ ]+" "-" clean))
    ;; Trim to 50 chars
    (when (> (length clean) 50)
      (setq clean (substring clean 0 50)))
    ;; Remove trailing hyphens
    (setq clean (replace-regexp-in-string "-+\\'" "" clean))
    clean))

(defun gptel-agent-harness--generate-session-title ()
  "Asynchronously generate a title for the current session.
Uses the first user message as input to the title LLM prompt.
On success, renames the session file to include the title."
  (when (and gptel-agent-harness--session-file-cache
             (not gptel-agent-harness--session-title)
             (not gptel-agent-harness--session-title-pending))
    (let* ((buf (current-buffer))
           ;; Extract the first user message from buffer
           (first-msg (save-excursion
                        (goto-char (point-min))
                        (when-let* ((props (text-property-search-forward
                                            'gptel 'response t))
                                    (resp-start (prop-match-beginning props)))
                          ;; Text before first response is the user's first message
                          (string-trim
                           (buffer-substring-no-properties (point-min) resp-start))))))
      (when (and first-msg (not (string-empty-p first-msg))
                 ;; Limit input to avoid sending too much
                 (> (length first-msg) 3))
        (setq gptel-agent-harness--session-title-pending t)
        (gptel-request
         (if (> (length first-msg) 500)
             (substring first-msg 0 500)
           first-msg)
         :system (gptel-agent-harness--read-title-prompt)
         :buffer buf
         :stream nil
         :callback
         (lambda (response _info)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq gptel-agent-harness--session-title-pending nil)
               (when (and (stringp response)
                          (not (string-empty-p response))
                          gptel-agent-harness--session-file-cache)
                 (let* ((title (gptel-agent-harness--sanitize-title response))
                        (old-file gptel-agent-harness--session-file-cache)
                        (dir (file-name-directory old-file))
                        (timestamp (format-time-string "%y%m%d%H%M%S"))
                        (new-name (format "%s_%s.md" title timestamp))
                        (new-file (expand-file-name new-name dir)))
                   (when (and (not (string-empty-p title))
                              (file-exists-p old-file))
                     (rename-file old-file new-file t)
                     (setq gptel-agent-harness--session-file-cache new-file)
                     (setq gptel-agent-harness--session-title title)
                     ;; Update buffer name to reflect the title
                     (let* ((display-title (replace-regexp-in-string "-" " " title))
                            (max-len 20)
                            (short (if (> (length display-title) max-len)
                                       (concat (substring display-title 0 (- max-len 1)) "…")
                                     display-title))
                            (new-buf-name (format "*%s*" short)))
                       (rename-buffer new-buf-name t))
                     (when gptel-agent-harness-verbose
                       (message "gptel-agent-harness: session titled — %s"
                                title)))))))))))))

;;;; Session File Management

(defun gptel-agent-harness--session-file (&optional buffer)
  "Return the session file path for BUFFER (default: current buffer).
Returns the cached path if available, otherwise generates a new one.
Returns nil if the buffer is not a gptel agent buffer."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when gptel-mode
          (or gptel-agent-harness--session-file-cache
              (let* ((proj-dir (or gptel-agent-harness--project-dir
                                   default-directory))
                     (proj-name (file-name-nondirectory
                                 (directory-file-name proj-dir)))
                     (timestamp (format-time-string "%y%m%d%H%M%S"))
                     (file-name (format "%s_%s.md" proj-name timestamp)))
                (setq gptel-agent-harness--session-file-cache
                      (expand-file-name file-name
                                        gptel-agent-harness-session-dir)))))))))

(defun gptel-agent-harness--write-local-vars (vars)
  "Insert a ;; Local Variables: block for VARS at point.
VARS is an alist of (VAR-NAME-STRING . VALUE).
Entries with nil values are skipped."
  (insert "\n;; Local Variables:\n")
  (pcase-dolist (`(,name . ,val) vars)
    (when val
      (insert (format ";; %s: %S\n" name val))))
  (insert ";; End:\n"))

;;;; Auto-Save

(defun gptel-agent-harness--auto-save-session (&rest _)
  "Auto-save the current gptel agent buffer to session dir.
Intended as a hook function for `gptel-post-response-functions'."
  (when (and gptel-mode
             gptel-agent-harness-auto-save-session)
    (unless (file-exists-p gptel-agent-harness-session-dir)
      (make-directory gptel-agent-harness-session-dir t))
    (when-let* ((file (gptel-agent-harness--session-file)))
      (with-temp-message "gptel-agent-harness: auto-saving session..."
        (let* ((source-buf (current-buffer))
               (proj-dir (or gptel-agent-harness--project-dir
                             default-directory))
               (backend-name (or (and (boundp 'gptel--backend-name) gptel--backend-name)
                                 (when (and (boundp 'gptel-backend) gptel-backend)
                                   (gptel-backend-name gptel-backend))))
               (vars `(("gptel-agent-harness--project-dir" . ,proj-dir)
                       ("gptel-model"                      . ,gptel-model)
                       ("gptel--backend-name"              . ,backend-name)
                       ("gptel--preset"                    . ,gptel--preset)
                       ("gptel-system-prompt"              . ,gptel-system-prompt)
                       ("gptel--tool-names"                . ,(mapcar #'gptel-tool-name gptel-tools))
                       ("gptel-temperature"                . ,gptel-temperature)
                       ("gptel-max-tokens"                 . ,gptel-max-tokens)
                       ("gptel--num-messages-to-send"      . ,(and (natnump gptel--num-messages-to-send)
                                                                    gptel--num-messages-to-send)))))
          (with-temp-buffer
            (insert-buffer-substring source-buf)
            (goto-char (point-max))
            (let ((print-escape-newlines t))
              (gptel-agent-harness--write-local-vars vars))
            (write-region (point-min) (point-max) file nil 'silent))))
      ;; Generate a meaningful title on first save
      (unless gptel-agent-harness--session-title
        (gptel-agent-harness--generate-session-title)))))

;;;; Session Preview

(defun gptel-agent-harness--preview-session (file)
  "Display a preview of session FILE in a side window.
Shows metadata and the first `gptel-agent-harness-preview-lines' lines.
Returns the preview buffer."
  (let ((buf (get-buffer-create "*gptel-session-preview*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file)
        ;; Parse local variables for metadata display
        (goto-char (point-min))
        (let (metadata)
          (when (search-forward "\n;; Local Variables:" nil t)
            (let ((start (match-beginning 0)))
              (forward-line 1)
              (while (looking-at ";; \\([^:]+\\): \\(.*\\)")
                (let ((name (string-trim (match-string 1)))
                      (val (match-string 2)))
                  (push (cons name val) metadata))
                (forward-line 1))
              ;; Remove local vars block from preview
              (delete-region start (point-max))))
          ;; Truncate if needed
          (when (and gptel-agent-harness-preview-lines
                     (> gptel-agent-harness-preview-lines 0))
            (goto-char (point-min))
            (when (> (count-lines (point-min) (point-max))
                     gptel-agent-harness-preview-lines)
              (forward-line gptel-agent-harness-preview-lines)
              (delete-region (point) (point-max))
              (insert "\n\n[... truncated ...]\n")))
          ;; Insert metadata header at top
          (goto-char (point-min))
          (let ((header (concat
                         (propertize "── Session Preview ──" 'face 'bold)
                         "\n"
                         (propertize (format "File: %s" (abbreviate-file-name file))
                                     'face 'font-lock-comment-face)
                         "\n"
                         (when-let* ((model (cdr (assoc "gptel-model" metadata))))
                           (format "Model: %s\n" model))
                         (when-let* ((proj (cdr (assoc "gptel-agent-harness--project-dir" metadata))))
                           (format "Project: %s\n" proj))
                         (when-let* ((backend (cdr (assoc "gptel--backend-name" metadata))))
                           (format "Backend: %s\n" backend))
                         (propertize "────────────────────" 'face 'bold)
                         "\n\n")))
            (insert header))))
      (goto-char (point-min))
      (unless (derived-mode-p 'markdown-mode)
        (when (fboundp 'markdown-mode) (markdown-mode)))
      (setq buffer-read-only t)
      (set-buffer-modified-p nil))
    (display-buffer buf
                    '((display-buffer-in-side-window
                       display-buffer-pop-up-window)
                      (side . right)
                      (window-width . 0.5)))
    buf))

(defun gptel-agent-harness--dismiss-preview ()
  "Kill the session preview buffer and its window if present."
  (when-let* ((buf (get-buffer "*gptel-session-preview*")))
    (when-let* ((win (get-buffer-window buf t)))
      (unless (eq win (frame-root-window (window-frame win)))
        (delete-window win)))
    (kill-buffer buf)))

(defvar gptel-agent-harness--preview-candidate nil
  "Current candidate being previewed during session selection.")

(defun gptel-agent-harness--preview-candidate-at-point ()
  "Preview the currently selected session file candidate.
Intended for use in `post-command-hook' inside the minibuffer."
  (condition-case nil
      (when-let* ((cand (or (and (bound-and-true-p vertico--index)
                                 (bound-and-true-p vertico--candidates)
                                 (listp vertico--candidates)
                                 (>= vertico--index 0)
                                 (< vertico--index (length vertico--candidates))
                                 (nth vertico--index vertico--candidates))
                            (and (bound-and-true-p ivy--current)
                                 ivy--current)
                            ;; Default completion: grab minibuffer content
                            (let ((content (minibuffer-contents)))
                              (when (> (length content) 0)
                                content)))))
        ;; Expand relative to minibuffer's default-directory
        (let ((full-path (expand-file-name cand)))
          (when (and (file-regular-p full-path)
                     (not (equal full-path gptel-agent-harness--preview-candidate)))
            (setq gptel-agent-harness--preview-candidate full-path)
            (gptel-agent-harness--preview-session full-path))))
    (error nil)))

(defun gptel-agent-harness--setup-preview-hook ()
  "Set up live preview in the minibuffer for session selection."
  (setq gptel-agent-harness--preview-candidate nil)
  (add-hook 'post-command-hook
            #'gptel-agent-harness--preview-candidate-at-point nil t))

(defun gptel-agent-harness--read-session-file ()
  "Read a session file with live preview in a side window.
Returns the selected file path."
  (let ((gptel-agent-harness--preview-candidate nil))
    (unwind-protect
        (progn
          (minibuffer-with-setup-hook
              #'gptel-agent-harness--setup-preview-hook
            (read-file-name "Session file: "
                           gptel-agent-harness-session-dir
                           nil t)))
      (gptel-agent-harness--dismiss-preview))))

;;;; Session Restore

(defun gptel-agent-harness--title-from-filename (session-file)
  "Extract the title portion from SESSION-FILE name.
Expects format \"Title-Here_YYMMDDHHMMSS.md\" or \"project_YYMMDDHHMMSS.md\".
Returns the title with hyphens replaced by spaces, or nil if no
meaningful title is found."
  (let ((basename (file-name-sans-extension
                   (file-name-nondirectory session-file))))
    ;; Strip the _YYMMDDHHMMSS timestamp suffix
    (when (string-match "\\(.+\\)_[0-9]\\{12\\}\\'" basename)
      (let ((title (replace-regexp-in-string "-" " " (match-string 1 basename))))
        ;; Only return if it's not just a bare project name (single word)
        (when (string-match-p " " title)
          title)))))

(defun gptel-agent-harness-restore-session (session-file)
  "Restore a gptel agent session from SESSION-FILE.
The file should have been created by
`gptel-agent-harness--auto-save-session'.
During file selection, a live preview is shown in a side window
as you navigate candidates.
This opens the file, enables `gptel-mode', and restores all state."
  (interactive
   (list (gptel-agent-harness--read-session-file)))
  (let* ((title (gptel-agent-harness--title-from-filename session-file))
         (buf-name (if title
                       ;; Keep buffer name short (~20 chars) to leave
                       ;; room for mode-line context ratio indicator
                       (let* ((max-len 20)
                              (display (if (> (length title) max-len)
                                           (concat (substring title 0 (- max-len 1)) "…")
                                         title)))
                         (format "*%s*" display))
                     (file-name-nondirectory session-file)))
         (buf (generate-new-buffer buf-name)))
    (switch-to-buffer buf)
    (insert-file-contents session-file)
    (setq major-mode 'markdown-mode)
    (when (fboundp 'markdown-mode) (markdown-mode))
    ;; Manually parse and apply local variables, then strip the block
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "\n;; Local Variables:" nil t)
        (let ((start (match-beginning 0)))
          (forward-line 1)
          (while (looking-at ";; \\([^:]+\\): \\(.*\\)")
            (let* ((var-name (string-trim (match-string 1)))
                   (val-str (match-string 2))
                   (var-sym (intern var-name)))
              (when (get var-sym 'safe-local-variable)
                (set (make-local-variable var-sym)
                     (car (read-from-string val-str)))))
            (forward-line 1))
          (delete-region start (point-max)))))
    (gptel-agent-update)
    (gptel-mode 1)
    ;; gptel-mode's built-in restore only fires for file-visiting buffers.
    ;; Since session buffers are not file-visiting, manually restore state.
    (when gptel--preset
      (when (gptel-get-preset gptel--preset)
        (gptel--apply-preset
         gptel--preset (lambda (sym val) (set (make-local-variable sym) val)))))
    (when gptel--backend-name
      (when-let* ((backend (alist-get
                            gptel--backend-name gptel--known-backends
                            nil nil #'equal)))
        (setq-local gptel-backend backend)))
    ;; Restore tools from saved tool names when no preset handles it
    (when (and (bound-and-true-p gptel--tool-names) (not gptel--preset))
      (when-let* ((tools (cl-loop for tname in gptel--tool-names
                                   for tool = (with-demoted-errors
                                                  "gptel-agent-harness: %S"
                                                (gptel-get-tool tname))
                                   if tool collect tool)))
        (setq-local gptel-tools tools)
        (setq-local gptel-use-tools t)))
    (when gptel-agent-harness--project-dir
      (setq default-directory gptel-agent-harness--project-dir))
    ;; Restore title and session file cache for subsequent saves
    (when title
      (setq gptel-agent-harness--session-title title))
    (setq gptel-agent-harness--session-file-cache session-file)
    (set-buffer-modified-p nil)
    (message "gptel-agent-harness: session restored from %s" session-file)))

(defun gptel-agent-harness-restore-latest-session ()
  "Restore the most recently modified gptel agent session.
Looks in `gptel-agent-harness-session-dir' for the newest .md file."
  (interactive)
  (if (file-directory-p gptel-agent-harness-session-dir)
      (let* ((files (directory-files gptel-agent-harness-session-dir
                                     t "\\.md\\'"))
             (latest (car (sort files #'file-newer-than-file-p))))
        (if latest
            (gptel-agent-harness-restore-session latest)
          (message "No gptel agent sessions found in %s"
                   gptel-agent-harness-session-dir)))
    (message "Session directory %s does not exist"
             gptel-agent-harness-session-dir)))

;;;; Setup / Teardown (called by gptel-agent-harness-mode)

(defun gptel-agent-harness--setup-session ()
  "Set up session auto-save for the current gptel buffer.
Adds hook to `gptel-post-response-functions' buffer-locally."
  (when gptel-agent-harness-auto-save-session
    (add-hook 'gptel-post-response-functions
              #'gptel-agent-harness--auto-save-session
              nil t)))

(defun gptel-agent-harness--teardown-session ()
  "Remove session auto-save from the current gptel buffer."
  (remove-hook 'gptel-post-response-functions
               #'gptel-agent-harness--auto-save-session
               t))

(provide 'gptel-agent-harness-session)
;;; gptel-agent-harness-session.el ends here
