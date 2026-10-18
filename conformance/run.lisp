;;;; Running a sequence on both databases and comparing each step.

(in-package #:vivace-cabinet-conformance)

(defparameter *kinds*
  '((:hash (:type :hash) "k.kch")
    (:bplus-tree (:type :tree :engine :bplus-tree) "k.kct")
    (:skip-list (:type :tree :engine :skip-list) "k.kct"))
  "Each kind compared: a name, vivace-cabinet's OPEN-DB arguments, and
the Kyoto file, whose extension picks the same database type.")

(defun sorted-octets (list)
  (sort (copy-list list) #'octets<))

(defun walk-keys (db)
  (with-cursor (c db)
    (when (cursor-jump c)
      (loop for k = (cursor-get-key c)
            while k
            collect k
            while (cursor-step c)))))

(defun %perform (db op cursor tree)
  "Apply OP to DB, with CURSOR the sequence's cursor on DB; the result,
in an order both libraries share."
  (destructuring-bind (name &rest args) op
    (flet ((ordered (keys)
             (if tree keys (sorted-octets keys))))
      (ecase name
        (:set (apply #'db-set db args))
        (:add (apply #'db-add db args))
        (:replace (apply #'db-replace db args))
        (:append (apply #'db-append db args))
        (:get (db-get db (first args)))
        (:check (db-check db (first args)))
        (:seize (db-seize db (first args)))
        (:remove (db-remove db (first args)))
        (:cas (apply #'db-cas db args))
        (:increment (db-increment db (first args) (second args)
                                  :orig (third args)))
        (:increment-double (db-increment-double db (first args) (second args)
                                                :orig (third args)))
        (:count (db-count db))
        (:clear (db-clear db))
        (:set-bulk (db-set-bulk db (first args) :atomic (second args)))
        (:get-bulk (let ((r (db-get-bulk db (first args)
                                         :atomic (second args))))
                     ;; Kyoto returns them in key order.
                     (sort (copy-list r) #'octets< :key #'car)))
        (:remove-bulk (db-remove-bulk db (first args) :atomic (second args)))
        (:match-prefix (ordered (db-match-prefix db (first args)
                                                 :max (second args))))
        (:match-regex (ordered (db-match-regex db (first args)
                                               :max (second args))))
        (:match-similar (db-match-similar db (first args) (second args)
                                          :utf (third args)
                                          :max (fourth args)))
        (:walk (ordered (walk-keys db)))
        (:jump-get (with-cursor (c db)
                     (and (cursor-jump c (first args))
                          (multiple-value-list (cursor-get c)))))
        (:cursor-jump (cursor-jump cursor (first args)))
        (:cursor-jump-back (cursor-jump-back cursor (first args)))
        (:cursor-step (cursor-step cursor))
        (:cursor-step-back (cursor-step-back cursor))
        (:cursor-get (multiple-value-list (cursor-get cursor)))
        (:cursor-get-step (multiple-value-list (cursor-get cursor :step t)))
        (:cursor-set-value (cursor-set-value cursor (first args)))
        (:cursor-remove (cursor-remove cursor))
        (:cursor-seize (multiple-value-list (cursor-seize cursor)))))))

(defparameter *list-ops* '(:get-bulk :match-prefix :match-regex
                           :match-similar :walk)
  "Operations whose result is a list, NIL when empty, not a failure.")

(defun perform (db op cursor tree)
  "OP's outcome on DB: (:VALUE result), (:FAILS reason) for a NIL
result, or (:SIGNALS condition-class)."
  (handler-case
      (let ((r (%perform db op cursor tree)))
        (if (and (or (null r) (equal r '(nil)))
                 (not (member (first op) *list-ops*)))
            (list :fails (db-error db))
            (list :value r)))
    (vivace-cabinet-error (c)
      (list :signals (type-of c)))))

(defun run-sequence (kind seed steps dir)
  "Run STEPS random operations from SEED on new databases of KIND (see
*KINDS*) in DIR, one vivace-cabinet's and one Kyoto's.  NIL when every
outcome agrees, else the first difference as a plist."
  (destructuring-bind (name args file) (assoc kind *kinds*)
    (declare (ignore name))
    (let* ((tree (eq :tree (getf args :type)))
           (*random-state* (sb-ext:seed-random-state seed))
           (v (apply #'open-db (merge-pathnames "v.vc/" dir) args))
           (k (open-kyoto-db (merge-pathnames file dir)
                             :mode '(:writer :create :truncate))))
      (unwind-protect
           (with-cursor (vc v)
             (with-cursor (kc k)
               (loop for step from 1 to steps
                     for op = (random-op tree)
                     for ov = (perform v op vc tree)
                     for ok = (perform k op kc tree)
                     unless (equalp ov ok)
                       return (list :kind kind :seed seed :step step :op op
                                    :vivace-cabinet ov :kyoto ok))))
        (close-db v)
        (close-db k)))))

(defun check-conformance (&key (kinds (mapcar #'first *kinds*)) (seeds 10)
                               (steps 2000) (from 1))
  "Run SEEDS sequences of STEPS operations, seeds FROM onwards, on each
of KINDS.  The differences found, the first of each sequence."
  (loop for kind in kinds
        nconc (loop for seed from from below (+ from seeds)
                    for d = (let ((dir (fresh-directory "vc-conformance")))
                              (unwind-protect
                                   (run-sequence kind seed steps dir)
                                (uiop:delete-directory-tree
                                 dir :validate t
                                     :if-does-not-exist :ignore)))
                    when d collect d)))

(defun replay (kind seed steps &key (show 12))
  "Rerun KIND's sequence from SEED for STEPS operations, printing the
last SHOW operations with both outcomes."
  (destructuring-bind (name args file) (assoc kind *kinds*)
    (declare (ignore name))
    (let* ((dir (fresh-directory "vc-replay"))
           (tree (eq :tree (getf args :type)))
           (*random-state* (sb-ext:seed-random-state seed))
           (v (apply #'open-db (merge-pathnames "v.vc/" dir) args))
           (k (open-kyoto-db (merge-pathnames file dir)
                             :mode '(:writer :create :truncate))))
      (unwind-protect
           (with-cursor (vc v)
             (with-cursor (kc k)
               (loop for step from 1 to steps
                     for op = (random-op tree)
                     for ov = (perform v op vc tree)
                     for ok = (perform k op kc tree)
                     when (> step (- steps show))
                       do (format t "~&~4d ~s~%     v ~s~%     k ~s~%"
                                  step op ov ok))))
        (close-db v)
        (close-db k)
        (uiop:delete-directory-tree dir :validate t)))))
