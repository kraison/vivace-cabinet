(in-package #:vivace-cabinet-conformance)

(fiveam:in-suite conformance-suite)

(defmacro def-conformance-test (kind)
  `(fiveam:test ,(alexandria:symbolicate "CONFORMS/" kind)
     ,(format nil "Random sequences agree with Kyoto on ~(~a~)." kind)
     (let ((diffs (check-conformance :kinds '(,kind) :seeds 20 :steps 1000)))
       (fiveam:is (null diffs) "~{~s~%~}" diffs))))

(def-conformance-test :hash)
(def-conformance-test :bplus-tree)
(def-conformance-test :skip-list)
