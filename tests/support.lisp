(in-package #:vivace-cabinet-test)

;;; Fixtures adapted from vivace-graph tests/suite.lisp at 853df62.

(defun make-temp-directory ()
  "A fresh, empty directory under the system temp directory."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "vivace-cabinet-test-~36r"
                       (random (expt 36 10) (make-random-state t)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-directory ((var) &body body)
  "Bind VAR to a fresh directory, run BODY, then delete the tree."
  `(let ((,var (make-temp-directory)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t
                                        :if-does-not-exist :ignore))))

(defmacro with-temp-memory ((var &key (size '(* 1024 1024 64))) &body body)
  "Bind VAR to a fresh MEMORY backed by a temp file, run BODY, then close
it and remove the directory."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (create-memory
                    (namestring (merge-pathnames "heap.dat" ,dir)) ,size)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-memory ,var)))))))

(defun gen-id ()
  "A random 16-byte key whose first byte is non-zero: all-zero keys mark
empty slots in the linear hash.  (vivace-graph used a v4 UUID.)"
  (let ((id (make-array 16 :element-type '(unsigned-byte 8))))
    (dotimes (i 16)
      (setf (aref id i) (random 256)))
    (setf (aref id 0) (1+ (random 255)))
    id))

(defmacro with-temp-lhash ((var &rest make-args) &body body)
  "Bind VAR to a fresh LHASH in a temp directory, run BODY, then close it
and remove the directory.  MAKE-ARGS go to MAKE-LHASH."
  (let ((dir (gensym "DIR")))
    `(with-temp-directory (,dir)
       (let ((,var (make-lhash :location ,dir ,@make-args)))
         (unwind-protect (progn ,@body)
           (ignore-errors (close-lhash ,var)))))))

(defun test-serialize (object)
  "OBJECT's printed form as UTF-8 after a 4-byte length.  A stand-in for
vivace-graph's serializer, which is not copied."
  (let* ((text (babel:string-to-octets (prin1-to-string object)
                                       :encoding :utf-8))
         (n (length text))
         (out (make-array (+ 4 n) :element-type '(unsigned-byte 8))))
    (setf (aref out 0) (ldb (byte 8 24) n)
          (aref out 1) (ldb (byte 8 16) n)
          (aref out 2) (ldb (byte 8 8) n)
          (aref out 3) (ldb (byte 8 0) n))
    (replace out text :start1 4)
    out))

(defun test-deserialize (octets)
  "The object TEST-SERIALIZE wrote at the start of OCTETS, and the number
of bytes it used."
  (let ((n (logior (ash (aref octets 0) 24) (ash (aref octets 1) 16)
                   (ash (aref octets 2) 8) (aref octets 3))))
    (values (let ((*read-eval* nil))
              (read-from-string
               (babel:octets-to-string octets :start 4 :end (+ 4 n)
                                              :encoding :utf-8)))
            (+ 4 n))))

(defun make-integer-skip-list (heap &key duplicates-allowed-p)
  "An integer-keyed skip list over HEAP, keys and values encoded by
TEST-SERIALIZE (vivace-graph used its general serializer here)."
  (make-skip-list :heap heap
                  :head-key most-negative-fixnum :head-value 0
                  :tail-key most-positive-fixnum :tail-value 0
                  :key-equal '= :key-comparison '<
                  :key-serializer 'test-serialize
                  :key-deserializer 'test-deserialize
                  :value-serializer 'test-serialize
                  :value-deserializer 'test-deserialize
                  :value-equal 'equal
                  :duplicates-allowed-p duplicates-allowed-p))
