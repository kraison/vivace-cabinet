;;;; Transactions: in version 1 every call signals (spec: API; unit 4).

(in-package #:vivace-cabinet)

(defun %no-transactions ()
  (%signal 'transactions-not-implemented
           "transactions are not implemented in version 1"))

(defmethod db-begin-transaction ((db database) &key hard)
  (declare (ignore hard))
  (%no-transactions))

(defmethod db-begin-transaction-try ((db database) &key hard)
  (declare (ignore hard))
  (%no-transactions))

(defmethod db-end-transaction ((db database) &key commit)
  (declare (ignore commit))
  (%no-transactions))
