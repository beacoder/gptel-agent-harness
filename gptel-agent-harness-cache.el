;;; gptel-agent-harness-cache.el --- Tool result caching for gptel-agent-harness -*- lexical-binding: t -*-
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
;; Tool result caching with deduplication for gptel-agent-harness.
;;
;; Caches results from Glob, Grep, and Read tool calls.  When the same
;; tool call is repeated within a single compaction epoch, returns a
;; short deduplication message instead of the full result, saving tokens.
;;
;; Cache entries are invalidated by:
;; - File mtime changes (for file-based lookups)
;; - TTL expiry (for directory-based lookups)
;; - Explicit invalidation on Write/Edit/Insert operations
;;
;; The "seen" set (tracking which results are already in conversation)
;; is cleared on context compaction, so the LLM gets full results again
;; in the new epoch.
;;
;; Activated/deactivated by `gptel-agent-harness-mode' in
;; gptel-agent-harness.el.  No separate mode is needed.
;;
;; Usage:
;;   (require 'gptel-agent-harness-cache)
;;   (gptel-agent-harness-cache-enable)
;;
;;; Code:

(require 'cl-lib)

;; Forward declarations — defined in gptel-agent-harness.el
(defvar gptel-agent-harness-verbose)

;;;; User Options

(defcustom gptel-agent-harness-cache-enabled t
  "When non-nil, cache Glob/Grep/Read tool results and deduplicate repeats."
  :type 'boolean
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-cache-ttl 60
  "Time-to-live in seconds for directory-based cache entries.
File-based entries use mtime invalidation instead of TTL."
  :type 'integer
  :group 'gptel-agent-harness)

(defcustom gptel-agent-harness-cache-max-entries 200
  "Maximum number of cached tool results per session.
When exceeded, oldest entries are evicted."
  :type 'integer
  :group 'gptel-agent-harness)

;;;; Internal State

(defvar-local gptel-agent-harness-cache--table nil
  "Buffer-local cache: key → (:result STRING :mtime TIME :timestamp FLOAT).
Persists across compaction epochs for latency benefit.")

(defvar-local gptel-agent-harness-cache--seen nil
  "Buffer-local set of cache keys whose full results are already in conversation.
Cleared on compaction so the LLM gets full results in the new epoch.")

(defvar-local gptel-agent-harness-cache--stats nil
  "Buffer-local cache statistics for diagnostics.
Keys: :hits :misses :dedups :invalidations.
Initialized on first access via `gptel-agent-harness-cache--ensure-stats'.")

