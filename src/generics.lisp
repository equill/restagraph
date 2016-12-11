(in-package #:restagraph)


;;;; Schema

(defgeneric get-resources-from-db (db)
  (:documentation "Extract the resource definitions from the database.
Returns a hashtable:
- <resource-type> -> hash-table
-- <attribute-name> -> hash-table
--- <attribute-attributes> -> alist"))

(defgeneric get-resource-names-from-db (db)
  (:documentation "Extract the names of resource definitions from the database"))

(defgeneric get-resource-attributes-from-db (db)
  (:documentation "Extract the attributes from resource definitions from the database"))

(defgeneric get-resource-relationships-from-db (db)
  (:documentation "Extract the relationships between the resource types, from the database"))

(defgeneric add-resourcetype-to-schema (schema resourcetype attributes)
  (:documentation "Add a resource-type to a schema, ensuring the internal structure is ready to receive new attributes and relationships."))

(defgeneric get-resourcetype-from-schema-by-name (schema resourcename)
  (:documentation "Extract a resource' definition from the schema, by name."))

(defgeneric add-resource-relationship-to-schema (schema from-resource relationship to-resource)
  (:documentation "Update the schema with a directional relationship between two resource types, returning an error if either of the resource types doesn't exist."))

(defgeneric relationship-valid-p (schema from-resource relationship to-resource)
  (:documentation "Checks whether this type of relationship is permitted between these types of resources. Returns a boolean."))


;;;; Resource instances

(defgeneric store-resource (db resourcetype attributes)
  (:documentation "Store a resource in the database.
Return an error if
- the resource type is not present in the schema
- any of the attributes is not defined in the schema for this resource type."))

(defgeneric get-resource-by-uid (db resourcetype uid)
  (:documentation "Retrieve a representation of a resource from the database."))

(defgeneric delete-resource-by-uid (db resourcetype uid)
  (:documentation "Delete a resource from the database. Automatically remove all relationships to other nodes."))

;;;; Relationships

(defgeneric create-relationship (db source-type source-uid reltype dest-type dest-uid)
  (:documentation "Create a relationship between two resources"))

(defgeneric get-resources-with-relationship (db resourcetype uid reltype)
  (:documentation "Retrieve a summary of all resources with a given relationship to this one.
  Return a list of two-element lists, where the first element is the resource-type and the second is the UID."))

(defgeneric delete-relationship (db source-type source-uid reltype dest-type dest-uid)
  (:documentation "Delete a relationship between two resources"))
