;   Copyright 2017 James Fleming <james@electronic-quill.net>
;
;   Licensed under the GNU General Public License
;   - for details, see LICENSE.txt in the top-level directory


;;;; The REST API server application

(in-package #:restagraph)
(declaim (optimize (compilation-speed 0)
                   (speed 2)
                   (safety 3)))

;;; Customised Hunchentoot acceptor.
;;; Carries information about the datastore being used.
(defclass restagraph-acceptor (tbnl:easy-acceptor)
  ;; Class attributes
  ((datastore :initarg :datastore
              :reader datastore
              :initform (error "Datastore object must be supplied.")
              :documentation "An object representing the datastore, on which the generic functions will be dispatched.")
   (uri-base-api :initarg :uri-base-api
                 :reader uri-base-api
                 :initform (error "uri-base-api is required"))
   (uri-base-schema :initarg :uri-base-schema
                    :reader uri-base-schema
                    :initform (error "uri-base-schema is required"))
   (uri-base-files :initarg :uri-base-files
                   :reader uri-base-files
                   :initform (error "uri-base-files is required"))
   (files-location :initarg :files-location
                   :reader files-location
                   :initform (error "files-location is required")))
  ;; Class defaults
  (:default-initargs :address "127.0.0.1")
  (:documentation "vhost object, subclassed from tbnl:easy-acceptor"))

;;; Define a logging method
(defmethod tbnl:acceptor-log-message ((acceptor restagraph-acceptor)
                                      log-level
                                      format-string
                                      &rest format-arguments)
  (log-message log-level (append (list format-string) format-arguments)))

;;; Configure Hunchentoot to extract POST-style parameters
;;; when processing PUT and DELETE requests
(pushnew :PUT tbnl:*methods-for-post-parameters*)
(pushnew :DELETE tbnl:*methods-for-post-parameters*)


;;; Utility functions

(defun sanitise-uid (uid)
  "Replace UID-unfriendly characters in UIDs with something safe"
  (declare (type (string) uid))
  (escape-neo4j
    (cl-ppcre:regex-replace-all "[/ ]" uid "_")))

(defun get-sub-uri (uri base-uri)
  (declare (type (string) uri base-uri))
  "Extract the URI from the full request string,
   excluding the base URL and any GET parameters."
  (first (cl-ppcre:split
           "\\?"
           (cl-ppcre:regex-replace base-uri uri ""))))

(defun get-uri-parts (uri)
  "Break the URI into parts for processing by uri-node-helper.
  Assumes the base-uri and trailing parameters have already been removed."
  (declare (type (string) uri))
  (mapcar #'sanitise-uid
          (cdr (ppcre:split "/" uri))))

(defun uri-node-helper (uri-parts &key (path "") (marker "n") (directional t))
  "Build a Cypher path ending in a node variable, which defaults to 'n'.
  Accepts a list of strings and returns a single string."
  (declare (type (or null cons) uri-parts)
           (type (string) path marker)
           (type (boolean) directional))
  (cond
    ((null uri-parts)
     (format nil "~A(~A)" path (escape-neo4j marker)))
    ((equal (length uri-parts) 1)
     (format nil "~A(~A:~A)" path (escape-neo4j marker) (first uri-parts)))
    ((equal (length uri-parts) 2)
     (format nil "~A(~A:~A { uid: '~A' })"
             path (escape-neo4j marker) (first uri-parts) (second uri-parts)))
    ((equal (length uri-parts) 3)
     (format nil "~A(:~A { uid: '~A' })-[:~A]~A(~A)"
             path
             (sanitise-uid (first uri-parts))
             (sanitise-uid (second uri-parts))
             (sanitise-uid (third uri-parts))
             (if directional "->" "-")
             (escape-neo4j marker)))
    (t
      (uri-node-helper
        (cdddr uri-parts)
        :path (format nil "~A(:~A { uid: '~A' })-[:~A]~A"
                      path
                      (sanitise-uid (first uri-parts))
                      (sanitise-uid (second uri-parts))
                      (sanitise-uid (third uri-parts))
                      (if directional "->" "-"))
        :marker marker
        :directional directional))))

(defun uri-rel-helper (uri-parts &key (path "") (marker "n") (directional t))
  "Build a Cypher path ending in a relationship variable, which defaults to 'n'.
  Accepts a list of strings and returns a single string."
  (declare (type (cons) uri-parts)
           (type (string) path marker)
           (type (boolean) directional))
  ;; Path-length must be a multiple of 3
  (if (= (mod (length uri-parts) 3) 0)
    ;; Path length is OK.
    ;; Is this the end of the path?
    (if (> (length uri-parts) 3)
      ;; More path to come
      (uri-rel-helper
        (cdddr uri-parts)
        :path (format nil "~A(:~A {uid: '~A'})-[:~A]~A"
                      path
                      (sanitise-uid (first uri-parts))
                      (sanitise-uid (second uri-parts))
                      (sanitise-uid (third uri-parts))
                      (if directional "->" "-"))
        :marker (escape-neo4j marker)
        :directional directional)
      ;; End of the path.
      ;; Return this along with whatever came before.
      (format nil "~A(:~A {uid: '~A'})-[~A:~A]"
              path
              (sanitise-uid (first uri-parts))
              (sanitise-uid (second uri-parts))
              (escape-neo4j marker)
              (sanitise-uid (third uri-parts))))
    ;; This isn't a path to a relationship
    (error 'client-error :message "Path length must be a multiple of 3.")))

(defun build-cypher-path (uri-parts &optional (path "") (marker "m"))
  "Build a Cypher path from the list of strings supplied.
  Attach a marker variable to the last node in the list, defaulting to 'm'."
  (declare (type (or null cons) uri-parts)
           (type (string) path)
           (type (string) marker))
  ;; sep == separator
  (let ((sep (if (equal path "") "" "->")))
    (cond
      ((null uri-parts)
       path)
      ((equal (length uri-parts) 1)
       (format nil "~A~A(~A:~A)" path sep marker (first uri-parts)))
      ((equal (length uri-parts) 2)
       (format nil "~A~A(~A:~A { uid: '~A' })"
               path sep marker (first uri-parts) (second uri-parts)))
      ((equal (length uri-parts) 3)
       (format nil "~A~A(~A:~A { uid: '~A' })-[:~A]"
               path sep marker (first uri-parts) (second uri-parts) (third uri-parts)))
      (t
       (build-cypher-path
         (cdddr uri-parts)
         (format nil "~A~A(:~A { uid: '~A' })-[:~A]"
                 path sep (first uri-parts) (second uri-parts) (third uri-parts)))))))

(defun format-schema-for-graphql (db)
  "Render the schema in a format suitable for GraphQL,
  in the format of Apollo Server and neo4j-graphql-js"
  (log-message :debug "Formatting schema for GraphQL")
  (let ((all-resourcetype-names
          (remove-if
            #'(lambda (name)
                (member name
                        '("any" "rgSchemas" "rgSchemaVersions")
                        :test #'equal))
            (mapcar
              #'(lambda (r)
                  ; Pull out just the name of the resource
                  (cdr (assoc :name r)))
              (get-resource-types db)))))
    (format nil "~{~A~^~%~%~}"
            (mapcar
              #'(lambda (r)
                  (describe-resource-type-for-graphql
                    db
                    ; resourcetype
                    r
                    ; all-resourcetype-names
                    all-resourcetype-names
                    ; rels-from-any
                    (describe-dependent-resources db "any" :resources-seen nil)))
              (remove-if #'(lambda (rtype)
                             (member rtype
                                     '("any" "rgSchemas" "rgSchemaVersions")
                                     :test #'equal))
                         all-resourcetype-names)))))

(defun hash-file (filepath &optional (digest 'ironclad:sha3/256))
  "Return the hash-digest of a file, as a string."
  (declare (type pathname filepath))
  (log-message :debug (format nil "Producing a hash digest of file '~A'" filepath))
  ;; Convert the digest back into a string
  (format nil "~{~2,'0X~}"
          (loop for b across
                ;; Digest the file
                (with-open-file (filestream filepath :element-type '(unsigned-byte 8))
                  (ironclad:digest-stream digest filestream))
                ;; Accumulator for the string to return
                collecting b)))

(defun digest-to-filepath (basedir digest)
  "Take a 64-bit digest string and the basedir, and return the target path to the file
   as a cons of two strings: the directory path and the filename"
  (declare (string basedir)
           (type string digest))
  (log-message :debug (format nil "Generating a filepath from base-dir '~A' and digest '~A'" basedir digest))
  (cons (format nil "~A/~A/~A/~A/"
                basedir
                (subseq digest 0 2)
                (subseq digest 2 4)
                (subseq digest 4 6))
        (subseq digest 6)))


;; Error response functions

(defun four-oh-four (&key file-p)
  "Fallthrough handler, for anything we haven't already defined.
   Also for requests for files we don't have."
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-not-found+)
  (if file-p
      "File not found"
      "This is not a valid URI"))

(defun method-not-allowed ()
  "Default response for a client making a request we don't support"
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-method-not-allowed+)
  "Method not allowed")

(defun uri-not-implemented ()
  "It's an API request, but not one we're configured for."
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-not-implemented+)
  "Not implemented")

(defun return-integrity-error (logmessage &optional client-message)
  "Report to the client that their request would have violated an integrity constraint.
  The optional client-message "
  (declare (type (string) logmessage)
           (type (or null string) client-message))
  (log-message :warn (format nil "Client triggered integrity error: ~A" logmessage))
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-conflict+)
  ;; If we were handed a specific message, use that.
  ;; Otherwise, just pass on the logmessage.
  (if client-message client-message logmessage))

(defun return-database-error (message)
  "There was a database problem. Log it and report something generic to the user, not to keep them in the dark but to reduce the potential for data leakage."
  (declare (type (string) message))
  (log-message :error (format nil "Database error: ~A" message))
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-internal-server-error+)
  "An error occurred with the database. This has been logged, and will be fixed.")

(defun return-transient-error (message)
  "Transient problem, which may already have self-resolved.. Log it and report something generic to the user, not to keep them in the dark but to reduce the potential for data leakage."
  (declare (type (string) message))
  (log-message :error (format nil "Database error: ~A" message))
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-service-unavailable+)
  "A transient error occurred, and has been logged for us to work on. Please try your request again.")

(defun return-client-error (logmessage &optional message)
  "The client made a bad request. Return this information to them, that they may learn from their mistakes."
  (declare (type (string) logmessage)
           (type (or null string) message))
  (log-message :info (format nil "Client error: ~A" logmessage))
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-bad-request+)
  ;; If we were handed a specific message, use that.
  ;; Otherwise, just pass on the logmessage.
  (format nil "Client error: ~A"
          (or message logmessage)))

