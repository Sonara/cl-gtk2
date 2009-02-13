(in-package :gobject)

(defvar *lisp-name-package* (find-package :gobject))
(defvar *strip-prefix* "")
(defvar *lisp-name-exceptions* nil)
(defvar *generation-exclusions* nil)
(defvar *known-interfaces* (make-hash-table :test 'equal))

(defun name->supplied-p (name)
  (intern (format nil "~A-SUPPLIED-P" (symbol-name name))
          *lisp-name-package*))

(defun property->method-arg (property)
  (destructuring-bind (name accessor-name g-name type readable writable) property
    (declare (ignore accessor-name g-name type readable writable))
    `(,name nil ,(name->supplied-p name))))

(defun property->arg-push (property)
  (destructuring-bind (name accessor-name g-name type readable writable) property
    (declare (ignore accessor-name readable writable))
    `(when ,(name->supplied-p name)
       (push ,g-name arg-names)
       (push ,type arg-types)
       (push ,name arg-values))))

(defun accessor-name (class-name property-name)
  (intern (format nil "~A-~A" (symbol-name class-name)
                  (lispify-name property-name))
          *lisp-name-package*))

(defun property->reader (property)
  (let ((name (nth 1 property))
        (prop-name (nth 2 property))
        (prop-type (nth 3 property)))
    `(defun ,name (object)
       (g-object-call-get-property object ,prop-name ,prop-type))))

(defun property->writer (property)
  (let ((name (nth 1 property))
        (prop-name (nth 2 property))
        (prop-type (nth 3 property)))
    `(defun (setf ,name) (new-value object)
       (g-object-call-set-property object ,prop-name new-value ,prop-type)
       new-value)))

(defun property->accessors (property export)
  (append (when (nth 4 property)
            (list (property->reader property)))
          (when (nth 5 property)
            (list (property->writer property)))
          (when export
            (list `(export ',(nth 1 property)
                           (find-package ,(package-name (symbol-package (nth 1 property)))))))))

(defun interface->lisp-class-name (interface)
  (etypecase interface
    (symbol interface)
    (string (or (gethash interface *known-interfaces*)
                (error "Unknown interface ~A" interface)))))

(defmacro define-g-object-class (g-type-name name (&optional (superclass 'g-object) (export t)) (&rest interfaces)
                                 &body properties)
  (let* ((superclass-properties (get superclass 'properties))
         (combined-properties (append superclass-properties properties)))
    `(progn
       (defclass ,name (,superclass ,@(mapcar #'interface->lisp-class-name interfaces)) ())
       (register-object-type ,g-type-name ',name)
       ,@(when export
               (list `(export ',name (find-package ,(package-name (symbol-package name)))))) 
       (defmethod initialize-instance :before 
           ((object ,name) &key pointer
            ,@(mapcar #'property->method-arg
                      combined-properties))
         (unless (or pointer (and (slot-boundp object 'pointer)
                                  (not (null-pointer-p (pointer object)))))
           (let (arg-names arg-values arg-types)
             ,@(mapcar #'property->arg-push combined-properties)
             (setf (pointer object)
                   (g-object-call-constructor ,g-type-name
                                              arg-names
                                              arg-values
                                              arg-types)
                   (g-object-has-reference object) t))))
       ,@(loop
            for property in properties
            append (property->accessors property export))
       
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (setf (get ',name 'superclass) ',superclass
               (get ',name 'properties) ',combined-properties)))))

(defmacro define-g-interface (g-name name (&optional (export t)) &body properties)
  `(progn
     (defclass ,name () ())
     ,@(when export
             (list `(export ',name (find-package ,(package-name (symbol-package name))))))
     ,@(loop
          for property in properties
          append (property->accessors property export))
     (eval-when (:compile-toplevel :load-toplevel :execute)
       (setf (get ',name 'properties) ',properties)
       (setf (gethash ,g-name *known-interfaces*) ',name))))

(defun starts-with (name prefix)
  (and prefix (> (length name) (length prefix)) (string= (subseq name 0 (length prefix)) prefix)))

(defun strip-start (name prefix)
  (if (starts-with name prefix)
      (subseq name (length prefix))
      name))

(defun lispify-name (name)
  (with-output-to-string (stream)
    (loop for c across (strip-start name *strip-prefix*)
       for firstp = t then nil
       do (when (and (not firstp) (upper-case-p c)) (write-char #\- stream))
       do (write-char (char-upcase c) stream))))

(defun g-name->name (name)
  (or (second (assoc name *lisp-name-exceptions* :test 'equal))
      (intern (string-upcase (lispify-name name)) *lisp-name-package*)))

(defun property->property-definition (class-name property)
  (let ((name (g-name->name (g-class-property-definition-name property)))
        (accessor-name (accessor-name class-name (g-class-property-definition-name property)))
        (g-name (g-class-property-definition-name property))
        (type (g-type-name (g-class-property-definition-type property)))
        (readable (g-class-property-definition-readable property))
        (writable (and (g-class-property-definition-writable property)
                       (not (g-class-property-definition-constructor-only property)))))
    `(,name ,accessor-name ,g-name ,type ,readable ,writable)))

(defun get-g-class-definition (type)
  (let* ((g-type (ensure-g-type type))
         (g-name (g-type-name g-type))
         (name (g-name->name g-name))
         (superclass-g-type (g-type-parent g-type))
         (superclass-name (g-name->name (g-type-name superclass-g-type)))
         (interfaces (g-type-interfaces g-type))
         (properties (class-properties g-type))
         (own-properties
          (remove-if-not (lambda (property)
                           (= g-type
                              (g-class-property-definition-owner-type property)))
                         properties)))
    `(define-g-object-class ,g-name ,name (,superclass-name t) (,@(mapcar #'g-type-name interfaces))
       ,@(mapcar (lambda (property)
                   (property->property-definition name property))
                 own-properties))))

(defun get-g-interface-definition (interface)
  (let* ((type (ensure-g-type interface))
         (g-name (g-type-name type))
         (name (g-name->name g-name))
         (properties (interface-properties type)))
    `(define-g-interface ,g-name ,name (t)
       ,@(mapcar (lambda (property)
                   (property->property-definition name property))
                 properties))))

(defun get-g-class-definitions-for-root-1 (type)
  (unless (member (ensure-g-type type) *generation-exclusions* :test '=)
    (cons (get-g-class-definition type)
          (reduce #'append
                  (mapcar #'get-g-class-definitions-for-root-1
                          (g-type-children type))))))

(defun get-g-class-definitions-for-root (type)
  (setf type (ensure-g-type type))
  (get-g-class-definitions-for-root-1 type))

(defvar *referenced-types*)

(defun class-or-interface-properties (type)
  (setf type (ensure-g-type type))
  (cond 
    ((= (g-type-fundamental type) +g-type-object+) (class-properties type))
    ((= (g-type-fundamental type) +g-type-interface+) (interface-properties type))))

(defun get-shallow-referenced-types (type)
  (setf type (ensure-g-type type))
  (remove-duplicates (sort (loop
                              for property in (class-or-interface-properties type)
                              when (= type (g-class-property-definition-owner-type property))
                              collect (g-class-property-definition-type property))
                           #'<)
                     :test 'equal))

(defun get-referenced-types-1 (type)
  (setf type (ensure-g-type type))
  (loop
     for property-type in (get-shallow-referenced-types type)
     do (pushnew property-type *referenced-types* :test '=))
  (loop
     for type in (g-type-children type)
     do (get-referenced-types-1 type)))

(defun get-referenced-types (root-type)
  (let (*referenced-types*)
    (get-referenced-types-1 (ensure-g-type root-type))
    *referenced-types*))

(defun filter-types-by-prefix (types prefix)
  (remove-if-not
   (lambda (type)
     (starts-with (g-type-name (ensure-g-type type)) prefix))
   types))

(defun filter-types-by-fund-type (types fund-type)
  (setf fund-type (ensure-g-type fund-type))
  (remove-if-not
   (lambda (type)
     (equal (g-type-fundamental (ensure-g-type type)) fund-type))
   types))

(defmacro define-g-enum (g-name name (&optional (export t)) &body values)
  `(progn
     (defcenum ,name ,@values)
     (register-enum-type ,g-name ',name)
     ,@(when export
             (list `(export ',name (find-package ,(package-name (symbol-package name))))))))

(defun enum-value->definition (enum-value)
  (let ((value-name (intern (lispify-name (enum-item-nick enum-value))
                            (find-package :keyword)))
        (numeric-value (enum-item-value enum-value)))
    `(,value-name ,numeric-value)))

(defun get-g-enum-definition (type)
  (let* ((g-type (ensure-g-type type))
         (g-name (g-type-name g-type))
         (name (g-name->name g-name))
         (items (get-enum-items g-type)))
    `(define-g-enum ,g-name ,name (t) ,@(mapcar #'enum-value->definition items))))

(defmacro define-g-flags (g-name name (&optional (export t)) &body values)
  `(progn
     (defbitfield ,name ,@values)
     (register-enum-type ,g-name ',name)
     ,@(when export
             (list `(export ',name (find-package ,(package-name (symbol-package name))))))))

(defun flags-value->definition (flags-value)
  (let ((value-name (intern (lispify-name (flags-item-nick flags-value))
                            (find-package :keyword)))
        (numeric-value (flags-item-value flags-value)))
    `(,value-name ,numeric-value)))

(defun get-g-flags-definition (type)
  (let* ((g-type (ensure-g-type type))
         (g-name (g-type-name g-type))
         (name (g-name->name g-name))
         (items (get-flags-items g-type)))
    `(define-g-flags ,g-name ,name (t) ,@(mapcar #'flags-value->definition items))))

(defun generate-types-hierarchy-to-file (file root-type &key include-referenced prefix package exceptions prologue interfaces enums flags objects exclusions)
  (if (not (streamp file))
      (with-open-file (stream file :direction :output :if-exists :supersede)
        (generate-types-hierarchy-to-file stream root-type
                                          :prefix prefix
                                          :package package
                                          :exceptions exceptions
                                          :prologue prologue
                                          :include-referenced include-referenced
                                          :interfaces interfaces
                                          :enums enums
                                          :flags flags
                                          :objects objects
                                          :exclusions exclusions))
      (let* ((*generation-exclusions* (mapcar #'ensure-g-type exclusions))
             (*lisp-name-package* (or package *package*))
             (*package* *lisp-name-package*)
             (*strip-prefix* (or prefix ""))
             (*lisp-name-exceptions* exceptions)
             (*print-case* :downcase)
             (referenced-types (and include-referenced
                                    (filter-types-by-prefix
                                     (get-referenced-types root-type)
                                     prefix))))
        (setf exclusions (mapcar #'ensure-g-type exclusions))
        (when prologue
          (write-string prologue file)
          (terpri file))
        (when include-referenced
          (loop
             for interface in interfaces
             do (loop
                   for referenced-type in (get-shallow-referenced-types interface)
                   do (pushnew referenced-type referenced-types :test 'equal)))
          (loop
             for object in objects
             do (loop
                   for referenced-type in (get-shallow-referenced-types object)
                   do (pushnew referenced-type referenced-types :test 'equal)))
          (loop
             for enum-type in (filter-types-by-fund-type
                               referenced-types "GEnum")
             for def = (get-g-enum-definition enum-type)
             unless (member (ensure-g-type enum-type) exclusions :test '=)
             do (format file "~S~%~%" def))
            
          (loop
             for flags-type in (filter-types-by-fund-type
                                referenced-types "GFlags")
             for def = (get-g-flags-definition flags-type)
             unless (member (ensure-g-type flags-type) exclusions :test '=)
             do (format file "~S~%~%" def)))
        (loop
           with auto-enums = (and include-referenced
                                  (filter-types-by-fund-type
                                   referenced-types "GEnum"))
           for enum in enums
           for def = (get-g-enum-definition enum)
           unless (find (ensure-g-type enum) auto-enums :test 'equal)
           do (format file "~S~%~%" def))
        (loop
           with auto-flags = (and include-referenced
                                  (filter-types-by-fund-type
                                   referenced-types "GFlags"))
           for flags-type in flags
           for def = (get-g-flags-definition flags-type)
           unless (find (ensure-g-type flags-type) auto-flags :test 'equal)
           do (format file "~S~%~%" def))
        (loop
           for interface in interfaces
           for def = (get-g-interface-definition interface)
           do (format file "~S~%~%" def))
        (loop
           for def in (get-g-class-definitions-for-root root-type)
           do (format file "~S~%~%" def))
        (loop
           for object in objects
           for def = (get-g-class-definition object)
           do (format file "~S~%~%" def)))))