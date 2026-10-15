;;;; Stand-ins for vivace-graph's buffer pool (buffer-pool.lisp at
;;;; 853df62), which only runs inside an open graph; without it these are
;;;; exactly what vivace-graph's functions return.

(in-package #:vivace-cabinet)

(defun get-buffer (size)
  "A fresh byte vector of SIZE."
  (make-byte-vector size))

(defun get-skip-node-buffer ()
  "A fresh skip-list node (defined in structures/skip-list.lisp)."
  (%make-skip-node))
