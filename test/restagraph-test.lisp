;;;; Test suite for all of restagraph
;;;;
;;;; Beware: it currently only tests _expected_ cases,
;;;; and does not test edge-cases or wrong input.

(in-package #:restagraph-test)

(defparameter *server*
  (restagraph::datastore restagraph::*restagraph-acceptor*))

(fiveam:def-suite main)
(fiveam:in-suite main)

(fiveam:test
  resources-basic
  "Basic operations on resources"
  (let ((restype "routers")
        (uid "amchitka")
        (comment "Test router #1")
        (invalid-type "interfaces")
        (invalid-uid "eth0"))
    ;; Confirm the resource isn't already present
    (fiveam:is (equal "{}" (restagraph::get-resources
                             *server* (format nil "/~A/~A" restype uid))))
    ;; Store the resource
    (multiple-value-bind (result code message)
      (restagraph::store-resource *server* restype `(("uid" . ,uid) ("comment" . ,comment)))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Confirm it's there
    (fiveam:is (equal
                 (format nil "{\"uid\":\"~A\",\"original_uid\":\"~A\",\"comment\":\"~A\"}"
                         uid (restagraph::sanitise-uid uid) comment)
                 (restagraph::get-resources
                   *server* (format nil "/~A/~A" restype uid))))
    ;; Delete it
    (multiple-value-bind (result code message)
      (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" restype uid))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Confirm it's gone again
    (fiveam:is (equal "{}" (restagraph::get-resources
                             *server* (format nil "/~A/~A" restype uid))))
    ;; Ensure we can't create a dependent type
    (fiveam:signals
      (restagraph:integrity-error "This is a dependent resource; it must be created as a sub-resource of an existing resource.")
      (restagraph::store-resource *server* invalid-type `(("uid" . ,invalid-uid))))))

(fiveam:test
  resources-dependent-simple
  "Basic operations on dependent resources"
  (let ((parent-type "routers")
        (parent-uid "bikini")
        (relationship "Interfaces")
        (child-type "interfaces")
        (child-uid "eth0")
        (invalid-child-type "routers")
        (invalid-child-uid "whitesands"))
    ;; Check underlying mechanisms
    (fiveam:is (equal
                 '("SubInterfaces" "HasModel" "Interfaces" "Addresses")
                 (restagraph::get-dependent-relationships-for-type *server* child-type)))
    ;; Create the parent resource
    (restagraph::store-resource *server* parent-type `(("uid" . ,parent-uid)))
    ;; Create the dependent resource
    (multiple-value-bind (result code message)
      (restagraph::store-dependent-resource
        *server*
        (format nil "/~A/~A/~A" parent-type parent-uid relationship)
        `(("type" . ,child-type) ("uid" . ,child-uid)))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Confirm it exists
    ;; Confirm it's the only member of the parent's dependents
    (fiveam:is (equal `((,relationship ,child-type ,child-uid))
                      (restagraph::get-dependent-resources
                        *server* (list parent-type parent-uid))))
    ;; Fail to delete the dependent resource
    (fiveam:signals
      (restagraph:client-error "This is a dependent resource. If you really want to delete it, try again with the 'delete-dependent=true' parameter.")
      (restagraph::delete-resource-by-path
        *server*
        (format nil "/~A/~A/~A/~A/~A"
                parent-type parent-uid relationship child-type child-uid)))
    ;; Delete the dependent resource
    (multiple-value-bind (result code message)
      (restagraph::delete-resource-by-path
        *server*
        (format nil "/~A/~A/~A/~A/~A"
                parent-type parent-uid relationship child-type child-uid)
        :delete-dependent t)
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Confirm the dependent resource is gone
    (fiveam:is (equal "{}" (restagraph::get-resources
                             *server* (format nil "/~A/~A" child-type child-uid))))
    ;; Attempt to create a child resource that isn't of a dependent type
    (fiveam:signals (restagraph:client-error "This is not a dependent resource type")
      (restagraph::store-dependent-resource
        *server*
        (format nil "/~A/~A/~A" parent-type parent-uid relationship)
        `(("type" . ,invalid-child-type) ("uid" . ,invalid-child-uid))))
    ;; Create the dependent resource yet again
    (restagraph::store-dependent-resource
      *server*
      (format nil "/~A/~A/~A" parent-type parent-uid relationship)
      `(("type" . ,child-type) ("uid" . ,child-uid)))
    ;; Delete the parent resource
    (restagraph::log-message :info "TEST Recursively deleting the parent resource")
    (restagraph::delete-resource-by-path
      *server*
      (format nil "/~A/~A" parent-type parent-uid)
      :delete-dependent t)
    ;; Confirm the dependent resource was recursively deleted with it
    (restagraph::log-message :info "TEST Confirm the dependent resource is gone")
    (fiveam:is (equal "{}" (restagraph::get-resources
                             *server* (format nil "/~A/~A" child-type child-uid))))
    (restagraph::log-message :info "TEST resources-dependent is complete")))

(fiveam:test
  resources-multiple
  "Confirm we can retrieve all resources of a given type"
  (let ((resourcetype "routers")
        (res1uid "amchitka")
        (res1attrname "comment")
        (res1attrval "Test router")
        (res2uid "bikini")
        (res3uid "mururoa"))
    ;; Confirm we have no instances of that resource in place now
    (fiveam:is (null (restagraph::get-resources *server* (format nil "/~A" resourcetype))))
    ;; Add one of that kind of resource
    (restagraph::store-resource *server* resourcetype `(("uid" . ,res1uid) (,res1attrname . ,res1attrval)))
    ;; Confirm we now get a list containing exactly that resource
    (fiveam:is (equal
                 (format nil "[[{\"uid\":\"~A\",\"original_uid\":\"~A\",\"~A\":\"~A\"}]]"
                         res1uid (restagraph::sanitise-uid res1uid) res1attrname res1attrval)
                 (restagraph::get-resources *server* (format nil "/~A" resourcetype))))
    ;; Add a second of that kind of resource
    (restagraph::store-resource *server* resourcetype `(("uid" . ,res2uid)))
    ;; Confirm we now get a list containing both resources
    (fiveam:is (equal
                 (format nil "[[{\"uid\":\"~A\",\"original_uid\":\"~A\",\"~A\":\"~A\"}],[{\"uid\":\"~A\",\"original_uid\":\"~A\"}]]"
                         res1uid (restagraph::sanitise-uid res1uid) res1attrname res1attrval
                         res2uid (restagraph::sanitise-uid res2uid))
                 (restagraph::get-resources *server* (format nil "/~A" resourcetype))))
    ;; Add a third of that kind of resource
    (restagraph::store-resource *server* resourcetype `(("uid" . ,res3uid)))
    ;; Confirm we now get a list containing both resources
    (fiveam:is (equal
                 (format nil "[[{\"uid\":\"~A\",\"original_uid\":\"~A\",\"~A\":\"~A\"}],[{\"uid\":\"~A\",\"original_uid\":\"~A\"}],[{\"uid\":\"~A\",\"original_uid\":\"~A\"}]]"
                         res1uid (restagraph::sanitise-uid res1uid) res1attrname res1attrval
                         res2uid (restagraph::sanitise-uid res2uid)
                         res3uid (restagraph::sanitise-uid res3uid))
                 (restagraph::get-resources *server* (format nil "/~A" resourcetype))))
    ;; Delete all the resources we added
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" resourcetype res1uid))
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" resourcetype res2uid))
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" resourcetype res3uid))))

(fiveam:test
  relationships
  "Basic operations on relationships between resources"
  (let ((from-type "routers")
        (from-uid "bikini")
        (relationship "Asn")
        (to-type "asn")
        (to-uid "64512"))
    (restagraph::log-message :info "TEST Creating the resources")
    ;; Store the router
    (restagraph::store-resource *server* from-type `(("uid" . ,from-uid)))
    ;; Create the interface
    (restagraph::store-resource *server* to-type `(("uid" . ,to-uid)))
    ;; Create a relationship between them
    (restagraph::log-message :info "TEST Create the relationship")
    ;(handler-case
      (multiple-value-bind (result code message)
        (restagraph::create-relationship-by-path
          *server*
          (format nil "/~A/~A/~A" from-type from-uid relationship)
          (format nil "/~A/~A" to-type to-uid))
        (declare (ignore result) (ignore message))
        (fiveam:is (equal 200 code)))
      ;(restagraph:client-error (e) (format t "~A" (restagraph:message e))))
    ;; Confirm the relationship is there
    (restagraph::log-message :info "TEST Confirm the relationship")
    (fiveam:is (equal
                 `((("resource-type" . ,to-type) ("uid" . ,to-uid)))
                 (restagraph::get-resources-with-relationship *server* from-type from-uid relationship)))
    ;; Delete the relationship
    (restagraph::log-message :info "TEST Delete the relationship")
    (multiple-value-bind (result code message)
      (restagraph::delete-resource-by-path
        *server*
        (format nil "/~A/~A/~A/~A/~A"
                from-type from-uid relationship to-type to-uid))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Delete the router
    (restagraph::log-message :info "TEST Cleanup: removing the resources")
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" from-type from-uid))
    ;; Delete the interface
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" to-type to-uid))))

(fiveam:test
  relationships-integrity
  "Basic operations on relationships between resources"
  (let ((from-type "routers")
        (from-uid "bikini")
        (relationship "Asn")
        (to-type "asn")
        (to-uid "64512"))
    ;; Create the resources
    (restagraph::log-message :info "TEST Creating the resources")
    (restagraph::store-resource *server* from-type `(("uid" . ,from-uid)))
    ;; Create the interface
    (restagraph::store-resource *server* to-type `(("uid" . ,to-uid)))
    ;; Create a relationship between them
    (multiple-value-bind (result code message)
      (restagraph::create-relationship-by-path
        *server*
        (format nil "/~A/~A/~A" from-type from-uid relationship)
        (format nil "/~A/~A" to-type to-uid))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Confirm the relationship is there
    (fiveam:is (equal
                 `((("resource-type" . ,to-type) ("uid" . ,to-uid)))
                 (restagraph::get-resources-with-relationship *server* from-type from-uid relationship)))
    ;; Attempt to create a duplicate relationship between them
    (fiveam:signals (restagraph:integrity-error
                      (format nil "Relationship ~A already exists from ~A ~A to ~A ~A"
                              relationship from-type from-uid to-type to-uid))
                    (restagraph::create-relationship-by-path
                      *server*
                      (format nil "/~A/~A/~A" from-type from-uid relationship)
                      (format nil "/~A/~A" to-type to-uid)))
    ;; Confirm we still only have one relationship between them
    (fiveam:is (equal
                 `((("resource-type" . ,to-type) ("uid" . ,to-uid)))
                 (restagraph::get-resources-with-relationship *server* from-type from-uid relationship)))
    ;; Delete the relationship
    (multiple-value-bind (result code message)
      (restagraph::delete-relationship-by-path
        *server*
        (format nil "/~A/~A/~A/"
                from-type from-uid relationship)
        (format nil "/~A/~A/" to-type to-uid))
      (declare (ignore result) (ignore message))
      (fiveam:is (equal 200 code)))
    ;; Clean-up: delete the resources
    (restagraph::log-message :info "TEST Cleaning up: removing the resources")
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" from-type from-uid))
    (restagraph::delete-resource-by-path *server* (format nil "/~A/~A" to-type to-uid))))

(fiveam:test
  errors-basic
  "Errors that can be triggered just by making a bad request"
  (let ((invalid-resourcetype "IjustMadeThisUpNow")
        (valid-resourcetype "routers")
        (invalid-attributes '(foo))
        (valid-attributes '("comment")))
    ;; Create a resource of an invalid type
    (restagraph::log-message :info "TEST Creating a resource of an invalid type")
    (fiveam:signals (restagraph:integrity-error
                      (format nil "Requested resource type ~A is not valid." invalid-resourcetype))
      (restagraph::store-resource *server* invalid-resourcetype '((:foo . "bar"))))
    ;; Create a resource of a valid type, but without a UID
    (restagraph::log-message :info "TEST Creating a valid resource without a UID")
    (fiveam:signals (restagraph:client-error "UID must be supplied")
      (restagraph::store-resource *server* valid-resourcetype '(("foo" . "bar"))))
    ;; Create a resource with a UID and a valid type, but another invalid attribute
    (restagraph::log-message :info "TEST Creating a resource with an invalid attribute")
    (fiveam:signals (restagraph:client-error
                      (format nil "These requested attributes are invalid for the resource-type ~A: ~{~A~^, ~}. Valid attributes are: ~{~A~^, ~}."
                              valid-resourcetype
                              invalid-attributes
                              valid-attributes))
      (restagraph::store-resource *server* valid-resourcetype '(("uid" . "amchitka") (:foo . "bar"))))))