(defun return-service-error (logmessage &optional message)
  "There was a problem with connecting to the backend service."
  (declare (type (string) logmessage)
           (type (or null string) message))
  (log-message :crit (format nil "Service error: ~A" logmessage))
  (setf (tbnl:content-type*) "text/plain")
  (setf (tbnl:return-code*) tbnl:+http-internal-server-error+)
  (format nil "Service error: ~A"
          (or message logmessage)))


;; Dispatchers

(defun schema-dispatcher-v1 ()
  "Hunchentoot dispatch function for managing Restagraph's schema."
  (handler-case
    (let ((uri-parts (get-uri-parts
                       (get-sub-uri (tbnl:request-uri*)
                                    (uri-base-schema tbnl:*acceptor*)))))
      (log-message :debug "Handling schema ~A request ~{/~A~}" (tbnl:request-method*) uri-parts)
      (cond
        ;; Get the description of a single resource-type
        ((and
           (equal (tbnl:request-method*) :GET)
           (first uri-parts))
         (progn
           (setf (tbnl:content-type*) "application/json")
           (setf (tbnl:return-code*) tbnl:+http-ok+)
           (cl-json:encode-json-alist-to-string
             (describe-resource-type
               (datastore tbnl:*acceptor*)
               (first uri-parts)))))
        ;; Get a description of the whole schema for the GraphQL engine
        ((and
           (equal (tbnl:request-method*) :GET)
           (tbnl:get-parameter "format")
           (equal (tbnl:get-parameter "format") "graphql"))
         (progn
           (log-message :info "Dumping schema in GraphQL format")
           (setf (tbnl:content-type*) "application/json")
           (setf (tbnl:return-code*) tbnl:+http-ok+)
           (format-schema-for-graphql (datastore tbnl:*acceptor*))))
        ;; Get a description of the whole schema in JSON format
        ((equal (tbnl:request-method*) :GET)
         (progn
           (setf (tbnl:content-type*) "application/json")
           (setf (tbnl:return-code*) tbnl:+http-ok+)
           (cl-json:encode-json-to-string
             (mapcar
               #'(lambda (r)
                   (describe-resource-type
                     (datastore tbnl:*acceptor*)
                     (cdr (assoc :name r))))
               (get-resource-types (datastore tbnl:*acceptor*))))))
        ;; Add a resource-type
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (first uri-parts) "resourcetype"))
         (let ((resourcetype (second uri-parts)))
           (cond
             ;; Sanity-check: was the resource-type supplied as a non-empty string?
             ((or
                (equal resourcetype "")
                (equal resourcetype "NIL"))
              (progn
                (setf (tbnl:content-type*) "text/plain")
                (setf (tbnl:return-code*) tbnl:+http-bad-request+)
                "At least give me the name of the resourcetype to create"))
             ;; Sanity-check: is the resource-type already present?
             ((resourcetype-exists-p (datastore tbnl:*acceptor*)
                                     resourcetype)
              (progn
                (setf (tbnl:content-type*) "text/plain")
                (setf (tbnl:return-code*) tbnl:+http-ok+)
                "Resourcetype already exists"))
             ;; Sanity tests passed; store it
             (t
               (let ((dependent (if (equal "true" (tbnl:post-parameter "dependent")) t nil)))
                 (log-message
                   :debug
                   (format nil "Adding resource type ~A with dependent status '~A' and notes '~A'."
                           resourcetype dependent (tbnl:post-parameter "notes")))
                 (add-resourcetype
                   (datastore tbnl:*acceptor*)
                   resourcetype
                   :dependent dependent
                   :notes (tbnl:post-parameter "notes"))
                 ;; Return something useful
                 (setf (tbnl:content-type*) "text/plain")
                 (setf (tbnl:return-code*) tbnl:+http-created+)
                 "Created")))))
        ;; Add an attribute to a resource-type
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (length uri-parts) 3)
           (equal (first uri-parts) "attribute"))
         (let ((resourcetype (second uri-parts))
               (attribute (third uri-parts)))
           (cond
             ;; Missing/nil resourcetype parameter.
             ;; If it's invalid, set-resourcetype-attribute will catch it.
             ((or
                (equal resourcetype "")
                (equal resourcetype "NIL"))
              (progn
                (setf (tbnl:content-type*) "text/plain")
                (setf (tbnl:return-code*) tbnl:+http-bad-request+)
                "At least give me the name of the resourcetype to modify"))
             ;; Missing/nil attribute parameter.
             ;; If it's invalid, set-resourcetype-attribute will catch it.
             ((or
                (equal attribute "")
                (equal attribute "NIL"))
              (progn
                (setf (tbnl:content-type*) "text/plain")
                (setf (tbnl:return-code*) tbnl:+http-bad-request+)
                "At least give me the name of the attribute to add"))
             ;; Sanity tests passed; set it.
             ;; Note that if the named attribute already exists, it will be forcibly replaced.
             (t
               (let ((description (tbnl:post-parameter "description"))
                     (vals (tbnl:post-parameter "vals")))
                 (log-message :debug (format nil "Adding attribute '~A' to resource type '~A'."
                                             attribute resourcetype))
                 (log-message :debug (format nil "Description: ~A" (if description
                                                                     description
                                                                     "Not supplied")))
                 (log-message :debug (format nil "Enum vals: ~A" (if vals
                                                                   vals
                                                                   "Not supplied")))
                 ;; Accumulate the parameters to make for a clean function-call
                 (set-resourcetype-attribute (datastore tbnl:*acceptor*)
                                             resourcetype
                                             :name attribute
                                             :description description
                                             :vals vals)
                 ;; Return something useful
                 (setf (tbnl:content-type*) "text/plain")
                 (setf (tbnl:return-code*) tbnl:+http-created+)
                 "Created")))))
        ;; Delete a resource-type
        ((and
           (equal (tbnl:request-method*) :DELETE)
           (equal (first uri-parts) "resourcetype"))
         (handler-case
           (let ((resourcetype (second uri-parts)))
             ;; Remove it
             (log-message :debug (format nil "Deleting resource type ~A" resourcetype))
             (delete-resourcetype (datastore tbnl:*acceptor*) resourcetype)
             ;; Return something useful
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-no-content+)
             "")
           (client-error
             (e)
             (return-client-error (message e)))))
        ;; Delete an attribute from a resource-type
        ((and
           (equal (tbnl:request-method*) :DELETE)
           (equal (first uri-parts) "attribute"))
         (handler-case
           (let ((resourcetype (second uri-parts))
                 (attribute (third uri-parts)))
             ;; Remove it
             (log-message :debug (format nil "Deleting attribute '~A' from resource type '~A'"
                                         attribute resourcetype))
             (delete-resourcetype-attribute (datastore tbnl:*acceptor*) resourcetype attribute)
             ;; Return something useful
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-no-content+)
             "")
           ;; If it breaks, pass the bad news back to the client.
           (client-error
             (e)
             (return-client-error (message e)))))
        ;; Add a relationship
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (first uri-parts) "relationships"))
         (let ((source-type (second uri-parts))
               (relationship (third uri-parts))
               (destination-type (fourth uri-parts)))
           ;; Sanity test
           (if (and
                 source-type
                 (not (equal source-type ""))
                 (not (equal source-type "NIL"))
                 relationship
                 (not (equal relationship ""))
                 (not (equal relationship "NIL"))
                 destination-type
                 (not (equal relationship ""))
                 (not (equal relationship "NIL")))
             ;; Store it
             (progn
               (log-message :debug
                            (format nil "Adding relationship ~A from ~A to ~A"
                                    relationship source-type destination-type))
               ;; Make it go
               (add-resource-relationship
                 (datastore tbnl:*acceptor*)
                 source-type
                 relationship
                 destination-type
                 :dependent (tbnl:post-parameter "dependent")
                 :cardinality (tbnl:post-parameter "cardinality"))
               ;; Return something useful
               (setf (tbnl:content-type*) "text/plain")
               (setf (tbnl:return-code*) tbnl:+http-created+)
               "Created")
             (progn
               (setf (tbnl:return-code*) tbnl:+http-bad-request+)
               (setf (tbnl:content-type*) "text/plain")
               "All parameters are required: /<source-type>/<relationship>/<destination-type>"))))
        ;; Delete a relationship
        ((and
           (equal (tbnl:request-method*) :DELETE)
           (equal (first uri-parts) "relationships"))
         (let ((source-type (second uri-parts))
               (relationship (third uri-parts))
               (destination-type (fourth uri-parts)))
           ;; Delete it
           (log-message :debug
                        (format nil "Deleting relationship ~A from ~A to ~A"
                                relationship source-type destination-type))
           (delete-resource-relationship (datastore tbnl:*acceptor*)
                                         source-type
                                         relationship
                                         destination-type)
           ;; Return something useful
           (setf (tbnl:content-type*) "text/plain")
           (setf (tbnl:return-code*) tbnl:+http-no-content+)
           ""))
        ;;
        ;; Methods we don't support.
        ;; Take the whitelist approach
        ((not (member (tbnl:request-method*) '(:POST :GET :PUT :DELETE)))
         (method-not-allowed))
        ;; Handle all other cases
        (t
          (return-client-error "This wasn't a valid request"))))
    ;; Handle general errors
    ;;
    ;; Attempted violation of db integrity
    (restagraph:integrity-error (e) (return-integrity-error (message e)))
    ;; Generic client errors
    (neo4cl:client-error (e) (return-client-error (neo4cl:message e)))
    ;; Transient error
    (neo4cl:transient-error (e) (return-transient-error e))
    ;; Database error
    (neo4cl:database-error (e) (return-database-error e))
    ;; Service errors, e.g. connection refused
    (neo4cl:service-error (e) (return-service-error (neo4cl:message e)))))

