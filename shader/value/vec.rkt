#lang racket/base

;; ============================================================
;; 值层 · value/vec.rkt —— 向量运算
;;
;; 「逻辑：GLSL 向量内建的 CPU 镜像（运算部分；取用在 access.rkt）」。
;; 数据面是裸 ffi cvector；宽度 = cvector 长度（自动）；标量可放任一侧。
;; 命名：[Racket 传统]（vec-add / vec-dot / …）。GLSL 名（vadd/vdot/…）在 rename-vec.rkt。
;; ============================================================

(require ffi/vector "type.rkt" "cvector.rkt")

(provide
 vec-map
 vec-add vec-sub vec-mul vec-div vec-neg vec-abs vec-min vec-max
 vec-floor vec-ceil vec-fract vec-mod
 vec-sqrt vec-pow vec-exp vec-log vec-sin vec-cos vec-tan vec-radians vec-degrees
 vec-dot vec-cross vec-length vec-distance vec-normalize vec-mix vec-clamp
 vec-step vec-smoothstep vec-reflect vec-refract vec-faceforward
 vec-and vec-or vec-xor vec-not vec-shift-left vec-shift-right)

;; 逐分量应用任意函数（逃生舱）。结果类型同输入。
(define (vec-map f v) (cvector-map1 'vec-map f v))

;; ---------- 逐分量算术 ----------

(define (vec-add a b) (cvector-binary 'vec-add + a b))
(define (vec-sub a b) (cvector-binary 'vec-sub - a b))
(define (vec-mul a b) (cvector-binary 'vec-mul * a b))

(define (float-mod x y) (- x (* y (floor (/ x y)))))

(define (vec-div a b)
  ;; 整数向量用截断除法（GLSL 语义）
  (define v (if (number? a) b a))
  (cvector-binary 'vec-div (if (int-kind? (value-kind v 'vec-div)) quotient /) a b))

(define (vec-mod a b)
  (define v (if (number? a) b a))
  (cvector-binary 'vec-mod (if (int-kind? (value-kind v 'vec-mod)) modulo float-mod) a b))

(define (vec-min a b) (cvector-binary 'vec-min min a b))
(define (vec-max a b) (cvector-binary 'vec-max max a b))

(define (vec-neg v) (cvector-map1 'vec-neg - v))
(define (vec-abs v) (cvector-map1 'vec-abs abs v))

(define (vec-floor v) (require-float 'vec-floor v) (cvector-map1 'vec-floor floor v))
(define (vec-ceil v) (require-float 'vec-ceil v) (cvector-map1 'vec-ceil ceiling v))
(define (vec-fract v) (require-float 'vec-fract v) (cvector-map1 'vec-fract (lambda (x) (- x (floor x))) v))

;; ---------- 幂 / 指 / 三角（仅 float/double） ----------

(define (vec-sqrt v)    (require-float 'vec-sqrt v)    (cvector-map1 'vec-sqrt sqrt v))
(define (vec-pow a b)   (require-float 'vec-pow (if (number? a) b a)) (cvector-binary 'vec-pow expt a b))
(define (vec-exp v)     (require-float 'vec-exp v)     (cvector-map1 'vec-exp exp v))
(define (vec-log v)     (require-float 'vec-log v)     (cvector-map1 'vec-log log v))
(define (vec-sin v)     (require-float 'vec-sin v)     (cvector-map1 'vec-sin sin v))
(define (vec-cos v)     (require-float 'vec-cos v)     (cvector-map1 'vec-cos cos v))
(define (vec-tan v)     (require-float 'vec-tan v)     (cvector-map1 'vec-tan tan v))
(define (vec-radians v) (require-float 'vec-radians v) (cvector-map1 'vec-radians (lambda (x) (* x (/ (acos -1.0) 180.0))) v))
(define (vec-degrees v) (require-float 'vec-degrees v) (cvector-map1 'vec-degrees (lambda (x) (* x (/ 180.0 (acos -1.0)))) v))

;; ---------- 几何 ----------

(define (vec-dot a b)
  (require-float 'vec-dot a)
  (define k (value-kind a 'vec-dot))
  (unless (eq? k (value-kind b 'vec-dot)) (error 'vec-dot "两个向量类别不同"))
  (define n ((kind-length k) a))
  (unless (= n ((kind-length k) b)) (error 'vec-dot "向量长度不同"))
  (define ref (kind-ref k))
  (for/sum ([i (in-range n)]) (* (ref a i) (ref b i))))

(define (vec-length v) (sqrt (vec-dot v v)))
(define (vec-distance a b) (vec-length (vec-sub a b)))

(define (vec-normalize v)
  (define l (vec-length v))
  (when (zero? l) (error 'vec-normalize "零向量不能归一化"))
  (vec-div v l))

(define (vec-cross a b)
  (require-float 'vec-cross a)
  (define k (value-kind a 'vec-cross))
  (unless (eq? k (value-kind b 'vec-cross)) (error 'vec-cross "两个向量类别不同"))
  (unless (and (= ((kind-length k) a) 3) (= ((kind-length k) b) 3))
    (error 'vec-cross "叉积要求 3 分量向量"))
  (define ref (kind-ref k))
  (apply (kind-ctor k)
         (list (- (* (ref a 1) (ref b 2)) (* (ref a 2) (ref b 1)))
               (- (* (ref a 2) (ref b 0)) (* (ref a 0) (ref b 2)))
               (- (* (ref a 0) (ref b 1)) (* (ref a 1) (ref b 0))))))

(define (vec-mix a b t)
  (require-float 'vec-mix a)
  (cond [(number? t)
         (check-scalar 'vec-mix (value-kind a 'vec-mix) t)
         (cvector-map2 'vec-mix (lambda (x y) (+ x (* t (- y x)))) a b)]
        [else (cvector-map3 'vec-mix (lambda (x y tt) (+ x (* tt (- y x)))) a b t)]))

(define (vec-clamp v lo hi)
  (cond [(and (number? lo) (number? hi))
         (check-scalar 'vec-clamp (value-kind v 'vec-clamp) lo)
         (check-scalar 'vec-clamp (value-kind v 'vec-clamp) hi)
         (cvector-map1 'vec-clamp (lambda (x) (min (max x lo) hi)) v)]
        [(and (not (number? lo)) (not (number? hi)))
         (cvector-map3 'vec-clamp (lambda (x l h) (min (max x l) h)) v lo hi)]
        [else (error 'vec-clamp "lo/hi 要么都是标量，要么都是向量")]))

(define (vec-step e x)
  (require-float 'vec-step x)
  (if (number? e)
      (begin (check-scalar 'vec-step (value-kind x 'vec-step) e)
             (cvector-map1 'vec-step (lambda (y) (if (< y e) 0.0 1.0)) x))
      (cvector-map2 'vec-step (lambda (ee y) (if (< y ee) 0.0 1.0)) e x)))

(define (vec-smoothstep e0 e1 x)
  (require-float 'vec-smoothstep x)
  (define (ss a b y)
    (define t (min (max (/ (- y a) (- b a)) 0.0) 1.0))
    (* t t (- 3.0 (* 2.0 t))))
  (cond [(and (number? e0) (number? e1))
         (cvector-map1 'vec-smoothstep (lambda (y) (ss e0 e1 y)) x)]
        [(and (not (number? e0)) (not (number? e1)))
         (cvector-map3 'vec-smoothstep ss e0 e1 x)]
        [else (error 'vec-smoothstep "e0/e1 要么都是标量，要么都是向量")]))

(define (vec-reflect i n)
  (require-float 'vec-reflect i)
  (vec-sub i (vec-mul n (* 2.0 (vec-dot n i)))))

(define (vec-refract i n eta)
  (require-float 'vec-refract i)
  (define d (vec-dot n i))
  (define k (- 1.0 (* eta eta (- 1.0 (* d d)))))
  (if (negative? k)
      (cvector-map1 'vec-refract (lambda (_) 0.0) i)
      (vec-sub (vec-mul i eta) (vec-mul n (+ (* eta d) (sqrt k))))))

(define (vec-faceforward n i nref)
  (if (< (vec-dot nref i) 0.0) n (vec-neg n)))

;; ---------- 位运算（仅 int 族） ----------

(define (vec-and a b) (require-int 'vec-and a) (cvector-map2 'vec-and bitwise-and a b))
(define (vec-or a b)  (require-int 'vec-or a)  (cvector-map2 'vec-or  bitwise-ior a b))
(define (vec-xor a b) (require-int 'vec-xor a) (cvector-map2 'vec-xor bitwise-xor a b))

(define (vec-not v)
  (require-int 'vec-not v)
  (define k (value-kind v 'vec-not))
  (if (eq? k 'u32)
      (cvector-map1 'vec-not (lambda (x) (bitwise-and (bitwise-not x) #xFFFFFFFF)) v)
      (cvector-map1 'vec-not bitwise-not v)))

(define (vec-shift-left v s)  (require-int 'vec-shift-left v)  (cvector-op-scalar 'vec-shift-left (lambda (x n) (arithmetic-shift x n)) v s))
(define (vec-shift-right v s) (require-int 'vec-shift-right v) (cvector-op-scalar 'vec-shift-right (lambda (x n) (arithmetic-shift x (- n))) v s))