(defun gptel-agent-harness-cache--ensure-stats ()
  "Ensure statistics hash table exists for the current buffer."
  (unless gptel-agent-harness-cache--stats
    (setq gptel-agent-harness-cache--stats
          (make-hash-table :test 'eq :size 4))
    (dolist (key '(:hits :misses :dedups :invalidations))
      (puthash key 0 gptel-agent-harness-cache--stats))))

(defun gptel-agent-harness-cache--inc-stat (key)
  "Increment statistic KEY by 1."
  (gptel-agent-harness-cache--ensure-stats)
  (puthash key (1+ (gethash key gptel-agent-harness-cache--stats 0))
           gptel-agent-harness-cache--stats))

;;;; Hash Table Management

(defun gptel-agent-harness-cache--ensure-tables ()
  "Ensure cache, seen, and stats tables exist for the current buffer."
  (unless gptel-agent-harness-cache--table
    (setq gptel-agent-harness-cache--table
          (make-hash-table :test 'equal :size 64)))
  (unless gptel-agent-harness-cache--seen
    (setq gptel-agent-harness-cache--seen
          (make-hash-table :test 'equal :size 64)))
  (gptel-agent-harness-cache--ensure-stats))

;;;; Cache Key Construction

(defun gptel-agent-harness-cache--make-key (func-name args)
  "Generate cache key from FUNC-NAME symbol and ARGS list.
Canonicalizes file paths for consistent cache hits."
  (cons func-name
        (mapcar (lambda (arg)
                  (if (and (stringp arg)
                           (not (string-empty-p arg))
                           (or (file-name-absolute-p arg)
                               (string-prefix-p "." arg)
                               (string-prefix-p "~" arg)))
                      (expand-file-name arg)
                    arg))
                args)))

;;;; Invalidation Checks

(defun gptel-agent-harness-cache--file-mtime (path)
  "Return modification time of PATH, or nil if inaccessible."
  (when (and (stringp path) (file-exists-p path))
    (file-attribute-modification-time (file-attributes path))))

(defun gptel-agent-harness-cache--valid-p (entry path)
  "Check if cache ENTRY is still valid for PATH.
Uses mtime for regular files, TTL for directories.
Returns nil if PATH was expected to be a file but no longer exists."
  (cond
   ;; Regular file: compare mtime
   ((and (stringp path) (file-regular-p path))
    (let ((cached-mtime (plist-get entry :mtime))
          (current-mtime (gptel-agent-harness-cache--file-mtime path)))
      (and cached-mtime current-mtime
           (time-equal-p cached-mtime current-mtime))))
   ;; Path was a file (has mtime in cache) but no longer exists: invalid
   ((and (stringp path) (plist-get entry :mtime) (not (file-exists-p path)))
    nil)
   ;; Directory or non-file: use TTL
   (t
    (let ((timestamp (plist-get entry :timestamp)))
      (and timestamp
           (< (- (float-time) timestamp)
              gptel-agent-harness-cache-ttl))))))

;;;; Eviction

(defun gptel-agent-harness-cache--evict-oldest ()
  "Evict the oldest cache entry by timestamp."
  (when (and gptel-agent-harness-cache--table
             (> (hash-table-count gptel-agent-harness-cache--table) 0))
    (let ((oldest-key nil)
          (oldest-time most-positive-fixnum))
      (maphash (lambda (key entry)
                 (let ((ts (plist-get entry :timestamp)))
                   (when (and ts (< ts oldest-time))
                     (setq oldest-time ts
                           oldest-key key))))
               gptel-agent-harness-cache--table)
      (when oldest-key
        (remhash oldest-key gptel-agent-harness-cache--table)))))

;;;; Core Cache Operations

(defun gptel-agent-harness-cache--lookup (key path)
  "Look up KEY in cache, validating against PATH.
Returns the cached result string, or nil if missing/stale."
  (gptel-agent-harness-cache--ensure-tables)
  (when-let* ((entry (gethash key gptel-agent-harness-cache--table)))
    (if (gptel-agent-harness-cache--valid-p entry path)
        (plist-get entry :result)
      ;; Stale — remove
      (remhash key gptel-agent-harness-cache--table)
      (gptel-agent-harness-cache--inc-stat :invalidations)
      nil)))

(defun gptel-agent-harness-cache--store (key result path)
  "Store RESULT in cache under KEY with metadata for PATH."
  (gptel-agent-harness-cache--ensure-tables)
  ;; Evict if at capacity
  (when (>= (hash-table-count gptel-agent-harness-cache--table)
            gptel-agent-harness-cache-max-entries)
    (gptel-agent-harness-cache--evict-oldest))
  (puthash key
           (list :result result
                 :mtime (gptel-agent-harness-cache--file-mtime path)
                 :timestamp (float-time))
           gptel-agent-harness-cache--table))

(defun gptel-agent-harness-cache--format-dedup (key result)
  "Format a dedup message for KEY describing the cached RESULT."
  (let* ((func-name (car key))
         (args (cdr key))
         (desc (pcase func-name
                 ('read
                  (let ((file (abbreviate-file-name (or (nth 0 args) "")))
                        (start (nth 1 args))
                        (end (nth 2 args)))
                    (if (and start end)
                        (format "Read \"%s\" lines %s-%s" file start end)
                      (format "Read \"%s\"" file))))
                 ('glob
                  (let ((pattern (nth 0 args))
                        (path (abbreviate-file-name (or (nth 1 args) "."))))
                    (format "Glob \"%s\" in %s" pattern path)))
                 ('grep
                  (let ((regex (nth 0 args))
                        (path (abbreviate-file-name (or (nth 1 args) ""))))
                    (format "Grep \"%s\" in %s" regex path)))
                 (_ (format "%s" func-name)))))
    (format "[Cached: %s (%d chars) — same as earlier call, see above]"
            desc (length result))))

(defun gptel-agent-harness-cache--get (key path)
  "Return tool result for KEY with PATH validation, deduplicating if seen.
Returns full result on first access, short message on repeats.
Returns nil on cache miss."
  (when-let* ((result (gptel-agent-harness-cache--lookup key path)))
    (gptel-agent-harness-cache--ensure-tables)
    (if (gethash key gptel-agent-harness-cache--seen)
        ;; Already in conversation this epoch — deduplicate
        (progn
          (gptel-agent-harness-cache--inc-stat :dedups)
          (when gptel-agent-harness-verbose
            (message "gptel-agent-harness-cache: dedup hit (%d chars saved)"
                     (length result)))
          (gptel-agent-harness-cache--format-dedup key result))
      ;; First time this epoch — return full, mark seen
      (puthash key t gptel-agent-harness-cache--seen)
      (gptel-agent-harness-cache--inc-stat :hits)
      result)))

;;;; Epoch Management (compaction integration)

(defun gptel-agent-harness-cache--reset-epoch ()
  "Clear the seen set for the current buffer.
Called on context compaction.  The cache table is preserved for
latency benefit — only the deduplication tracking is reset."
  (when gptel-agent-harness-cache--seen
    (clrhash gptel-agent-harness-cache--seen))
  (when gptel-agent-harness-verbose
    (message "gptel-agent-harness-cache: epoch reset (seen set cleared)")))

;;;; Advice Functions for Tool Wrapping

(defun gptel-agent-harness-cache--cacheable-p (result)
  "Return non-nil if RESULT is worth caching.
Skips empty results and error messages."
  (and (stringp result)
       (not (string-empty-p result))
       (not (string-prefix-p "Error:" result))
       (not (string-match-p "\\`.*failed with exit code" result))))

(defun gptel-agent-harness-cache--read-advice (orig-fn filename &optional start-line end-line)
  "Caching :around advice for `gptel-agent--read-file-lines'.
ORIG-FN is the original function.  FILENAME, START-LINE, END-LINE
are passed through."
  (if (not gptel-agent-harness-cache-enabled)
      (funcall orig-fn filename start-line end-line)
    (let* ((expanded (and (stringp filename) (expand-file-name filename)))
           (key (gptel-agent-harness-cache--make-key
                 'read (list expanded start-line end-line)))
           (cached (gptel-agent-harness-cache--get key expanded)))
      (or cached
          (let ((result (funcall orig-fn filename start-line end-line)))
            (when (gptel-agent-harness-cache--cacheable-p result)
              (gptel-agent-harness-cache--store key result expanded)
              (gptel-agent-harness-cache--ensure-tables)
              (puthash key t gptel-agent-harness-cache--seen))
            (gptel-agent-harness-cache--inc-stat :misses)
            result)))))

(defun gptel-agent-harness-cache--glob-advice (orig-fn pattern &optional path depth)
  "Caching :around advice for `gptel-agent--glob'.
ORIG-FN is the original function.  PATTERN, PATH, DEPTH are passed through."
  (if (not gptel-agent-harness-cache-enabled)
      (funcall orig-fn pattern path depth)
    (let* ((resolved (expand-file-name (or path ".")))
           (key (gptel-agent-harness-cache--make-key
                 'glob (list pattern resolved depth)))
           (cached (gptel-agent-harness-cache--get key resolved)))
      (or cached
          (let ((result (funcall orig-fn pattern path depth)))
            (when (gptel-agent-harness-cache--cacheable-p result)
              (gptel-agent-harness-cache--store key result resolved)
              (gptel-agent-harness-cache--ensure-tables)
              (puthash key t gptel-agent-harness-cache--seen))
            (gptel-agent-harness-cache--inc-stat :misses)
            result)))))

(defun gptel-agent-harness-cache--grep-advice (orig-fn regex path &optional glob context-lines)
  "Caching :around advice for `gptel-agent--grep'.
ORIG-FN is the original function.  REGEX, PATH, GLOB, CONTEXT-LINES
are passed through."
  (if (not gptel-agent-harness-cache-enabled)
      (funcall orig-fn regex path glob context-lines)
    (let* ((resolved (expand-file-name path))
           (key (gptel-agent-harness-cache--make-key
                 'grep (list regex resolved glob context-lines)))
           (cached (gptel-agent-harness-cache--get key resolved)))
      (or cached
          (let ((result (funcall orig-fn regex path glob context-lines)))
            (when (gptel-agent-harness-cache--cacheable-p result)
              (gptel-agent-harness-cache--store key result resolved)
              (gptel-agent-harness-cache--ensure-tables)
              (puthash key t gptel-agent-harness-cache--seen))
            (gptel-agent-harness-cache--inc-stat :misses)
            result)))))

;;;; Write-Through Invalidation

(defun gptel-agent-harness-cache--invalidate-path (path)
  "Invalidate all cache entries whose key references PATH.
Also removes affected entries from the seen set."
  (when (and gptel-agent-harness-cache--table (stringp path))
    (let ((expanded (expand-file-name path))
          (to-remove nil))
      (maphash
       (lambda (key _entry)
         ;; Key is (func-name . args-list) — check all string args
         (let ((args (cdr key)))
           (when (cl-some
                  (lambda (arg)
                    (and (stringp arg)
                         (not (string-empty-p arg))
                         (or ;; Exact file match (e.g. Read of this file)
                             (string= arg expanded)
                             ;; The edited file lies within a cached search
                             ;; directory — catches directory-based grep/glob
                             ;; entries, including any ancestor directory that
                             ;; contains the file.  `file-name-as-directory'
                             ;; normalizes ARG so the match works whether or
                             ;; not it carries a trailing slash.
                             (string-prefix-p (file-name-as-directory arg)
                                              expanded))))
                  args)
             (push key to-remove))))
       gptel-agent-harness-cache--table)
      (dolist (key to-remove)
        (remhash key gptel-agent-harness-cache--table)
        (when gptel-agent-harness-cache--seen
          (remhash key gptel-agent-harness-cache--seen))
        (gptel-agent-harness-cache--inc-stat :invalidations))
      (when (and to-remove gptel-agent-harness-verbose)
        (message "gptel-agent-harness-cache: invalidated %d entries for %s"
                 (length to-remove) (abbreviate-file-name expanded))))))

(defun gptel-agent-harness-cache--after-edit (path &rest _args)
  "Invalidation advice for `gptel-agent--edit-files'.
PATH is the file or directory that was edited."
  (when (stringp path)
    (gptel-agent-harness-cache--invalidate-path path)))

(defun gptel-agent-harness-cache--after-write (path filename &rest _args)
  "Invalidation advice for `gptel-agent--write-file'.
PATH is the directory, FILENAME is the file written."
  (when (and (stringp path) (stringp filename))
    (gptel-agent-harness-cache--invalidate-path
     (expand-file-name filename path))))

(defun gptel-agent-harness-cache--after-insert (path &rest _args)
  "Invalidation advice for `gptel-agent--insert-in-file'.
PATH is the file that was modified."
  (when (stringp path)
    (gptel-agent-harness-cache--invalidate-path path)))

;;;; Diagnostics

(defun gptel-agent-harness-cache-stats ()
  "Display cache statistics for the current buffer in the echo area."
  (interactive)
  (gptel-agent-harness-cache--ensure-stats)
  (let ((entries (if gptel-agent-harness-cache--table
                     (hash-table-count gptel-agent-harness-cache--table)
                   0))
        (seen (if gptel-agent-harness-cache--seen
                  (hash-table-count gptel-agent-harness-cache--seen)
                0)))
    (message "[Buffer %s] Cache: %d entries, %d seen | Hits: %d, Misses: %d, Dedups: %d, Invalidations: %d"
             (buffer-name)
             entries seen
             (gethash :hits gptel-agent-harness-cache--stats 0)
             (gethash :misses gptel-agent-harness-cache--stats 0)
             (gethash :dedups gptel-agent-harness-cache--stats 0)
             (gethash :invalidations gptel-agent-harness-cache--stats 0))))

(defun gptel-agent-harness-cache-clear ()
  "Clear all cache state for the current buffer."
  (interactive)
  (when gptel-agent-harness-cache--table
    (clrhash gptel-agent-harness-cache--table))
  (when gptel-agent-harness-cache--seen
    (clrhash gptel-agent-harness-cache--seen))
  (when gptel-agent-harness-cache--stats
    (clrhash gptel-agent-harness-cache--stats))
  (message "gptel-agent-harness-cache: cleared"))

;;;; Enable / Disable

(defun gptel-agent-harness-cache-enable ()
  "Activate tool result caching with deduplication.
Adds :around advice to Glob/Grep/Read and :after advice to
Edit/Write/Insert for write-through invalidation."
  ;; Caching advice (wraps the final implementation, including harness overrides)
  (advice-add 'gptel-agent--read-file-lines
              :around #'gptel-agent-harness-cache--read-advice
              '((depth . -90)))
  (advice-add 'gptel-agent--glob
              :around #'gptel-agent-harness-cache--glob-advice
              '((depth . -90)))
  (advice-add 'gptel-agent--grep
              :around #'gptel-agent-harness-cache--grep-advice
              '((depth . -90)))
  ;; Write-through invalidation
  (advice-add 'gptel-agent--edit-files
              :after #'gptel-agent-harness-cache--after-edit)
  (advice-add 'gptel-agent--write-file
              :after #'gptel-agent-harness-cache--after-write)
  (advice-add 'gptel-agent--insert-in-file
              :after #'gptel-agent-harness-cache--after-insert))

(defun gptel-agent-harness-cache-disable ()
  "Deactivate tool result caching."
  (advice-remove 'gptel-agent--read-file-lines
                 #'gptel-agent-harness-cache--read-advice)
  (advice-remove 'gptel-agent--glob
                 #'gptel-agent-harness-cache--glob-advice)
  (advice-remove 'gptel-agent--grep
                 #'gptel-agent-harness-cache--grep-advice)
  (advice-remove 'gptel-agent--edit-files
                 #'gptel-agent-harness-cache--after-edit)
  (advice-remove 'gptel-agent--write-file
                 #'gptel-agent-harness-cache--after-write)
  (advice-remove 'gptel-agent--insert-in-file
                 #'gptel-agent-harness-cache--after-insert))

;;;; Setup / Teardown (per-buffer, called via gptel-mode-hook)

(defun gptel-agent-harness-cache--setup ()
  "Initialize cache tables for the current gptel buffer."
  (gptel-agent-harness-cache--ensure-tables))

(defun gptel-agent-harness-cache--teardown ()
  "Clean up cache state for the current buffer."
  (setq gptel-agent-harness-cache--table nil)
  (setq gptel-agent-harness-cache--seen nil)
  (setq gptel-agent-harness-cache--stats nil))

(provide 'gptel-agent-harness-cache)

;; Local Variables:
;; package-lint-main-file: "gptel-agent-harness.el"
;; End:
;;; gptel-agent-harness-cache.el ends here
