;;;; Keys matching a prefix, a regular expression, or within an edit
;;;; distance (spec: API).  A TreeDB in unsigned byte order jumps to a
;;;; prefix; anything else walks every key, as Kyoto Cabinet's PolyDB
;;;; does (kcpolydb.h: match_prefix, match_regex, match_similar).

(in-package #:vivace-cabinet)

(defun %prefix-p (prefix key)
  (and (<= (length prefix) (length key))
       (not (mismatch prefix key :end2 (length prefix)))))

(defun %byte-ordered-p (db)
  "True when DB keeps its keys in unsigned byte order."
  (and (typep db 'tree-db)
       (eq 'octets< (getf (%db-tuning db) :comparator))))

(defun %walk-cursor (db fn &optional from)
  "Call FN with each key a cursor on DB reaches, from FROM (a jump) or
the first record, until FN returns :STOP."
  (with-cursor (cur db)
    (when (cursor-jump cur from)
      (loop for k = (cursor-get-key cur :step t)
            while (and k (not (eq :stop (funcall fn k))))))))

(defun %key-text (k)
  (babel:octets-to-string k :encoding :utf-8 :errorp nil))

(defmethod db-match-prefix ((db database) prefix &key max (as :octets))
  (check-as as)
  (let ((p (to-octets prefix))
        (ordered (%byte-ordered-p db))
        (found '())
        (n 0))
    (%walk-cursor db (lambda (k)
                       (cond ((and max (>= n max)) :stop)
                             ((%prefix-p p k) (push k found) (incf n) nil)
                             (ordered :stop)))
                  (and ordered p))
    (mapcar (lambda (k) (from-octets k as)) (nreverse found))))

(defmethod db-match-regex ((db database) regex &key max (as :octets))
  (check-as as)
  (let ((scanner (handler-case (cl-ppcre:create-scanner regex)
                   (cl-ppcre:ppcre-syntax-error (c)
                     (%signal 'invalid-argument
                              "bad regular expression ~s: ~a" regex c))))
        (found '())
        (n 0))
    (%walk-cursor db (lambda (k)
                       (cond ((and max (>= n max)) :stop)
                             ((cl-ppcre:scan scanner (%key-text k))
                              (push k found)
                              (incf n)
                              nil))))
    (mapcar (lambda (k) (from-octets k as)) (nreverse found))))

(defun %edit-distance (a b)
  "The Levenshtein distance between vectors A and B."
  (let* ((n (length b))
         (prev (make-array (1+ n)))
         (curr (make-array (1+ n))))
    (dotimes (j (1+ n))
      (setf (aref prev j) j))
    (dotimes (i (length a) (aref prev n))
      (setf (aref curr 0) (1+ i))
      (dotimes (j n)
        (setf (aref curr (1+ j))
              (min (1+ (aref prev (1+ j)))
                   (1+ (aref curr j))
                   (+ (aref prev j) (if (eql (aref a i) (aref b j)) 0 1)))))
      (rotatef prev curr))))

(defun %code-points (octets)
  (map 'vector #'char-code (%key-text octets)))

(defmethod db-match-similar ((db database) origin range &key utf max
                                                              (as :octets))
  (check-as as)
  (unless (typep range '(integer 0))
    (%signal 'invalid-argument "RANGE must be a natural number: ~s" range))
  (let* ((o (to-octets origin))
         (oseq (if utf (%code-points o) o))
         (hits '())
         (order 0))
    (%walk-cursor db (lambda (k)
                       (let* ((kseq (if utf (%code-points k) k))
                              (d (and (<= (abs (- (length oseq)
                                                  (length kseq)))
                                          range)
                                      (%edit-distance oseq kseq))))
                         (when (and d (<= d range))
                           (push (list d k order) hits))
                         (incf order)
                         nil)))
    (let ((sorted (sort hits (lambda (x y)
                               (cond ((/= (first x) (first y))
                                      (< (first x) (first y)))
                                     ((octets< (second x) (second y)) t)
                                     ((octets< (second y) (second x)) nil)
                                     (t (< (third x) (third y))))))))
      (mapcar (lambda (h) (from-octets (second h) as))
              (if max
                  (subseq sorted 0 (min max (length sorted)))
                  sorted)))))
