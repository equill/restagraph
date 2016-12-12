(asdf:defsystem #:restagraph
  :serial t
  :license "MIT license"
  :author "James Fleming <james@electronic-quill.net>"
  :description "Generates a REST API from a shema defined in Neo4J"
  :depends-on (#:neo4cl
               #:hunchentoot)
  :components ((:file "package")
               (:file "config")
               (:file "conditions")
               (:file "logging")
               (:file "generics")
               (:file "neo4j")
               (:file "schema")
               (:file "hunchentoot")))
