(in-package #:vivace-cabinet-test)

(def-suite admin-suite
  :description "Copying and merging that are not per kind."
  :in vivace-cabinet-suite)

(in-suite admin-suite)

(defun sorted-records (db)
  "DB's records as (key . value) strings, in key order."
  (let ((rs '()))
    (db-iterate db (lambda (k v) (push (cons k v) rs) :nop)
                :writable nil :as :string)
    (sort rs #'string< :key #'car)))

(def-db-test status-describes-the-database
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((s (db-status db)))
      (is (eq (getf *db-type-args* :type) (getf s :type)))
      (is (= 1 (getf s :count)))
      (is (= (db-size db) (getf s :size)))
      (is (equal (db-path db) (getf s :path)))
      (is (eq t (getf s :writable)))
      (is (null (getf s :autosync)))
      (if (eq :tree (getf s :type))
          (is (eq (getf *db-type-args* :engine) (getf s :engine)))
          (is (plusp (getf s :buckets)))))))

(def-db-test occupy-runs-with-the-database-held
  (with-temp-db (db)
    (db-set db "k" "v")
    (let ((args nil))
      (is-true (db-occupy db (lambda (path count size)
                               (setf args (list path count size))
                               t)))
      (is (equal (list (db-path db) 1 (db-size db)) args)))
    (is (null (db-occupy db (lambda (&rest r) (declare (ignore r)) nil)
                         :writable nil)))
    (is (eq :logic (db-error db)))))

(def-db-test copy-makes-a-database-of-its-own
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "o.vc/" dir))
          (copy (merge-pathnames "c.vc/" dir)))
      (with-test-db (db path)
        (dotimes (i 200)
          (db-set db (keyed i) (keyed i)))
        (is-true (db-copy db copy))
        (signals invalid-argument (db-copy db copy))
        (db-set db "after" "copy"))
      (with-db (c copy)
        (is (= 200 (db-count c)))
        (is (equal (keyed 7) (db-get c (keyed 7) :as :string)))
        (is (null (db-get c "after")))
        (is (eq (getf *db-type-args* :type) (getf (db-status c) :type)))))))