(defun api-dispatcher-v1 ()
  "Hunchentoot dispatch function for the Restagraph API, version 1."
  (handler-case
    (let* ((sub-uri (get-sub-uri (tbnl:request-uri*) (uri-base-api tbnl:*acceptor*)))
           (uri-parts (get-uri-parts sub-uri)))
      (log-message :debug "Handling request ~{~A~} " uri-parts)
      (cond
        ;;
        ;; Intercept and reject attempts to interact with the "any" resource-type
        ((equal (third uri-parts) "any")
         (progn
           (setf (tbnl:content-type*) "text/plain")
           (setf (tbnl:return-code*) tbnl:+http-not-found+)
           (format nil "No resources found for ~A" uri-parts)))
        ;;
        ;; GET -> Retrieve something
        ((equal (tbnl:request-method*) :GET)
         (log-message :debug
                      (format nil "Dispatching GET request for URI ~A"
                              (tbnl:request-uri*)))
         (let* (;; Do it separately because we use it again later in this function.
                ;; Get the search result
                (result (get-resources (datastore tbnl:*acceptor*)
                                       sub-uri
                                       :directional (when (tbnl:get-parameter "directional") t)
                                       :filters (remove-if
                                                  #'(lambda (par)
                                                      (equal (car par) "directional"))
                                                  (tbnl:get-parameters*)))))
           ;; Return what we found
           (progn
             (setf (tbnl:content-type*) "application/json")
             (setf (tbnl:return-code*) tbnl:+http-ok+)
             (cond
               ;; Single resource was requested, and nothing was found.
               ((and (= (mod (length uri-parts) 3) 2)
                     (or (null result)
                         (equal result "")))
                "[]")
               ;; Single resource was requested, and something was found.
               ((= (mod (length uri-parts) 3) 2)
                (cl-json:encode-json-alist-to-string result))
               ;; Class of resources was requested, and nothing was found.
               ((or (null result)
                    (equal result ""))
                "[]")
               ;; Class of resources was requested, and something was found.
               (t
                 (cl-json:encode-json-to-string result))))))
        ;; POST -> Store something
        ;;
        ;; Resource
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (length uri-parts) 1)
           (tbnl:post-parameter "uid"))
         (let ((resourcetype (first uri-parts)))
           (log-message :debug
                        (format nil
                                "Attempting to dispatch a POST request for resource type ~A"
                                resourcetype))
           ;; Do we already have one of these?
           (if (get-resources
                 (datastore tbnl:*acceptor*)
                 (format nil "/~A/~A" (car uri-parts) (tbnl:post-parameter "uid")))
             ;; It's already there; return 200/OK
             (progn
               (log-message
                 :debug
                 (format nil
                         "Doomed attempt to re-create resource /~A/~A. Reassuring the client that it's already there."
                         (car uri-parts)
                         (tbnl:post-parameter "uid")))
               (setf (tbnl:content-type*) "text/plain")
               (setf (tbnl:return-code*) tbnl:+http-ok+)
               (format nil "/~A/~A" resourcetype
                       (sanitise-uid (tbnl:post-parameter "uid"))))
             ;; We don't already have one of these; store it
             (handler-case
               (progn
                 (store-resource (datastore tbnl:*acceptor*)
                                 resourcetype
                                 (tbnl:post-parameters*))
                 ;; Return it from the database, for confirmation
                 (log-message :debug "Stored the new resource. Now retrieving it from the database, to return to the client.")
                 (setf (tbnl:content-type*) "text/plain")
                 (setf (tbnl:return-code*) tbnl:+http-created+)
                 ;; Return the URI to the newly-created resource
                 (format nil "/~A/~A" resourcetype
                         (sanitise-uid (tbnl:post-parameter "uid"))))
               ;; Handle integrity errors
               (restagraph:integrity-error (e) (return-integrity-error (message e)))
               ;; Handle general client errors
               (restagraph:client-error (e) (return-client-error (message e)))))))
        ;;
        ;; Store a relationship
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (mod (length uri-parts) 3) 0)
           (tbnl:post-parameter "target"))
         ;; Grab these once, as we'll be referring to them a few times
         (let ((dest-path (tbnl:post-parameter "target")))
           ;; Basic sanity check
           (log-message :debug (format nil "Creating a relationship from ~A to ~A" sub-uri dest-path))
           (handler-case
             (progn
               (create-relationship-by-path (datastore tbnl:*acceptor*) sub-uri dest-path)
               ;; Report success to the client
               (setf (tbnl:content-type*) "text/plain")
               (setf (tbnl:return-code*) tbnl:+http-created+)
               ;; Return the URI to the resource at the end of the newly-created relationship
               (format nil "~{/~A~}/~A/~A"
                       uri-parts    ; Path down to the relationship
                       (car (last (get-uri-parts dest-path) 2)) ; Target resourcetype
                       (car (last (get-uri-parts dest-path))))) ; Target UID
             ;; Attempted violation of db integrity
             (restagraph:integrity-error (e) (return-integrity-error (message e)))
             ;; Generic client errors
             (restagraph:client-error (e) (return-client-error (message e)))
             (neo4cl:client-error (e) (return-client-error (neo4cl:message e))))))
        ;;
        ;; Create a dependent resource
        ((and
           (equal (tbnl:request-method*) :POST)
           (equal (mod (length uri-parts) 3) 1)
           (tbnl:post-parameter "uid"))
         ;; Do we already have one of these?
         (if (get-resources
               (datastore tbnl:*acceptor*)
               (format nil "~{/~A~}/~A" uri-parts (tbnl:post-parameter "uid")))
           ;; It's already there; return 200/OK
           (progn
             (log-message
               :debug
               (format nil
                       "Doomed attempt to re-create resource /~A/~A. Reassuring the client that it's already there."
                       (car uri-parts)
                       (tbnl:post-parameter "uid")))
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-ok+)
             (format nil "~{/~A~}/~A" uri-parts (sanitise-uid (tbnl:post-parameter "uid"))))
           ;; We don't already have one of these; store it
           (handler-case
             (let ((newtype (car (last uri-parts)))
                   (uid (tbnl:post-parameter "uid")))
               (log-message :debug (format nil "Attempting to create dependent resource ~A:~A on ~A"
                                           newtype uid sub-uri))
               (store-dependent-resource
                 (datastore tbnl:*acceptor*) sub-uri (tbnl:post-parameters*))
               (setf (tbnl:content-type*) "text/plain")
               (setf (tbnl:return-code*) tbnl:+http-created+)
               ;; Return the URI to the resource at the end of the newly-created resource
               (format nil "~{/~A~}/~A" uri-parts (sanitise-uid (tbnl:post-parameter "uid"))))
             ;; Attempted violation of db integrity
             (restagraph:integrity-error (e) (return-integrity-error (message e)))
             ;; Generic client errors
             (restagraph:client-error (e) (return-client-error (message e)))
             (neo4cl:client-error (e) (return-client-error (neo4cl:message e))))))
        ;;
        ;; Re-home a dependent resource
        ((and
           (equal (tbnl:request-method*) :POST)
           (> (length uri-parts) 0)
           (equal (mod (length uri-parts) 3) 2)
           (tbnl:post-parameter "target"))
         (log-message :debug (format nil "Attempting to move dependent resource ~A to ~A"
                                     sub-uri (tbnl:post-parameter "target")))
         (handler-case
           (progn
             (move-dependent-resource
               (datastore tbnl:*acceptor*)
               sub-uri
               (tbnl:post-parameter "target"))
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-created+)
             ;; Return the URI to the new path for this resource
             (format nil "~{/~A~}/~A/~A" (get-uri-parts (tbnl:post-parameter "target"))
                     (car (last uri-parts 2))
                     (car (last uri-parts))))
           ;; Attempted violation of db integrity
           (restagraph:integrity-error (e) (return-integrity-error (message e)))
           ;; Generic client errors
           (restagraph:client-error (e) (return-client-error (message e)))
           (neo4cl:client-error (e) (return-client-error (neo4cl:message e)))))
        ;; PUT -> update something
        ;;
        ;; Resource attributes
        ((and
           (equal (tbnl:request-method*) :PUT)
           (equal (mod (length uri-parts) 3) 2))
         (handler-case
           (progn
             (log-message
               :debug
               (format nil "Attempting to update attributes of resource ~{/~A~}" uri-parts))
             (update-resource-attributes
               (datastore tbnl:*acceptor*)
               uri-parts
               (remove-if #'(lambda (param)
                              (or (null (cdr param))
                                  (equal (cdr param) "")))
                          (append (tbnl:post-parameters*)
                                  (tbnl:get-parameters*))))
             (setf (tbnl:content-type*) "application/json")
             (setf (tbnl:return-code*) tbnl:+http-no-content+)
             "")
           ;; Attempted violation of db integrity
           (restagraph:integrity-error (e) (return-integrity-error (message e)))
           ;; Generic client errors
           (restagraph:client-error (e) (return-client-error (message e)))
           (neo4cl:client-error (e) (return-client-error (neo4cl:message e)))))
        ;;
        ;; DELETE -> Delete something
        ;;
        ;; Attempting to delete a file
        ((and (equal (tbnl:request-method*) :DELETE)
              (equal (mod (length uri-parts) 3) 2)
              (equal "files" (first uri-parts)))
         (log-message :debug "Client is requesting deletion of a file")
         (setf (tbnl:content-type*) "text/plain")
         (setf (tbnl:return-code*) tbnl:+http-bad-request+)
         (format nil "Use the files API to delete files: /files/v1/~A" (second uri-parts)))
        ;; Resource
        ((and (equal (tbnl:request-method*) :DELETE)
              (equal (mod (length uri-parts) 3) 2))
         (log-message :debug "Attempting to delete a resource on an arbitrary path")
         (handler-case
           (progn
             (delete-resource-by-path
               (datastore tbnl:*acceptor*)
               sub-uri
               :recursive (tbnl:post-parameter "recursive"))
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-no-content+)
             "")
           ;; Attempted violation of db integrity
           (restagraph:integrity-error (e) (return-integrity-error (message e)))
           ;; Generic client errors
           (restagraph:client-error (e) (return-client-error (message e)))))
        ;;
        ;; Delete a relationship on an arbitrary path
        ((and (equal (tbnl:request-method*) :DELETE)
              (or (tbnl:post-parameter "resource")
                  (tbnl:get-parameter "resource"))
              (equal (mod (length uri-parts) 3) 0))
         (handler-case
           (progn
             (log-message :debug "Attempting to delete a relationship on an arbitrary path: ~A" sub-uri)
             (delete-relationship-by-path (datastore tbnl:*acceptor*)
                                          sub-uri
                                          (or (tbnl:post-parameter "resource")
                                              (tbnl:get-parameter "resource")))
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-no-content+)
             "")
           ;; Attempted violation of db integrity
           (restagraph:integrity-error (e) (return-integrity-error (message e)))
           ;; Generic client errors
           (restagraph:client-error (e) (return-client-error (message e)))))
        ;;
        ;; Methods we don't support.
        ;; Take the whitelist approach
        ((not (member (tbnl:request-method*) '(:POST :GET :PUT :DELETE)))
         (method-not-allowed))
        ;; Handle all other cases
        (t
          (log-message :warn "Bad request received with URI: ~A, reassembled as ~{/~A~}"
                       (tbnl:request-uri*) uri-parts)
          (return-client-error "This wasn't a valid request"))))
    ;; Handle general errors
    ;;
    ;; Generic client errors
    (neo4cl:client-error (e) (return-client-error (neo4cl:message e)))
    ;; Transient error
    (neo4cl:transient-error (e) (return-transient-error e))
    ;; Database error
    (neo4cl:database-error (e) (return-database-error e))
    ;; Service errors, e.g. connection refused
    (neo4cl:service-error (e) (return-service-error (neo4cl:message e)))))

