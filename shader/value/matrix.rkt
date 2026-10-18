#lang racket/base

;; ============================================================
;; 值层 · value/matrix.rkt —— 矩阵运算
;;
;; 「逻辑：GLSL 矩阵内建的 CPU 镜像（运算部分；元素取用在 access.rkt）」
;; 约定：matrix-ref m row col（Racket 约定），内部列主序 m[col][row] = idx col*n+row。
;; 命名：[Racket 传统]（matrix-ref / matrix* / …）。GLSL 名（mat4-ref/mat4-mul/…）
;; 在 rename-matrix.rkt（在那里交换 col/row）。
;; ============================================================

(require ffi/vector "type.rkt" "cvector.rkt" "access.rkt")

(provide identity-matrix matrix-copy matrix*
         matrix-vector* vector-matrix* matrix+ matrix- matrix-neg
         matrix-transpose matrix-inverse matrix-scale)

(define (check-matrix who k n m)
  (define k2 (value-kind m who))
  (unless (eq? k k2) (error who "矩阵精度不匹配：~a vs ~a" k k2))
  (unless (= n (matrix-dim who m)) (error who "矩阵阶不匹配"))
  m)

(define (identity-matrix n k)
  (apply (kind-ctor k) (for*/list ([c (in-range n)] [r (in-range n)]) (if (= c r) 1.0 0.0))))

(define (matrix-copy m)
  (define k (value-kind m 'matrix-copy))
  (apply (kind-ctor k) (cvector->list k m)))

(define (matrix* a b)
  (define k (value-kind a 'matrix*))
  (define n (matrix-dim 'matrix* a))
  (check-matrix 'matrix* k n b)
  (define ref (kind-ref k))
  (apply (kind-ctor k)
         (for*/list ([c (in-range n)] [r (in-range n)])
           (for/fold ([acc 0.0]) ([i (in-range n)])
             (+ acc (* (ref a (+ (* i n) r)) (ref b (+ (* c n) i))))))))

(define (matrix-vector* m v)
  (define k (value-kind m 'matrix-vector*))
  (define n (matrix-dim 'matrix-vector* m))
  (unless (eq? k (value-kind v 'matrix-vector*)) (error 'matrix-vector* "向量精度与矩阵不匹配"))
  (unless (= n ((kind-length k) v)) (error 'matrix-vector* "向量长度应为 ~a" n))
  (define ref (kind-ref k))
  (apply (kind-ctor k)
         (for/list ([r (in-range n)])
           (for/fold ([acc 0.0]) ([c (in-range n)])
             (+ acc (* (ref m (+ (* c n) r)) (ref v c)))))))

(define (vector-matrix* v m)
  (define k (value-kind m 'vector-matrix*))
  (define n (matrix-dim 'vector-matrix* m))
  (unless (eq? k (value-kind v 'vector-matrix*)) (error 'vector-matrix* "向量精度与矩阵不匹配"))
  (unless (= n ((kind-length k) v)) (error 'vector-matrix* "向量长度应为 ~a" n))
  (define ref (kind-ref k))
  (apply (kind-ctor k)
         (for/list ([c (in-range n)])
           (for/fold ([acc 0.0]) ([r (in-range n)])
             (+ acc (* (ref v r) (ref m (+ (* c n) r))))))))

(define (matrix+ a b)
  (define k (value-kind a 'matrix+)) (define n (matrix-dim 'matrix+ a)) (check-matrix 'matrix+ k n b)
  (cvector-map2 'matrix+ + a b))

(define (matrix- a b)
  (define k (value-kind a 'matrix-)) (define n (matrix-dim 'matrix- a)) (check-matrix 'matrix- k n b)
  (cvector-map2 'matrix- - a b))

(define (matrix-neg m) (cvector-map1 'matrix-neg - m))

(define (matrix-transpose m)
  (define k (value-kind m 'matrix-transpose))
  (define n (matrix-dim 'matrix-transpose m))
  (define ref (kind-ref k))
  (apply (kind-ctor k)
         (for*/list ([c (in-range n)] [r (in-range n)]) (ref m (+ (* r n) c)))))

(define (matrix-inverse m)
  (define k (value-kind m 'matrix-inverse))
  (define n (matrix-dim 'matrix-inverse m))
  (define ref (kind-ref k))
  (define rows (make-vector n))
  (for ([r (in-range n)])
    (define v (make-f64vector (* 2 n) 0.0))
    (for ([c (in-range n)]) (f64vector-set! v c (exact->inexact (ref m (+ (* c n) r)))))
    (f64vector-set! v (+ n r) 1.0)
    (vector-set! rows r v))
  (for ([i (in-range n)])
    (define-values (p _)
      (for/fold ([best i] [bestv (abs (f64vector-ref (vector-ref rows i) i))])
                ([r (in-range (add1 i) n)])
        (define v (abs (f64vector-ref (vector-ref rows r) i)))
        (if (> v bestv) (values r v) (values best bestv))))
    (unless (> (abs (f64vector-ref (vector-ref rows p) i)) 1e-12)
      (error 'matrix-inverse "矩阵不可逆（奇异）"))
    (unless (= p i)
      (define tmp (vector-ref rows i))
      (vector-set! rows i (vector-ref rows p))
      (vector-set! rows p tmp))
    (define piv-row (vector-ref rows i))
    (define piv (f64vector-ref piv-row i))
    (for ([c (in-range (* 2 n))]) (f64vector-set! piv-row c (/ (f64vector-ref piv-row c) piv)))
    (for ([r (in-range n)] #:unless (= r i))
      (define row (vector-ref rows r))
      (define f (f64vector-ref row i))
      (for ([c (in-range (* 2 n))])
        (f64vector-set! row c (- (f64vector-ref row c) (* f (f64vector-ref piv-row c)))))))
  (apply (kind-ctor k)
         (for*/list ([c (in-range n)] [r (in-range n)])
           (f64vector-ref (vector-ref rows r) (+ n c)))))

(define (matrix-scale m s)
  (define k (value-kind m 'matrix-scale))
  (check-scalar 'matrix-scale k s)
  (cvector-map1 'matrix-scale (lambda (x) (* x s)) m))
