;;; gptel-agent-harness-coverage.el --- Test coverage infrastructure -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.3
;; Package-Requires: ((emacs "29.1"))
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
;; Function-level test coverage for gptel-agent-harness.  Every
;; top-level function defined in the source files is instrumented
;; with a `:before' advice; a function counts as covered when the
;; test suite calls it at least once.
;;
;; Batch usage:
;;   Emacs -Q -L . -L tests -batch \
;;     -l gptel-agent-harness-test \
;;     -l gptel-agent-harness-coverage \
;;     --eval '(gptel-agent-harness-coverage--run-with-report "coverage.txt")'
;;
;; Exits 0 when all tests pass and coverage meets
;; `gptel-agent-harness-coverage-minimum'; exits 1 otherwise.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)

(defcustom gptel-agent-harness-coverage-minimum 70
  "Minimum required function-level test coverage percentage.
Raise this as more coverage is added."
  :type 'integer
  :group 'gptel-agent-harness)

(defvar gptel-agent-harness-coverage--stats-accessors
  (if (fboundp 'ert-stats-total)
      '(ert-stats-total ert-stats-completed-expected
                        ert-stats-completed-unexpected)
    '(ert--stats-total ert--stats-completed-expected
                       ert--stats-completed-unexpected))
  "ERT stats accessors for the running Emacs version.
Emacs 29 renamed the internal `ert--stats-*' accessors to the
public `ert-stats-*' names; pick whichever exists.")

(defvar gptel-agent-harness-coverage--instrumented nil
  "List of (FILE . FUNCTION) pairs for instrumented functions.")

(defun gptel-agent-harness-coverage--source-directory ()
  "Return the harness source directory."
  (if load-file-name
      (expand-file-name ".." (file-name-directory load-file-name))
    default-directory))

(defun gptel-agent-harness-coverage--collect-source-files ()
  "Collect all source files in the harness directory."
  (cl-remove-if-not
   (lambda (f)
     (string-match-p "^gptel-agent-harness[^/]*\\.el$" f))
   (directory-files (gptel-agent-harness-coverage--source-directory)
                    nil "\\.el$")))

(defun gptel-agent-harness-coverage--top-level-functions (file)
  "Return the list of function symbols defined at top level in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((defs nil))
      (condition-case nil
          (while t
            (forward-comment (point-max))
            (let ((form (read (current-buffer))))
              (when (and (consp form)
                         (eq (car form) 'defun)
                         (symbolp (cadr form)))
                (push (cadr form) defs))))
        (end-of-file nil))
      (nreverse defs))))

(defun gptel-agent-harness-coverage--instrument ()
  "Add a `:before' advice to every top-level function in the source files.
Records each instrumented function in
`gptel-agent-harness-coverage--instrumented' and marks a function
as covered the first time it is called."
  (dolist (file (gptel-agent-harness-coverage--collect-source-files))
    (dolist (fn (gptel-agent-harness-coverage--top-level-functions file))
      (when (fboundp fn)
        (push (cons file fn) gptel-agent-harness-coverage--instrumented)
        (let ((target fn))
          (advice-add fn :before
                      (lambda (&rest _)
                        (put target 'gptel-agent-harness-coverage-called t))))))))

(defun gptel-agent-harness-coverage--covered-p (entry)
  "Return non-nil if the function in ENTRY was called."
  (get (cdr entry) 'gptel-agent-harness-coverage-called))

(defun gptel-agent-harness-coverage--generate-report (output-file)
  "Generate coverage report and save to OUTPUT-FILE.
Returns t if coverage passes the threshold, nil otherwise."
  (let* ((by-file
          (seq-group-by (lambda (entry) (car entry))
                        gptel-agent-harness-coverage--instrumented))
         (file-names (mapcar #'car by-file))
         (total (length gptel-agent-harness-coverage--instrumented))
         (covered (cl-count-if #'gptel-agent-harness-coverage--covered-p
                               gptel-agent-harness-coverage--instrumented))
         (uncovered (cl-remove-if #'gptel-agent-harness-coverage--covered-p
                                  gptel-agent-harness-coverage--instrumented))
         (coverage-percent
          (if (= total 0)
              100
            (round (* 100.0 (/ covered (float total))))))
         (passes-p (>= coverage-percent
                       gptel-agent-harness-coverage-minimum)))
    (with-temp-buffer
      (insert "=== gptel-agent-harness Coverage Report ===\n")
      (insert (format "Total instrumented functions: %d\n" total))
      (insert (format "Covered functions: %d\n" covered))
      (insert (format "Coverage: %d%%\n" coverage-percent))
      (insert "\n--- Per-File Coverage ---\n")
      (dolist (file (sort file-names #'string<))
        (let* ((entries (cdr (assoc file by-file)))
               (file-total (length entries))
               (file-covered (cl-count-if #'gptel-agent-harness-coverage--covered-p
                                          entries)))
          (insert (format "%s: %d/%d (%d%%)\n"
                          file file-covered file-total
                          (if (= file-total 0)
                              100
                            (round (* 100.0 (/ file-covered
                                                (float file-total)))))))))
      (insert "\n--- Uncovered Functions ---\n")
      (dolist (entry (sort uncovered
                           (lambda (a b) (string< (car a) (car b)))))
        (insert (format "%s (%s)\n" (cdr entry) (car entry))))
      (insert "\n")
      (insert (format "Threshold: %d%%\n"
                      gptel-agent-harness-coverage-minimum))
      (insert (if passes-p
                  "Status: PASS\n"
                "Status: FAIL - Coverage below threshold\n"))
      (write-region (point-min) (point-max) output-file nil 'silent))
    passes-p))

(defun gptel-agent-harness-coverage--run-with-report (output-file)
  "Run the ERT suite and write a coverage report to OUTPUT-FILE.
Exit with status 0 when all tests pass and coverage meets the
threshold; exit with status 1 otherwise."
  (gptel-agent-harness-coverage--instrument)
  (let* ((result (ert-run-tests-batch "^gptel-agent-harness"))
         (accessors gptel-agent-harness-coverage--stats-accessors)
         (total (funcall (nth 0 accessors) result))
         (passed (funcall (nth 1 accessors) result))
         (unexpected (funcall (nth 2 accessors) result))
         (tests-pass-p (zerop unexpected))
         (coverage-passes (gptel-agent-harness-coverage--generate-report
                           output-file))
         (ok (and tests-pass-p coverage-passes)))
    (message "gptel-agent-harness coverage: %s (%d/%d tests passed)"
             (if ok "PASS" "FAIL") passed total)
    (kill-emacs (if ok 0 1))))

(provide 'gptel-agent-harness-coverage)
;;; gptel-agent-harness-coverage.el ends here
