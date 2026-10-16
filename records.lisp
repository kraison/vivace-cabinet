;;;; Key/value records in the heap: [next u64][key length u64][value
;;;; length u64][key][value].  NEXT chains records whose keys share a
;;;; digest (spec: HashDB).

(in-package #:vivace-cabinet)

(alexandria:define-constant +record-header-bytes+ 24)

(defun write-record (heap key value next)
  "Allocate a record holding KEY and VALUE (octets) linked to NEXT;
return its address."
  (let* ((klen (length key))
         (vlen (length value))
         (addr (allocate heap (+ +record-header-bytes+ klen vlen))))
    (serialize-uint64 heap next addr)
    (serialize-uint64 heap klen (+ addr 8))
    (serialize-uint64 heap vlen (+ addr 16))
    (set-bytes heap key (+ addr +record-header-bytes+) klen)
    (set-bytes heap value (+ addr +record-header-bytes+ klen) vlen)
    addr))

(defun record-next (heap addr)
  (deserialize-uint64 heap addr))

(defun (setf record-next) (next heap addr)
  (serialize-uint64 heap next addr)
  next)

(defun record-key-length (heap addr)
  (deserialize-uint64 heap (+ addr 8)))

(defun record-value-length (heap addr)
  (deserialize-uint64 heap (+ addr 16)))

(defun record-key (heap addr)
  (get-bytes heap (+ addr +record-header-bytes+)
             (record-key-length heap addr)))

(defun record-value (heap addr)
  (get-bytes heap
             (+ addr +record-header-bytes+ (record-key-length heap addr))
             (record-value-length heap addr)))

(defun record-key= (heap addr key)
  "True when the record at ADDR holds KEY."
  (and (= (length key) (record-key-length heap addr))
       (equalp key (record-key heap addr))))

(defun free-record (heap addr)
  (free heap addr))
