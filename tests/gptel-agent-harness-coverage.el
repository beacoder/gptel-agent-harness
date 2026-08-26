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
;; File-level test coverage for gptel-agent-harness.  A source file is
;; considered covered when its feature was loaded by the test suite, so
;; a source file that no test requires lowers the measured coverage.
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

(defcustom gptel-agent-harness-coverage-minimum 90
  "Minimum required test coverage percentage.
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

(defun gptel-agent-harness-coverage--covered-source-files ()
  "Return source files whose feature was loaded by the test suite."
  (cl-remove-if-not
   (lambda (f)
     (let ((feature (intern
                     (file-name-sans-extension (file-name-nondirectory f)))))
       (featurep feature)))
   (gptel-agent-harness-coverage--collect-source-files)))

(defun gptel-agent-harness-coverage--generate-report (output-file)
  "Generate coverage report and save to OUTPUT-FILE.
Returns t if coverage passes the threshold, nil otherwise."
  (let* ((all-files (gptel-agent-harness-coverage--collect-source-files))
         (covered-files (gptel-agent-harness-coverage--covered-source-files))
         (total-count (length all-files))
         (covered-count (length covered-files))
         (coverage-percent
          (if (= total-count 0)
              100
            (round (* 100.0 (/ covered-count (float total-count))))))
         (passes-p (>= coverage-percent gptel-agent-harness-coverage-minimum)))
    (with-temp-buffer
      (insert "=== gptel-agent-harness Coverage Report ===\n")
      (insert (format "Total source files: %d\n" total-count))
      (insert (format "Covered files: %d\n" covered-count))
      (insert (format "Coverage: %d%%\n" coverage-percent))
      (insert "\n--- Covered Files ---\n")
      (dolist (f covered-files)
        (insert (format "%s\n" f)))
      (insert "\n--- Uncovered Files ---\n")
      (dolist (f (cl-set-difference all-files covered-files :test #'string=))
        (insert (format "%s\n" f)))
      (insert "\n")
      (insert (format "Threshold: %d%%\n" gptel-agent-harness-coverage-minimum))
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