(defun get-file-mime-type (filepath)
  (string-right-trim
    '(#\NewLine)
    (with-output-to-string (str)
      (sb-ext:run-program "/run/current-system/sw/bin/file"
                          (list "-b" "--mime-type" (namestring filepath))
                          :output str)
      str)))

(defun files-dispatcher-v1 ()
  "Files API handler, API version 1."
  (log-message :debug "Handling files request")
  (log-message :debug (format nil "Handling files '~A' request with content-type '~A'"
                              (tbnl:request-method*) (tbnl:content-type*)))
  (cond
    ;; Client fails to upload a file
    ((and (equal (tbnl:request-method*) :POST)
          (or (null (tbnl:post-parameter "name"))
              (equal "" (tbnl:post-parameter "name")))
          (or (null (tbnl:post-parameter "file"))
              (equal "" (tbnl:post-parameter "file"))))
     (return-client-error "The 'name' and 'file' parameters must be supplied"))
    ((and (equal (tbnl:request-method*) :POST)
          (or (null (tbnl:post-parameter "name"))
              (equal "" (tbnl:post-parameter "name"))))
     (return-client-error "The 'name' parameter must be supplied"))
    ((and (equal (tbnl:request-method*) :POST)
          (or (null (tbnl:post-parameter "file"))
              (equal "" (tbnl:post-parameter "file"))))
     (return-client-error "The 'file' parameter must be supplied"))
    ;; Client uploads a file
    ((equal (tbnl:request-method*) :POST)
     (log-message :debug (format nil "Requested filename: ~A" (or (tbnl:post-parameter "name") "<not specified>")))
     (log-message :debug (format nil "Temporary filepath: ~A" (first (tbnl:post-parameter "file"))))
     (log-message :debug (format nil "Original filename: ~A" (second (tbnl:post-parameter "file"))))
     (log-message :debug (format nil "Reported content-type: ~A" (third (tbnl:post-parameter "file"))))
     (let* ((requested-filename (tbnl:post-parameter "name"))
            ;; File-details should be a three-element list: (path file-name content-type)
            ;; Where do we store these, anyway?
            ;; "path is a pathname denoting the place were the uploaded file was stored, file-name
            ;; (a string) is the file name sent by the browser, and content-type (also a string) is
            ;; the content type sent by the browser. The file denoted by path will be deleted after
            ;; the request has been handled - you have to move or copy it somewhere else if you want
            ;; to keep it."
            ;; Get the filepath of the uploaded file
            (filepath-temp (first (tbnl:post-parameter "file")))
            ;; Get the checksum of the file
            (checksum (hash-file filepath-temp))
            (filepath-target-parts (digest-to-filepath (files-location tbnl:*acceptor*) checksum))
            (filepath-target (concatenate 'string (car filepath-target-parts)
                                          (cdr filepath-target-parts))))
       ;; Does a file of this name already exist?
       (log-message :debug (format nil "Checking for an existing file by name '~A'" requested-filename))
       (if (get-resources (datastore tbnl:*acceptor*)
                          (format nil "/files/~A" (sanitise-uid requested-filename)))
           ;; If it already exists, bail out now.
           (progn
             (log-message :error "File already exists")
             ;; Return client-error message indicating name collision
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-conflict+)
             "Filename already exists")
           ;; Name isn't already taken; rock on.
           (progn
             ;; Now we need to store the file's metadata,
             (log-message :debug "Storing file metadata: name = '~A', checksum = '~A'"
                          requested-filename checksum)
             (store-resource (datastore tbnl:*acceptor*)
                             "files"
                             `(("uid" . ,(sanitise-uid requested-filename))
                               ("title" . ,requested-filename)
                               ("sha3256sum" . ,checksum)
                               ("originalname" . ,(second (tbnl:post-parameter "file")))
                               ("mimetype" . ,(get-file-mime-type (namestring filepath-temp)))))
             ;; then if that succeeds move it to its new location.
             ;; Check whether this file already exists by another name
             (log-message :debug "Moving the file to its new home.")
             (log-message :debug (format nil "New home: '~A'" filepath-target))
             (if (probe-file filepath-target)
                 ;; If it does, don't bother overwriting it.
                 (log-message :debug
                              (format nil "File ~A already exists. Not overwriting it with a duplicate."
                                      filepath-target))
                 ;; If it doesn't, move it now.
                 (progn
                   (log-message :debug
                                (format nil "Moving received file '~A' to storage location '~A'"
                                        filepath-temp filepath-target))
                   ;; Ensure the destination path actually exists
                   (log-message :debug (format nil "Ensuring existence of target directory '~A'"
                                               (car filepath-target-parts)))
                   (ensure-directories-exist (car filepath-target-parts))
                   ;; Now move the file.
                   (log-message :debug
                                (format nil "Actually moving received file '~A' to storage location '~A'"
                                        filepath-temp filepath-target))
                   (rename-file filepath-temp filepath-target)))
             ;; If the location-move fails, we should probably remove the metadata and tell the client.
             ;;
             ;; Now return success to the client
             (setf (tbnl:content-type*) "text/plain")
             (setf (tbnl:return-code*) tbnl:+http-created+)
             (concatenate 'string "/files/" (sanitise-uid requested-filename))))))
    ;; Client requests a file
    ((equal (tbnl:request-method*) :GET)
     (log-message :debug
                  (format nil "Dispatching GET request for URI ~A"
                          (tbnl:request-uri*)))
     (let* ((filename (first (get-uri-parts
                               (get-sub-uri (tbnl:request-uri*)
                                            (uri-base-files tbnl:*acceptor*)))))
            ;; Do it separately because we use it again later in this function.
            ;; Get the search result
            (result (get-resources (datastore tbnl:*acceptor*)
                                   (format nil "/files/~A" filename)
                                   :directional nil
                                   :filters nil)))
       (log-message :debug (format nil "Retrieved resource details ~A" result))
       ;; Return the file to the client if it's present
       (cond
         ((not (null result))
          (let* ((source-path-parts (digest-to-filepath
                                      (files-location tbnl:*acceptor*)
                                      (cdr (assoc :sha3256sum result))))
                 (source-path (concatenate 'string (car source-path-parts) (cdr source-path-parts))))
            (log-message :debug (format nil "Returning the file from source-path '~A'"
                                        source-path))
            (tbnl:handle-static-file
              source-path
              ;; Specify the mime-type
              (cdr (assoc :mime-type result)))))
         ;; Fallthrough for not finding the file
         (t
          (log-message :debug "Null result returned")
          (setf (tbnl:content-type*) "text/plain")
          (setf (tbnl:return-code*) tbnl:+http-not-found+)
          "File not found"))))
    ;; Client requests deletion of a file
    ((equal (tbnl:request-method*) :DELETE)
     (log-message :debug "File deletion requested")
     (let* ((filename (first (get-uri-parts
                               (get-sub-uri (tbnl:request-uri*)
                                            (uri-base-files tbnl:*acceptor*))))))
       (log-message :debug (format nil "Client requested deletion of file '~A'" filename))
       ;; Check whether the file is present.
       (let ((result (get-resources (datastore tbnl:*acceptor*)
                                    (format nil "/files/~A" filename)
                                    :directional nil
                                    :filters nil)))
         (log-message :debug (format nil "Got result '~A'" result))
         (if result
             ;; If it is, delete its metadata and then (conditionally) the file itself.
             (progn
               (log-message :debug (format nil "Found file details '~A'" result))
               ;; Delete the metadata
               (delete-resource-by-path
                 (datastore tbnl:*acceptor*)
                 (concatenate 'string "/files/" filename)
                 :recursive nil)
               ;; Now delete the file itself
               (when (null (get-resources (datastore *restagraph-acceptor*)
                                          "/files"
                                          :filters '(("sha3256sum" .
                                                      (cdr (assoc :SHA3256SUM (cdr result)))))))
                 (let* ((source-path-parts (digest-to-filepath
                                             (files-location tbnl:*acceptor*)
                                             (cdr (assoc :sha3256sum result))))
                        (source-path (concatenate 'string
                                                  (car source-path-parts)
                                                  (cdr source-path-parts))))
                   (log-message :debug (format nil "Deleting the file at source-path '~A'"
                                               source-path))
                   (delete-file source-path)))
               ;; Now return a suitable message to the client
               (setf (tbnl:content-type*) "text/plain")
               (setf (tbnl:return-code*) tbnl:+http-no-content+)
               "")
             ;; If not, return 404
             (progn
               (log-message :debug (format nil "Requested file '~A' not found. Returning 404" filename))
               (four-oh-four :file-p t))))))
    ;;
    ;; Methods we don't support.
    ;; Take the whitelist approach
    ((not (member (tbnl:request-method*) '(:POST :GET :DELETE)))
     (method-not-allowed))
    ;; Handle all other cases
    (t
      (log-message :warn "Bad request received with URI: ~A" (tbnl:request-uri*))
      (return-client-error "This wasn't a valid request"))))



;; Appserver startup/shutdown

(defun make-default-acceptor ()
  (make-instance 'restagraph-acceptor
                 :address (or (sb-ext:posix-getenv "LISTEN_ADDR")
                              (getf *config-vars* :listen-address))
                 :port (or (when (sb-ext:posix-getenv "LISTEN_PORT")
                             (parse-integer (sb-ext:posix-getenv "LISTEN_PORT")))
                           (getf *config-vars* :listen-port))
                 :uri-base-api (or (when (sb-ext:posix-getenv "API_URI_BASE")
                                     (parse-integer (sb-ext:posix-getenv "API_URI_BASE")))
                                   (getf *config-vars* :api-uri-base))
                 :uri-base-schema (or (when (sb-ext:posix-getenv "SCHEMA_URI_BASE")
                                        (parse-integer (sb-ext:posix-getenv "SCHEMA_URI_BASE")))
                                      (getf *config-vars* :schema-uri-base))
                 :uri-base-files (or (when (sb-ext:posix-getenv "FILES_URI_BASE")
                                       (parse-integer (sb-ext:posix-getenv "FILES_URI_BASE")))
                                     (getf *config-vars* :files-uri-base))
                 :files-location (or (when (sb-ext:posix-getenv "FILES_LOCATION")
                                       (parse-integer (sb-ext:posix-getenv "FILES_LOCATION")))
                                     (getf *config-vars* :files-location))
                 ;; Send all logs to STDOUT, and let Docker sort 'em out
                 :access-log-destination (make-synonym-stream 'cl:*standard-output*)
                 :message-log-destination (make-synonym-stream 'cl:*standard-output*)
                 ;; Datastore object - for specialising all the db methods on
                 :datastore (make-instance
                              'neo4cl:neo4j-rest-server
                              :hostname (or (sb-ext:posix-getenv "NEO4J_HOSTNAME")
                                            (getf *config-vars* :dbhostname))
                              :port (or (sb-ext:posix-getenv "NEO4J_PORT")
                                        (getf *config-vars* :dbport))
                              :dbname (or (sb-ext:posix-getenv "NEO4J_DBNAME")
                                          (getf *config-vars* :dbname))
                              :dbuser (or (sb-ext:posix-getenv "NEO4J_USER")
                                          (getf *config-vars* :dbusername))
                              :dbpasswd (or (sb-ext:posix-getenv "NEO4J_PASSWORD")
                                            (getf *config-vars* :dbpasswd)))))

(defun ensure-db-passwd (server)
  "Check the credentials for the database, and return a boolean."
  (log-message :info "Checking database credentials.")
  (let ((err (cdr (assoc :errors
                    (neo4cl:neo4j-transaction
                      server
                      '((:statements ((:statement . "MATCH (n) RETURN n")))))))))
    ;; Crude error handling
    (if (and (listp err)
             (null err))
      ;; Credentials check out; we're good
      (progn
        (log-message :debug "Password is good.")
        t)
      ;; Credentials failed; we have a problem
      (progn
        (log-message :debug (format nil "Credentials failed: '~A'" err))
        nil))))

(defun confirm-db-is-running (server &key (counter 1) (max-count 5) (sleep-time 5))
  "Check whether the database server is running by polling the discovery endpoint."
  (declare (type (integer) counter max-count sleep-time))
  (log-message :debug "Checking whether the database is running on ~A:~A"
               (neo4cl:hostname server) (neo4cl:port server))
  (handler-case
    (when (drakma:http-request
            (format nil "http://~A:~A" (neo4cl:hostname server) (neo4cl:port server)))
      (ensure-db-passwd server))
    (USOCKET:CONNECTION-REFUSED-ERROR
      (e)
      (declare (ignore e))
      (if (>= counter max-count)
        ;; Timed out.
        ;; Leave a message, then exit this whole thing.
        (progn
          (log-message :crit "Timed out trying to connect to the database. Exiting.")
          (sb-ext:exit))
        ;; Still isn't responding, but we haven't yet hit timeout.
        ;; Leave a message, pause, then try again.
        (progn
          (log-message :warn "Connection refused. Pausing for ~A seconds before retrying" sleep-time)
          (sleep sleep-time)
          (confirm-db-is-running server
                                 :counter (+ counter 1)
                                 :max-count max-count
                                 :sleep-time sleep-time))))))

(defun startup (&key acceptor dispatchers docker schemapath)
  "Start up the appserver.
   Ensures the uniqueness constraint on resource-types is present in Neo4j.
   Keyword arguments:
   - acceptor = prebuilt acceptor, to use instead of the default.
   - dispatchers = extra dispatchers to add to tbnl:*dispatch-table* in addition to the defaults.
   - docker = whether to start up in a manner suitable to running under docker,
   i.e. return only after Hunchentoot shuts down, instead of immediately after it starts up.
   - schemapath = path to directory containing schema files, in YAML format, with .yaml extension. If this is absent, a check will be made for the environment variable SCHEMAPATH.
   If supplied, parse all .yaml files in alphabetical order, and apply each one that has a newer
   version number than is recorded in the database."
  (declare (type (boolean) docker)
           (type (or null string) schemapath))
  (log-message :info "Attempting to start up the restagraph application server")
  ;; Control the decoding of JSON identifiers
  (setf JSON:*JSON-IDENTIFIER-NAME-TO-LISP* 'common-lisp:string-upcase)
  ;; Sanity-check: do we have a storage directory?
  (let ((files-location (or (when (sb-ext:posix-getenv "FILES_LOCATION")
                              (parse-integer (sb-ext:posix-getenv "FILES_LOCATION")))
                            (getf *config-vars* :files-location))))
    (ensure-directories-exist files-location)
    (unless (probe-file files-location)
      (error (format nil "File storage location ~A does not exist!" files-location))))
  ;; Sanity-check: is an acceptor already running?
  ;;; We can't directly check whether this acceptor is running,
  ;;; so we're using the existence of its special variable as a proxy.
  (if (boundp '*restagraph-acceptor*)
      ;; There's an acceptor already in play; bail out.
      (log-message :warn "Acceptor already exists; refusing to create a new one.")
      ;; No existing acceptor; we're good to go.
      ;;
      ;; Figure out whether we have a schema directory to work with
      (let ((schemadir
              (cond
                ;; Were we passed one explicitly?
                (schemapath schemapath)
                ;; Is one set via an environment variable?
                ((sb-ext:posix-getenv "SCHEMAPATH") (sb-ext:posix-getenv "SCHEMAPATH"))
                ;; Default case
                (t nil))))
        ;; Ensure we have an acceptor to work with
        (unless acceptor (setf acceptor (make-default-acceptor)))
        ;; Make it available as a dynamic variable, for shutdown to work on
        (defparameter *restagraph-acceptor* acceptor)
        ;; Sanity-check whether the database is available
        (unless (confirm-db-is-running (datastore acceptor) :max-count 25)
          (error "Database is not available"))
        ;; Ensure we have a uniqueness constraint on resource-types
        (handler-case
          (neo4cl:neo4j-transaction
            (datastore acceptor)
            `((:STATEMENTS
                ((:STATEMENT . "CREATE CONSTRAINT ON (r:rgResource) ASSERT r.name IS UNIQUE")))))
          ;; If this fails because we already did it, that's fine.
          (neo4cl:client-error
            (e)
            ;; If we already have this constraint, catch the error and move on.
            (if (and
                  (equal "Schema" (neo4cl:category e))
                  (equal "EquivalentSchemaRuleAlreadyExists" (neo4cl:title e)))
                nil
                ;; If anything else went wrong, log it and pass it on up the stack
                (progn
                  (log-message :debug (format nil "Received error '~A.~A ~A'"
                                              (neo4cl:category e)
                                              (neo4cl:title e)
                                              (neo4cl:message e)))
                  (return-database-error
                    (format nil "~A.~A: ~A"
                            (neo4cl:category e)
                            (neo4cl:title e)
                            (neo4cl:message e)))))))
        ;; Update the schema, if one has been specified
        (inject-all-schemas (datastore acceptor) schemadir)
        ;; Set the dispatch table
        (restagraph:log-message :info "Configuring the dispatch table")
        (setf tbnl:*dispatch-table*
              (append
                ;; Restagraph defaults
                (list (tbnl:create-prefix-dispatcher
                        (uri-base-api acceptor) 'api-dispatcher-v1)
                      (tbnl:create-prefix-dispatcher
                        (uri-base-schema acceptor) 'schema-dispatcher-v1)
                      (tbnl:create-prefix-dispatcher
                        (uri-base-files acceptor) 'files-dispatcher-v1))
                ;; Include the additional dispatchers here
                dispatchers
                ;; Default fallback
                (list (tbnl:create-prefix-dispatcher "/" 'four-oh-four))))
        ;; Prepare for file upload
        (ensure-directories-exist (getf *config-vars* :files-temp-location))
        (setf tbnl:*tmp-directory* (getf *config-vars* :files-temp-location))
        ;; Start up the server
        (log-message :info "Starting up Hunchentoot to serve HTTP requests")
        (handler-case
          (tbnl:start acceptor)
          (usocket:address-in-use-error
            () (log-message :error
                            (format nil "Attempted to start an already-running instance!"))))
        (when docker
          (sb-thread:join-thread
            (find-if
                    (lambda (th)
                      (string= (sb-thread:thread-name th)
                               (format nil "hunchentoot-listener-~A:~A"
                                       (tbnl:acceptor-address acceptor)
                                       (tbnl:acceptor-port acceptor))))
                    (sb-thread:list-all-threads)))))))

(defun dockerstart (&key schemapath)
  (declare (type (or null string) schemapath))
  (if schemapath
    (startup :docker t :schemapath schemapath)
    (startup :docker t)))

(defun save-image (&optional (path "/tmp/restagraph"))
  (declare (type (string) path))
  (sb-ext:save-lisp-and-die path :executable t :toplevel 'restagraph::dockerstart))

(defun shutdown ()
  ;; Check whether there's something to shut down
  (if (and
        (boundp '*restagraph-acceptor*)
        *restagraph-acceptor*)
      ;; There is; go ahead
      (progn
      ;; Check whether it's still present but shutdown
      (if (tbnl::acceptor-shutdown-p *restagraph-acceptor*)
          (log-message :info "Acceptor was present but already shut down.")
          (progn
            (restagraph:log-message
              :info
              (format nil "Shutting down the restagraph application server"))
            (handler-case
              ;; Perform a soft shutdown: finish serving any requests in flight
              (tbnl:stop *restagraph-acceptor* :soft t)
              ;; Catch the case where it's already shut down
              (tbnl::unbound-slot
                ()
                (restagraph:log-message
                  :info
                  "Attempting to shut down Hunchentoot, but it's not running."))
              (sb-pcl::no-applicable-method-error
                ()
                (restagraph:log-message
                  :info
                  "Attempted to shut down Hunchentoot, but received an error. Assuming it wasn't running.")))))
        ;; Nuke the acceptor
        (makunbound '*restagraph-acceptor*))
      ;; No acceptor. Note the fact and do nothing.
      (restagraph:log-message :warn "No acceptor present; nothing to shut down.")))
