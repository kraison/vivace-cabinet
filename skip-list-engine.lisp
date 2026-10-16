;;;; TreeDB's skip-list engine: each record a heap node of any size (spec:
;;;; TreeDB).  Keys are stored after a 4-byte length.  The list caches and
;;;; returns the vectors it was given, so the engine keeps and hands out
;;;; copies.

(in-package #:vivace-cabinet)

(defclass skip-list-engine ()
  ((sl :initarg :sl :reader %sle-list)))

(defun %sle-encode-key (key)
  "KEY as a 4-byte little-endian length and its octets.  The head and
tail sentinels' key, :END, is length #xFFFFFFFF, which no key can have."
  (let* ((end (eq key :end))
         (n (if end 0 (length key)))
         (v (make-array (+ 4 n) :element-type '(unsigned-byte 8))))
    (dotimes (i 4)
      (setf (aref v i) (if end 255 (ldb (byte 8 (* 8 i)) n))))
    (unless end
      (replace v key :start1 4))
    v))

(defun %sle-decode-key (bytes)
  "The key at the start of BYTES, and the bytes it took."
  (let ((n (logior (aref bytes 0) (ash (aref bytes 1) 8)
                   (ash (aref bytes 2) 16) (ash (aref bytes 3) 24))))
    (if (= n #xFFFFFFFF)
        (values :end 4)
        (values (subseq bytes 4 (+ 4 n)) (+ 4 n)))))

(defun %sle-key-equal (less)
  "Key equality under LESS.  The list's search tests its tail against
the key, so the sentinels' :END must never match, not even an empty key."
  (let ((equal (%equal-under less)))
    (lambda (a b)
      (and (not (eq a :end)) (not (eq b :end)) (funcall equal a b)))))

(defun %sle-args (less)
  (list :key-equal (%sle-key-equal less) :key-comparison less
        :key-serializer '%sle-encode-key :key-deserializer '%sle-decode-key
        :value-serializer 'identity :value-deserializer 'identity
        :duplicates-allowed-p nil :value-equal 'equalp))

(defun make-skip-list-engine (heap &key (less 'octets<))
  (let ((none (make-array 0 :element-type '(unsigned-byte 8))))
    (make-instance 'skip-list-engine
                   :sl (apply #'make-skip-list :heap heap
                              :head-key :end :head-value none
                              :tail-key :end :tail-value none
                              (%sle-args less)))))

(defun open-skip-list-engine (heap address &key (less 'octets<))
  (make-instance 'skip-list-engine
                 :sl (apply #'open-skip-list :heap heap :address address
                            (%sle-args less))))

(defun %sle-copies (node)
  "Copies of NODE's key and value, as (values key value)."
  (values (copy-seq (%sn-key node)) (copy-seq (%sn-value node))))

(defun %sle-real-p (sl node)
  "True unless NODE is NIL or SL's head or tail."
  (and node
       (/= (%sn-addr node) (%sl-head-pointer sl))
       (/= (%sn-addr node) (%sl-tail-pointer sl))))

(defun %sle-search (sl key)
  "KEY's level-0 predecessor and successor in SL."
  (let ((preds (make-array (%sl-max-level sl)))
        (succs (make-array (%sl-max-level sl))))
    (%find-in-skip-list sl key preds succs)
    (values (aref preds 0) (aref succs 0))))

(defun %sle-last (sl)
  "SL's last node, or its head when SL is empty: descend each level
until the next node is the tail."
  (let ((pred (%sl-head sl))
        (tail (%sl-tail-pointer sl)))
    (loop for level from (1- (%sl-max-level sl)) downto 0
          do (loop for next = (aref (%sn-pointers pred) level)
                   until (= next tail)
                   do (setf pred (read-skip-node sl next))))
    pred))

(defmethod engine-get ((e skip-list-engine) key)
  (let ((node (%find-in-skip-list (%sle-list e) key)))
    (and node (copy-seq (%sn-value node)))))

(defmethod engine-put ((e skip-list-engine) key value)
  (let ((sl (%sle-list e))
        (k (copy-seq key)))
    (when (%find-in-skip-list sl k)
      (remove-from-skip-list sl k))
    (unless (add-to-skip-list sl k (copy-seq value))
      (error "skip list: a removed key is still present: ~s" k))
    t))

(defmethod engine-delete ((e skip-list-engine) key)
  (remove-from-skip-list (%sle-list e) key))

(defmethod engine-count ((e skip-list-engine))
  (%sl-length (%sle-list e)))

(defmethod engine-ceiling ((e skip-list-engine) key strict)
  (let* ((sl (%sle-list e))
         (node (if key
                   (nth-value 1 (%sle-search sl key))
                   (node-forward sl (%sl-head sl)))))
    (when (and key strict (%sle-real-p sl node)
               (funcall (%sl-key-equal sl) key (%sn-key node)))
      (setf node (node-forward sl node)))
    (when (%sle-real-p sl node)
      (%sle-copies node))))

(defmethod engine-floor ((e skip-list-engine) key strict)
  (let* ((sl (%sle-list e))
         (node (if key
                   (multiple-value-bind (pred succ) (%sle-search sl key)
                     (if (and (not strict) (%sle-real-p sl succ)
                              (funcall (%sl-key-equal sl) key
                                       (%sn-key succ)))
                         succ
                         pred))
                   (%sle-last sl))))
    (when (%sle-real-p sl node)
      (%sle-copies node))))

(defmethod engine-address ((e skip-list-engine))
  (%sl-address (%sle-list e)))

(defmethod engine-close ((e skip-list-engine))
  (close-skip-list (%sle-list e)))