(defun file-lengths (dir)
  "The length of each file in DIR and DIR's index/, by name."
  (sort (loop for f in (append (uiop:directory-files dir)
                               (uiop:directory-files
                                (merge-pathnames "index/" dir)))
              collect (cons (enough-namestring f dir)
                            (with-open-file (s f :element-type
                                                 '(unsigned-byte 8))
                              (file-length s))))
        #'string< :key #'car))

(test copy-keeps-holes
  "The index's 1000 MiB sparse files stay sparse in a copy, and every
file keeps its length, those that end in a hole too."
  (with-temp-directory (dir)
    (let ((orig (merge-pathnames "o.vch/" dir))
          (copy (merge-pathnames "c.vch/" dir)))
      (with-db (db orig)
        (db-set db "k" "v")
        (db-copy db copy)
        (is (equal (file-lengths orig) (file-lengths copy))))
      (let ((kb (parse-integer
                 (uiop:run-program
                  (list "du" "-k" (namestring
                                   (merge-pathnames "index/table.dat" copy)))
                  :output '(:string :stripped t))
                 :junk-allowed t)))
        (is (< kb 10240) "~a KiB on disk" kb)))))

(defun file-modes (dir)
  "Each file's mode in DIR and DIR's index/, by name."
  (sort (loop for f in (append (uiop:directory-files dir)
                               (uiop:directory-files
                                (merge-pathnames "index/" dir)))
              collect (cons (enough-namestring f dir) (%file-mode f)))
        #'string< :key #'car))

(test copy-keeps-file-modes
  "The copy's files have the source's modes (#8): the mapped files'
0640, and whatever a file was given since."
  (with-temp-directory (dir)
    (let ((orig (merge-pathnames "o.vch/" dir))
          (copy (merge-pathnames "c.vch/" dir)))
      (with-db (db orig)
        (db-set db "k" "v")
        (uiop:run-program
         (list "chmod" "600" (uiop:native-namestring
                              (merge-pathnames "heap.dat" orig))))
        (db-copy db copy)
        (is (equal (file-modes orig) (file-modes copy)))
        (is (= #o600 (cdr (assoc "heap.dat" (file-modes copy)
                                 :test #'equal))))
        (is (= #o640 (cdr (assoc "index/table.dat" (file-modes copy)
                                 :test #'equal))))))))

(test copy-reads-only-the-data
  "Copying a sparse file reads its data, not its holes (#8): 1000 MiB
of holes around two 4 KiB blocks cost about the blocks."
  (with-temp-directory (dir)
    (let ((from (merge-pathnames "sparse" dir))
          (to (merge-pathnames "copy" dir))
          (size (* 1000 1024 1024))
          (block (make-array 4096 :element-type '(unsigned-byte 8)
                                  :initial-element 7)))
      (with-open-file (out from :direction :output
                                :element-type '(unsigned-byte 8))
        (write-sequence block out)
        (file-position out (- size 4096))
        (write-sequence block out))
      (let ((bytes (%copy-sparse from to)))
        (is (< bytes (* 1024 1024)) "~d bytes read" bytes))
      (with-open-file (in to :element-type '(unsigned-byte 8))
        (is (= size (file-length in)))
        (let ((got (make-array 4096 :element-type '(unsigned-byte 8))))
          (read-sequence got in)
          (is (equalp block got))
          (file-position in (floor size 2))
          (is (zerop (read-byte in)))
          (file-position in (- size 4096))
          (read-sequence got in)
          (is (equalp block got)))))))

(defun chmod-files (dir mode)
  "chmod every file under DIR to MODE, a string."
  (uiop:run-program (list "find" (uiop:native-namestring dir) "-type" "f"
                          "-exec" "chmod" mode "{}" "+")))

(def-db-test copy-of-files-without-owner-write
  "A writable database whose files lost owner write (0440) still copies:
the copy's files are 0440 too and its header says closed with the
count, since the copy writes that header while copying it, rewriting
and reopening nothing (#8)."
  (with-temp-directory (dir)
    (let ((orig (merge-pathnames "o.vc/" dir))
          (copy (merge-pathnames "c.vc/" dir)))
      (with-test-db (db orig)
        (dotimes (i 20)
          (db-set db (keyed i) "v"))
        (chmod-files orig "440")
        (unwind-protect
             (progn
               (is-true (db-copy db copy))
               (is (equal (file-modes orig) (file-modes copy)))
               (is (= #o440 (cdr (assoc "header.dat" (file-modes copy)
                                        :test #'equal))))
               (let ((header (%read-header copy)))
                 (is (null (getf header :open)))
                 (is (= 20 (getf header :count)))))
          ;; The writer must write its header to close.
          (chmod-files orig "640")))
      (chmod-files copy "640")
      (with-db (c copy)
        (is (= 20 (db-count c)))
        (is (equal "v" (db-get c (keyed 3) :as :string)))))))

(def-db-test copy-turns-a-sync-failure-into-system-error
  "A FILE-ERROR from synchronizing the database before the copy signals
SYSTEM-ERROR, like one from the copy itself (#8)."
  (with-temp-directory (dir)
    (with-test-db (db (merge-pathnames "o.vc/" dir))
      (db-set db "k" "v")
      (let ((method (defmethod %sync-storage :around ((d database) hard)
                      (declare (ignore hard))
                      (if (eq d db)
                          (error 'file-error :pathname (db-path d))
                          (call-next-method)))))
        (unwind-protect
             (signals system-error
               (db-copy db (merge-pathnames "c.vc/" dir)))
          (remove-method #'%sync-storage method)))
      (is-true (db-copy db (merge-pathnames "c.vc/" dir))))))

(def-db-test merge-modes
  "Each mode stores a source's records as its operation would."
  (with-temp-directory (dir)
    (with-test-db (src (merge-pathnames "s.vc/" dir))
      (db-set src "y" "b")
      (db-set src "z" "b")
      (dolist (case '((:set ("x" . "a") ("y" . "b") ("z" . "b"))
                      (:add ("x" . "a") ("y" . "a") ("z" . "b"))
                      (:replace ("x" . "a") ("y" . "b"))
                      (:append ("x" . "a") ("y" . "ab") ("z" . "b"))))
        (with-test-db (m (merge-pathnames
                          (format nil "m-~(~a~).vc/" (first case)) dir))
          (db-set m "x" "a")
          (db-set m "y" "a")
          (is-true (db-merge m (list src) :mode (first case)))
          (is (equal (rest case) (sorted-records m)))))
      (signals invalid-argument (db-merge src (list src)))
      (signals invalid-argument (db-merge src '() :mode :bogus)))))

(test merge-across-types
  "A HashDB merges into a TreeDB, which then holds the records in order."
  (with-temp-directory (dir)
    (with-db (h (merge-pathnames "h.vch/" dir))
      (dolist (k '("c" "a" "b"))
        (db-set h k k))
      (with-db (tr (merge-pathnames "t.vct/" dir) :type :tree)
        (is-true (db-merge tr (list h)))
        (is (equal '("a" "b" "c") (db-match-prefix tr "" :as :string)))))))

(def-db-test occupy-holds-the-database
  "A write started inside a writable DB-OCCUPY lands only after it."
  (with-temp-db (db)
    (let ((writer nil)
          (inside 0)
          (written 0))
      (is-true (db-occupy db (lambda (path count size)
                               (declare (ignore path count size))
                               (setf writer
                                     (bt:make-thread
                                      (lambda ()
                                        (db-set db "late" "x")
                                        (setf written
                                              (get-internal-real-time)))))
                               (sleep 0.3)
                               (setf inside (get-internal-real-time))
                               t)))
      (bt:join-thread writer)
      (is (>= written inside))
      (is (equal "x" (db-get db "late" :as :string))))))

(def-db-test copy-holds-the-database
  "Other threads' writes wait while DB-COPY runs, so the copy's count is
the number of records it holds."
  (with-temp-directory (dir)
    (let ((copy (merge-pathnames "c.vc/" dir))
          (stop nil))
      (with-test-db (db (merge-pathnames "o.vc/" dir))
        (let ((writers
                (loop for w below 2
                      collect (let ((w w))
                                (bt:make-thread
                                 (lambda ()
                                   (loop for i from 0
                                         until stop
                                         do (db-set db (format nil "~d-~d" w i)
                                                    "v"))))))))
          (sleep 0.2)
          (unwind-protect (db-copy db copy)
            (setf stop t)
            (mapc #'bt:join-thread writers))))
      (with-db (c copy)
        (let ((n 0))
          (db-iterate c (lambda (k v)
                          (declare (ignore k v))
                          (incf n)
                          :nop)
                      :writable nil)
          (is (= n (db-count c))))))))

(def-db-test copy-refuses-a-place-inside-the-database
  "A copy into the database's own directory would copy itself without
end; it signals INVALID-ARGUMENT."
  (with-temp-db (db)
    (signals invalid-argument
      (db-copy db (merge-pathnames "bak/" (db-path db))))))

(def-db-test closed-databases-refuse-calls-with-no-parts
  "DB-MERGE with no sources, DB-LOAD-SNAPSHOT of an empty snapshot and
the bulk calls with no keys signal INVALID-ARGUMENT on a closed
database, as every call does (#8)."
  (with-temp-directory (dir)
    (let ((empty (merge-pathnames "empty.snap" dir))
          (db (open-test-db (merge-pathnames "c.vc/" dir))))
      (db-dump-snapshot db empty)
      (close-db db)
      (signals invalid-argument (db-merge db '()))
      (signals invalid-argument (db-load-snapshot db empty))
      (dolist (atomic '(t nil))
        (signals invalid-argument (db-set-bulk db '() :atomic atomic))
        (signals invalid-argument (db-get-bulk db '() :atomic atomic))
        (signals invalid-argument (db-remove-bulk db '() :atomic atomic))))))

(def-db-test readers-and-whole-database-calls
  "A reader refuses a writable DB-ITERATE, DB-MERGE and DB-LOAD-SNAPSHOT
with :NO-PERMISSION, iterates read-only, and copies into a database
that opens on its own."
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "r.vc/" dir))
          (snap (merge-pathnames "r.snap" dir))
          (copy (merge-pathnames "c.vc/" dir)))
      (with-test-db (db path)
        (dotimes (i 50)
          (db-set db (keyed i) "v"))
        (db-dump-snapshot db snap))
      (with-test-db (src (merge-pathnames "s.vc/" dir))
        (db-set src "s" "v")
        (with-test-db (db path :mode '(:reader))
          (is (null (db-iterate db (answer :remove))))
          (is (eq :no-permission (db-error db)))
          (is (null (db-merge db (list src))))
          (is (eq :no-permission (db-error db)))
          (is (null (db-load-snapshot db snap)))
          (is (eq :no-permission (db-error db)))
          (let ((n 0))
            (is-true (db-iterate db (lambda (k v)
                                      (declare (ignore k v))
                                      (incf n)
                                      :nop)
                                 :writable nil))
            (is (= 50 n)))
          (is-true (db-copy db copy))
          (is (= 50 (db-count db)))))
      (with-db (c copy)
        (is (= 50 (db-count c)))
        (is (equal "v" (db-get c (keyed 3) :as :string)))))))
