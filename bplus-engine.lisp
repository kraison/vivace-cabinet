;;;; TreeDB's default engine: the B+ tree.  Keys sit in the pages; a value
;;;; sits there too when it and its key fit a quarter page, else in a heap
;;;; record the page points to.  So every cell fits a quarter page and a
;;;; full page always splits into two that fit (spec: TreeDB; #4).

(in-package #:vivace-cabinet)

(defclass bplus-engine ()
  ((tree :initarg :tree :reader %bpe-tree)
   (heap :initarg :heap :reader %bpe-heap)))

(defun %bpe-tree-args (less)
  (list :key-comparison less :key-equal (%equal-under less)
        :value-equal 'equalp
        :key-serializer 'identity :key-deserializer 'identity
        :value-serializer 'identity :value-deserializer 'identity))

(defun make-bplus-engine (heap &key (less 'octets<) (page-size 4096))
  (make-instance 'bplus-engine
                 :heap heap
                 :tree (apply #'make-bplus-tree :heap heap
                              :page-size page-size (%bpe-tree-args less))))

(defun open-bplus-engine (heap address &key (less 'octets<))
  (make-instance 'bplus-engine
                 :heap heap
                 :tree (apply #'open-bplus-tree :heap heap :address address
                              (%bpe-tree-args less))))

(defun %bpe-quarter (e)
  (floor (%bpt-page-size (%bpe-tree e)) 4))

(defun %bpe-encode (e key value)
  "VALUE's leaf bytes: 0 and the value, or 1 and the address of a heap
record holding it when KEY and VALUE together exceed a quarter page."
  (if (<= (+ (length key) (length value)) (%bpe-quarter e))
      (let ((v (make-array (1+ (length value))
                           :element-type '(unsigned-byte 8))))
        (setf (aref v 0) 0)
        (replace v value :start1 1))
      (let ((v (make-array 9 :element-type '(unsigned-byte 8)
                             :initial-element 1))
            (addr (write-record (%bpe-heap e)
                                (make-array 0 :element-type
                                            '(unsigned-byte 8))
                                value 0)))
        (dotimes (i 8 v)
          (setf (aref v (1+ i)) (ldb (byte 8 (* 8 i)) addr))))))

(defun %bpe-record (sval)
  "The heap record address in leaf bytes SVAL, or NIL for an inline value."
  (when (= 1 (aref sval 0))
    (let ((addr 0))
      (dotimes (i 8 addr)
        (setf addr (logior addr (ash (aref sval (1+ i)) (* 8 i))))))))

(defun %bpe-decode (e sval)
  (let ((addr (%bpe-record sval)))
    (if addr
        (record-value (%bpe-heap e) addr)
        (subseq sval 1))))

(defun %bpe-free (e sval)
  "Free the heap record leaf bytes SVAL point to, if any."
  (let ((addr (and sval (%bpe-record sval))))
    (when addr
      (free-record (%bpe-heap e) addr))))

;;; Ordered lookups in the leaves; the caller holds the tree's lock.

(defun %bpt-entry-at (buf idx)
  "The key and value bytes of leaf slot IDX in BUF."
  (let* ((slot (%bpt-slot-off buf idx))
         (klen (buf-u16 buf slot)))
    (values (subseq buf (+ slot 2) (+ slot 2 klen))
            (%bpt-cell-sval buf slot))))

(defun %bpt-ceiling (tree key strict)
  "The first leaf entry at or after KEY (after it when STRICT), or the
first entry when KEY is NIL, as (values key value-bytes); NIL past the
end."
  (multiple-value-bind (buf count link idx)
      (if key
          (%bpt-leaf-at tree key)
          (multiple-value-bind (b c l) (%bpt-leftmost-leaf tree)
            (values b c l 0)))
    (when (and key strict (< idx count)
               (bpt-key= tree key
                         (%bpt-slot-key tree buf (%bpt-slot-off buf idx))))
      (incf idx))
    (loop while (and (>= idx count) (/= link 0))
          do (setf buf (%bpt-read-page tree link buf)
                   count (buf-u16 buf +bpt-p-count-offset+)
                   link (buf-u64 buf +bpt-p-link-offset+)
                   idx 0))
    (when (< idx count)
      (%bpt-entry-at buf idx))))

(defun %bpt-rightmost-leaf (tree addr)
  "The last leaf under the page at ADDR."
  (let ((buf nil))
    (loop
      (setf buf (%bpt-read-page tree addr buf))
      (when (%bpt-leaf-p buf)
        (return buf))
      (let ((n (buf-u16 buf +bpt-p-count-offset+)))
        (setf addr (if (zerop n)
                       (buf-u64 buf +bpt-p-link-offset+)
                       (%bpt-slot-child buf (1- n))))))))

(defun %bpt-last-entry (buf)
  (let ((n (buf-u16 buf +bpt-p-count-offset+)))
    (when (plusp n)
      (%bpt-entry-at buf (1- n)))))

(defun %bpt-floor (tree key strict)
  "The last leaf entry at or before KEY (before it when STRICT), or the
last entry when KEY is NIL, as (values key value-bytes); NIL before the
start.  Leaves link forward only, so the descent remembers the subtree
just left of its path."
  (if (null key)
      (%bpt-last-entry (%bpt-rightmost-leaf tree (%bpt-root tree)))
      (let ((addr (%bpt-root tree))
            (buf nil)
            (left nil))
        (loop
          (setf buf (%bpt-read-page tree addr buf))
          (when (%bpt-leaf-p buf)
            (return))
          (let ((idx (%bpt-page-bsearch tree buf
                                        (buf-u16 buf +bpt-p-count-offset+)
                                        key)))
            (cond ((> idx 0) (setf left (%bpt-slot-child buf (1- idx))))
                  ((= idx 0) (setf left (buf-u64 buf +bpt-p-link-offset+))))
            (setf addr (if (< idx 0)
                           (buf-u64 buf +bpt-p-link-offset+)
                           (%bpt-slot-child buf idx)))))
        (multiple-value-bind (idx exact)
            (%bpt-page-bsearch tree buf (buf-u16 buf +bpt-p-count-offset+)
                               key)
          (when (and exact strict)
            (decf idx))
          (cond ((>= idx 0) (%bpt-entry-at buf idx))
                (left (%bpt-last-entry (%bpt-rightmost-leaf tree left))))))))

;;; The engine protocol

(defmethod engine-get ((e bplus-engine) key)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (sval found) (%bpt-find tree key)
        (and found (%bpe-decode e sval))))))

(defmethod engine-put ((e bplus-engine) key value)
  (when (> (length key) (%bpe-quarter e))
    (%signal 'key-too-long "a ~d-byte key; the B+ tree's limit is ~d"
             (length key) (%bpe-quarter e)))
  (let ((tree (%bpe-tree e))
        (sval (%bpe-encode e key value))
        (old nil))
    (with-bpt-write-lock (tree)
      (multiple-value-bind (osval found) (%bpt-find tree key)
        (when found
          (setf old osval)
          (%bpt-remove-top tree key)))
      (%bpt-insert-top tree key key sval))
    (%bpe-free e old)
    t))

(defmethod engine-delete ((e bplus-engine) key)
  (let ((tree (%bpe-tree e))
        (old nil))
    (with-bpt-write-lock (tree)
      (multiple-value-bind (osval found) (%bpt-find tree key)
        (when found
          (setf old osval)
          (%bpt-remove-top tree key))))
    (when old
      (%bpe-free e old)
      t)))

(defmethod engine-count ((e bplus-engine))
  (bplus-tree-count (%bpe-tree e)))

(defmethod engine-ceiling ((e bplus-engine) key strict)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (k sval) (%bpt-ceiling tree key strict)
        (and k (values k (%bpe-decode e sval)))))))

(defmethod engine-floor ((e bplus-engine) key strict)
  (let ((tree (%bpe-tree e)))
    (with-bpt-read-lock (tree)
      (multiple-value-bind (k sval) (%bpt-floor tree key strict)
        (and k (values k (%bpe-decode e sval)))))))

(defmethod engine-address ((e bplus-engine))
  (%bpt-address (%bpe-tree e)))

(defmethod engine-close ((e bplus-engine))
  (close-bplus-tree (%bpe-tree e)))
