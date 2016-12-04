;;;; Methods and functions specifically relating to Neo4J

(in-package #:restagraph)


;;;; Schema methods and functions

(defmethod get-classes-from-db ((db neo4cl:neo4j-rest-server))
  (mapcar #'car
          (neo4cl::extract-rows-from-get-request
            (neo4cl:neo4j-transaction
              db
              `((:STATEMENTS
                  ((:STATEMENT . "MATCH (c:rgClass) RETURN c.name"))))))))

(defmethod get-class-relationships-from-db ((db neo4cl:neo4j-rest-server))
          (neo4cl::extract-rows-from-get-request
            (neo4cl:neo4j-transaction
              db
              `((:STATEMENTS
                  ((:STATEMENT . "MATCH (c:rgClass)-[r]->(t:rgClass) RETURN c.name, type(r), t.name")))))))

;;;; Classes

(defmethod store-class-instance ((db neo4cl:neo4j-rest-server) classname post-params)
  (let* (;; Local cache of the schema for the requested class
         (classdata (get-class-from-schema-by-name (getf *config-vars* :schema) classname))
         ;; Attributes that are valid for this resource type
         (valid-attributes (gethash "attributes" classdata))
         ;; Attributes with which to create the resource
         (attributes ())
         ;; Attributes that were specified but aren't valid for this resource-type
         (invalid-attributes ()))
    ;; Check whether the requested classname is valid
    (log-message :debug (format nil "Checking validity of class name '~A'." classname))
    (unless classname
      (error (format nil "The class name ~A is not present in the schema." classname)))
    ;; Check whether a UID has been specified
    (unless (assoc "uid" post-params :test 'equal)
      (log-message :debug "No UID found in the request parameters")
      (error "UID must be supplied as a POST parameter."))
    ;; Check for invalid attributes in the request
    (log-message :debug (format nil "Checking validity of supplied parameters ~A." post-params))
    (loop for (name . value) in post-params
          do (if (or (equal name '"uid")                ; Mandatory values
                     (gethash name valid-attributes)    ; User-configured defaults
                     (member name (getf *config-vars* :default-write-attributes) :test 'equal))
               (push (cons (intern name :keyword) value) attributes)
               (push name invalid-attributes)))
    ;; Report on the valid attributes we have
    (log-message :debug (format nil "The following attributes will be used when creating the resource: ~{~A~^, ~}." attributes))
    ;; If any requested attributes are invalid, report them as an error
    (when invalid-attributes
      (let ((message (format nil "These requested attributes are invalid for the resource-type ~A: ~{~A~^, ~}."
                             classname
                             invalid-attributes)))
        (log-message :debug message)
        (error message)))
    ;; If we got this far, we have a valid class name and valid attribute names.
    ;; Make it happen
    (neo4cl:neo4j-transaction
      db
      `((:STATEMENTS
          ((:STATEMENT . ,(format nil "CREATE (:~A { properties })" classname))
           (:PARAMETERS .
            ((:PROPERTIES . ,attributes)))))))))
