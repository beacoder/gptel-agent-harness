;;; gptel-agent-harness-coverage.el --- Test coverage infrastructure -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Huming Chen
;;
;; Author: Huming Chen <chenhuming@gmail.com>
;; URL: https://github.com/beacoder/gptel-agent-harness
;; Package-Version: 0.4
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
;; Form-level test coverage for gptel-agent-harness using the built-in
;; `testcover' package (which wraps `edebug' instrumentation).
;;
;; Each top-level form in the source files is instrumented by
;; `testcover-start'.  After the test suite runs, the `edebug-coverage'
;; vector for each instrumented symbol is examined: entries marked
;; `edebug-unknown' are uncovered; all other entries are covered.
;;
;; Batch usage:
;;   Emacs -Q -L . -L tests -batch \
;;     -l gptel-agent-harness-coverage \
;;     --eval '(gptel-agent-harness-coverage--start)' \
;;     -l gptel-agent-harness-test \
;;     --eval '(gptel-agent-harness-coverage--run-with-report "coverage.txt")'
;;
;; Exits 0 when all tests pass and coverage meets
;; `gptel-agent-harness-coverage-minimum'; exits 1 otherwise.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'edebug)
(require 'testcover)

(defcustom gptel-agent-harness-coverage-minimum 70
  "Minimum required form-level test coverage percentage.
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

(defvar gptel-agent-harness-coverage--instrumented-files nil
  "List of (FILE-NAME . FULL-PATH) pairs for instrumented source files.")

(defun gptel-agent-harness-coverage--lenient-after
    (_before-index after-index value)
  "Like `testcover-after' but never raise an error.
AFTER-INDEX is the form's index into the coverage vector.
VALUE is the form's result.
testcover marks forms that always return the same value as
1-valued and raises an error when such a form later returns a
different value.  This breaks test suites that exercise the same
form with different inputs.  We silently upgrade such forms to
`edebug-ok-coverage' instead."
  (let ((old-result (aref testcover-vector after-index)))
    (cond
     ((eq 'edebug-unknown old-result)
      (aset testcover-vector after-index
            (testcover--copy-object value)))
     ((eq 'maybe old-result)
      (aset testcover-vector after-index 'edebug-ok-coverage))
     ((eq '1value old-result)
      (aset testcover-vector after-index
            (cons old-result (testcover--copy-object value))))
     ((eq (car-safe old-result) '1value)
      (aset testcover-vector after-index 'edebug-ok-coverage))
     ((not (condition-case ()
               (equal value old-result)
             (circular-list nil)))
      (aset testcover-vector after-index 'edebug-ok-coverage))))
  value)

(defun gptel-agent-harness-coverage--source-directory ()
  "Return the harness source directory."
  (if load-file-name
      (expand-file-name ".." (file-name-directory load-file-name))
    default-directory))

(defun gptel-agent-harness-coverage--collect-source-files ()
  "Collect all source files in the harness directory.
Returns a list of (FILE-NAME . FULL-PATH) pairs."
  (let ((dir (gptel-agent-harness-coverage--source-directory)))
    (mapcar
     (lambda (f)
       (cons f (expand-file-name f dir)))
     (cl-remove-if-not
      (lambda (f)
        (string-match-p "^gptel-agent-harness[^/]*\\.el$" f))
      (directory-files dir nil "\\.el$")))))

(defun gptel-agent-harness-coverage--start ()
  "Instrument all source files for coverage via `testcover-start'.
Must be called BEFORE the test suite is loaded so that test
functions pick up the instrumented definitions."
  (setq gptel-agent-harness-coverage--instrumented-files nil)
  ;; Replace testcover-after with our lenient version that does not
  ;; raise errors when a 1-valued form returns different values.
  (setf (cdr (assq 'testcover edebug-behavior-alist))
        (list #'testcover-enter
              #'testcover-before
              #'gptel-agent-harness-coverage--lenient-after))
  (dolist (entry (gptel-agent-harness-coverage--collect-source-files))
    (let ((file-name (car entry))
          (full-path (cdr entry)))
      (condition-case err
          (progn
            (testcover-start full-path)
            (push entry gptel-agent-harness-coverage--instrumented-files))
        (error
         (message "testcover: skipping %s: %s"
                  file-name (error-message-string err)))))))

(defun gptel-agent-harness-coverage--form-covered-p (entry)
  "Return non-nil if ENTRY in a coverage vector indicates a covered form.
ENTRY is a value from the `edebug-coverage' vector.
`edebug-unknown' means the form was never evaluated (uncovered).
All other values indicate the form was evaluated at least once."
  (not (eq entry 'edebug-unknown)))

(defun gptel-agent-harness-coverage--symbol-stats (sym)
  "Return (COVERED . TOTAL) for instrumented symbol SYM.
Reads the `edebug-coverage' vector property."
  (let ((cov (get sym 'edebug-coverage)))
    (if (not (vectorp cov))
        (cons 0 0)
      (let ((total (length cov))
            (covered 0))
        (dotimes (i total)
          (when (gptel-agent-harness-coverage--form-covered-p (aref cov i))
            (cl-incf covered)))
        (cons covered total)))))

(defun gptel-agent-harness-coverage--file-stats (file-path)
  "Return (COVERED . TOTAL) for all instrumented forms in FILE-PATH.
FILE-PATH is the full path to a source file that was instrumented
by `testcover-start'.  The buffer for FILE-PATH must be live."
  (let ((buf (find-buffer-visiting file-path))
        (total 0)
        (covered 0))
    (if (not buf)
        (cons 0 0)
      (with-current-buffer buf
        (dolist (entry edebug-form-data)
          (let* ((sym (car entry))
                 (stats (gptel-agent-harness-coverage--symbol-stats sym)))
            (cl-incf total (cdr stats))
            (cl-incf covered (car stats))))))
    (cons covered total)))

(defun gptel-agent-harness-coverage--uncovered-forms (file-path)
  "Return a list of uncovered form symbols in FILE-PATH."
  (let ((buf (find-buffer-visiting file-path))
        (uncovered nil))
    (when buf
      (with-current-buffer buf
        (dolist (entry edebug-form-data)
          (let* ((sym (car entry))
                 (cov (get sym 'edebug-coverage)))
            (when (vectorp cov)
              (dotimes (i (length cov))
                (when (not (gptel-agent-harness-coverage--form-covered-p
                            (aref cov i)))
                  (push sym uncovered))))))))
    (nreverse uncovered)))

(defun gptel-agent-harness-coverage--generate-report (output-file)
  "Generate coverage report and save to OUTPUT-FILE.
Returns t if coverage passes the threshold, nil otherwise."
  (let* ((files (nreverse gptel-agent-harness-coverage--instrumented-files))
         (all-stats
          (mapcar
           (lambda (entry)
             (let* ((file-name (car entry))
                    (full-path (cdr entry))
                    (stats (gptel-agent-harness-coverage--file-stats full-path)))
               (list :file file-name
                     :full-path full-path
                     :covered (car stats)
                     :total (cdr stats)
                     :uncovered (gptel-agent-harness-coverage--uncovered-forms
                                 full-path))))
           files))
         (total (cl-reduce #'+ (mapcar (lambda (s) (plist-get s :total)) all-stats)))
         (covered (cl-reduce #'+ (mapcar (lambda (s) (plist-get s :covered)) all-stats)))
         (coverage-percent
          (if (= total 0)
              100
            (round (* 100.0 (/ covered (float total))))))
         (passes-p (>= coverage-percent gptel-agent-harness-coverage-minimum)))
    (with-temp-buffer
      (insert "=== gptel-agent-harness Coverage Report ===\n")
      (insert (format "Total forms: %d\n" total))
      (insert (format "Covered forms: %d\n" covered))
      (insert (format "Coverage: %d%%\n" coverage-percent))
      (insert "\n--- Per-File Coverage ---\n")
      (dolist (stats all-stats)
        (let ((f-total (plist-get stats :total))
              (f-covered (plist-get stats :covered))
              (f-name (plist-get stats :file)))
          (insert (format "%s: %d/%d (%d%%)\n"
                          f-name f-covered f-total
                          (if (= f-total 0)
                              100
                            (round (* 100.0 (/ f-covered (float f-total)))))))))
      (insert "\n--- Uncovered Forms ---\n")
      (let ((any-uncovered nil))
        (dolist (stats all-stats)
          (let ((uncovered (plist-get stats :uncovered))
                (f-name (plist-get stats :file)))
            (when uncovered
              (setq any-uncovered t)
              (dolist (sym uncovered)
                (insert (format "%s: %s\n" f-name sym))))))
        (unless any-uncovered
          (insert "(none)\n")))
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
