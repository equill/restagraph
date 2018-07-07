;   Copyright 2017 James Fleming <james@electronic-quill.net>
;
;   Licensed under the Apache License, Version 2.0 (the "License");
;   you may not use this file except in compliance with the License.
;   You may obtain a copy of the License at
;
;       http://www.apache.org/licenses/LICENSE-2.0
;
;   Unless required by applicable law or agreed to in writing, software
;   distributed under the License is distributed on an "AS IS" BASIS,
;   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;   See the License for the specific language governing permissions and
;   limitations under the License.


;;;; Logging infrastructure
;;; We only need something extremely simple

(in-package #:restagraph)

(defvar *loglevels*
  '(:crit 4
    :critical 4
    :error 3
    :warn 2
    :warning 2
    :info 1
    :debug 0))

;; Set the threshold logging level
(defparameter *loglevel* :debug)

(defparameter *log-stream*
  (make-synonym-stream 'cl:*standard-output*))

(defun make-timestamp ()
  (multiple-value-bind (sec minute hour date month year)
    (get-decoded-time)
    (format nil "[~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d]"
    year month date hour minute sec)))

(defun log-message (severity &rest args)
  (when (>= (getf *loglevels* severity)
            (getf *loglevels* *loglevel*))
    (format *log-stream* "~A ~A ~A~%"
            (make-timestamp)
            severity
            (apply #'format (append '(()) args)))))
