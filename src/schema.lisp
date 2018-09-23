;;;; Schema creation functions

(in-package #:restagraph)

(defun read-schemas (parent-dir)
  "Parse the .yaml files in the specified directory, in alphabetical order.
  Return the result as a list of objects output by cl-yaml:parse,
  expected to be hash objects."
  ;; Safety first: is the directory even there?
  (if (probe-file parent-dir)
      ;; This is _really_ ugly, but guarantees alphabetical order.
      (mapcar #'cl-yaml:parse
              (mapcar #'pathname
                      (sort
                        (mapcar #'namestring
                                (directory (make-pathname
                                             :name :wild
                                             :type "yaml"
                                             :directory parent-dir)))
                        #'string<)))
      ;; Safety-check failed. Complain loudly.
      (progn
        (error (format nil "Schema directory ~A doesn't exist!" parent-dir))
        (log-message :fatal (format nil "Schema directory ~A doesn't exist!" parent-dir)))))

(defun ensure-schema-schema (db)
  "Bootstrap function to ensure the database contains the schema-related schema.
   Must be handled separately from the schema we're trying to inject."
  (log-message :info "Attempting to apply schema")
  ;; Schema name.
  ;; Enables us to combine multiple schemas in a single system.
  (unless (resourcetype-exists-p db "rgSchemas")
    (progn
      (log-message :info "Attempting to add resourcetype rgSchemas")
      (add-resourcetype
        db
        "rgSchemas"
        :notes "Schema-management schema.")))
  ;; Schema version object.
  ;; Allows us to track the history of schema updates in this installation.
  (unless (resourcetype-exists-p db "rgSchemaVersions")
    (progn
      (log-message :info "Attempting to add resourcetype rgSchemaVersions")
      (add-resourcetype
        db
        "rgSchemaVersions"
        :dependent t
        :notes "Schema version-management atom.")))
  ;; Define the relationship between schemas and their versions
  (unless (get-relationship-attrs db "rgSchemas" "Versions" "rgSchemaVersions")
    (log-message :info "Attempting to link rgSchemas with rgSchemaVersions")
    (add-resource-relationship
      db
      "rgSchemas"
      "Versions"
      "rgSchemaVersions"
      :dependent t
      :cardinality "1:many")))

(defun get-schema-version (db name &key all-versions)
  "Extract the highest version number in the database for the named schema.
   If no such schema is present, return NIL."
  (let ((rawdata (get-resources
                   db
                   (format nil "/rgSchemas/~A/Versions/rgSchemaVersions" name))))
    (log-message :debug "Versions retrieved")
    (when rawdata
      (let ((versions
              (mapcar
                #'(lambda (row)
                    (realpart
                      (parse-integer
                        (cdr (assoc :uid row :test #'equal)))))
                rawdata)))
        (if all-versions
            versions
            (apply 'max versions))))))

(defun set-schema-version (db name version)
  "Set the version for the named schema.
   If there's no record of a schema by this name, create that first.
   version should be an integer."
  ;; Ensure the schema itself is represented,
  ;; and that we're attempting to store a newer version than already exists.
  (if (get-resources db (format nil "/rgSchemas/~A" name))
      ;; Schema is already represented; sanity-check the version
      (let ((existing-version (get-schema-version db name)))
        (when (not (> version existing-version))
          (error "Attempting to store a version that is not greater than the existing highest.")))
      ;; Not already there; create it.
      (store-resource db "rgSchemas" `(("uid" . ,name))))
  ;; Now set the version
  (store-dependent-resource
    db
    (format nil "/rgSchemas/~A/Versions/rgSchemaVersions" name)
    `(("uid" . ,(format nil "~A" version)))))

(defun inject-schema (db schema)
  "Apply the supplied schema, if it's a newer version than the one already present,
   or if there isn't one already there.
   schema is expected to be the output of cl-yaml:parse."
  ;; Ensure the schema-schema is in place
  (ensure-schema-schema db)
  ;; Now do the actual thing
  ;; Get these values now because current-version is used repeatedly
  (let* ((current-version (get-schema-version db (gethash "name" schema))))
    ;; Sanity-check: is there already a schema in place,
    ;; of a version equal to or greater than the one we've read in?
    (if (and current-version
             (>= current-version (gethash "version" schema)))
        ;; Schema is already in place, and this one isn't newer.
        (log-message
          :info
          "Schema version ~A is present. Not attempting to supersede it with version ~A."
          current-version
          (gethash "version" schema))
        ;; This schema is newer than the existing one. Carry on.
        (progn
          (log-message
            :info
            "Superseding existing schema version ~A with version ~A."
            current-version
            (gethash "version" schema))
          ;; Update resourcetypes
          (log-message :info "Adding resources")
          (maphash
            #'(lambda (resourcename value)
                (log-message
                  :debug
                  (format nil "Attempting to add resource '~A'" resourcename))
                ;; Build the resource definition,
                ;; including only the attributes actually supplied
                (let ((resource
                        (append
                          (list db resourcename)
                          (when (gethash "dependent" value)
                            (list :dependent (gethash "dependent" value)))
                          (when (gethash "notes" value)
                            (list :notes (gethash "notes" value))))))
                  (apply #'add-resourcetype resource))
                ;; Now add the attributes.
                ;; Looks like a really clunky way to go about it,
                ;; but is designed to be extended with other attribute-attributes,
                ;; such as type and input validation.
                (when
                  ;; Only do this if the resourcetype has an 'attributes' subhash
                  (gethash "attributes" value)
                  ;; Process each attribute-attribute in turn
                  (log-message
                    :debug
                    (format nil "Processing attributes for resourcetype ~A"
                            resourcename))
                  (maphash #'(lambda (attrname attrdetails)
                               (log-message
                                 :debug
                                 (format nil "Processing attribute ~A"
                                         attrname))
                               (let ((attribute
                                       (append
                                         ;; Each attr-attr has at least this much
                                         (list db resourcename :name attrname)
                                         (when (and
                                                 attrdetails
                                                 (hash-table-p attrdetails)
                                                 (gethash "description" attrdetails))
                                           (log-message
                                             :debug
                                             (format
                                               nil "Adding description ~A"
                                               (gethash "description" attrdetails)))
                                           (list :description
                                                 (gethash "description" attrdetails))))))
                                 (apply #'add-resourcetype-attribute attribute)))
                           (gethash "attributes" value))))
            (gethash "resourcetypes" schema))
          ;; Update relationships between resourcetypes
          (log-message :info "Adding relationships between resources")
          (mapcar
            #'(lambda (rel)
                ;; Sanity-check
                (if (and
                      rel
                      (hash-table-p rel)
                      (gethash "uri" rel))
                    ;; We're OK; carry on
                    (let ((relparts (cl-ppcre:split "/" (gethash "uri" rel))))
                      (log-message
                        :debug
                        "Requesting to add relationship '~A' from '~A' to '~A'"
                        (third relparts) (second relparts) (fourth relparts))
                      (handler-case
                        (add-resource-relationship
                          db
                          (second relparts)   ; parent-type
                          (third relparts)    ; relationship
                          (fourth relparts)   ; dependent-type
                          :dependent (gethash "dependent" rel)
                          :cardinality (gethash "cardinality" rel)
                          :notes (gethash "notes" rel))
                        (restagraph:integrity-error (e)
                                                    (log-message :error (restagraph:message e)))))
                    ;; Sanity-check failed
                    (log-message :warning
                                 (format nil "Invalid entry ~A" rel))))
            (gethash "relationships" schema))
          ;; Record the current version of the schema
          (log-message :info "Update schema version in database")
          (set-schema-version db (gethash "name" schema) (gethash "version" schema))))))
