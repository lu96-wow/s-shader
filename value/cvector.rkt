#lang racket/base

;; ============================================================
;; 值层 · value/cvector.rkt —— 运行时 cvector 原语
;;
;; 「逻辑：裸 ffi 值的读写分派 + 标量校验 + 逐分量映射」。
;; 这是 vec / matrix / construct / layout 共用的底座，不是用户 API，
;; 因此没有对应的 rename-*.rkt。
;;
;; 命名：[Racket 传统]。
;; ============================================================

(require ffi/vector "type.rkt")

(provide ensure-flonum ensure-integer ensure-bool
         value-kind check-scalar require-float require-int
         cvector->list
         cvector-map1 cvector-map2 cvector-map3
         cvector-op-scalar scalar-op-cvector cvector-binary)

;; ---------- 输入校验（不隐式转换） ----------

(define (ensure-flonum who x)
  (unless (flonum? x)
    (error who "参数应为浮点（如 1.0，不要整数/有理数），实际 ~s" x))
  x)

(define (ensure-integer who x)
  (unless (and (exact? x) (integer? x))
    (error who "参数应为整数，实际 ~s" x))
  x)

;; bool → 0/1（GLSL bool 在内存是 32 位）
(define (ensure-bool who x)
  (cond [(boolean? x) (if x 1 0)]
        [(number? x) (if (zero? x) 0 1)]
        [else (error who "bool 分量应为 #t/#f 或数字，实际 ~s" x)]))

;; ---------- 运行期值的存储类别 ----------

(define (value-kind v who)
  (cond [(f32vector? v) 'f32] [(f64vector? v) 'f64]
        [(s32vector? v) 's32] [(u32vector? v) 'u32]
        [(u16vector? v) 'u16] [(u8vector? v) 'u8]
        [else (error who "需要向量（f32/f64/s32/u32/u16/u8vector），实际 ~s" v)]))

(define (require-float who v)
  (define k (value-kind v who))
  (unless (float-kind? k) (error who "只对 float/double 向量有意义，实际 ~a" k))
  v)

(define (require-int who v)
  (define k (value-kind v who))
  (unless (int-kind? k) (error who "只对 int/uint 向量有意义，实际 ~a" k))
  v)

(define (check-scalar who k s)
  (if (float-kind? k) (ensure-flonum who s) (ensure-integer who s))
  s)

(define (cvector->list k v)
  (define len (kind-length k))
  (define ref (kind-ref k))
  (for/list ([i (in-range (len v))]) (ref v i)))

;; ---------- 逐分量映射 ----------

(define (cvector-map1 who f v)
  (define k (value-kind v who))
  (apply (kind-ctor k) (map f (cvector->list k v))))

(define (cvector-map2 who f a b)
  (define ka (value-kind a who))
  (define kb (value-kind b who))
  (unless (eq? ka kb) (error who "两个向量精度/类别不同：~a vs ~a" ka kb))
  (define n ((kind-length ka) a))
  (unless (= n ((kind-length kb) b)) (error who "向量长度不同：~a vs ~a" n ((kind-length kb) b)))
  (apply (kind-ctor ka)
         (for/list ([x (in-list (cvector->list ka a))] [y (in-list (cvector->list kb b))])
           (f x y))))

(define (cvector-map3 who f a b c)
  (define ka (value-kind a who))
  (unless (and (eq? ka (value-kind b who)) (eq? ka (value-kind c who)))
    (error who "三个向量精度/类别不同"))
  (define n ((kind-length ka) a))
  (unless (and (= n ((kind-length ka) b)) (= n ((kind-length ka) c)))
    (error who "向量长度不同"))
  (apply (kind-ctor ka)
         (map f (cvector->list ka a) (cvector->list ka b) (cvector->list ka c))))

;; v op 标量 / 标量 op v
(define (cvector-op-scalar who f v s)
  (define k (value-kind v who))
  (check-scalar who k s)
  (apply (kind-ctor k) (map (lambda (x) (f x s)) (cvector->list k v))))

(define (scalar-op-cvector who f s v)
  (define k (value-kind v who))
  (check-scalar who k s)
  (apply (kind-ctor k) (map (lambda (x) (f s x)) (cvector->list k v))))

;; 标量可放任一侧的二元运算派发
(define (cvector-binary who f a b)
  (cond [(number? a) (scalar-op-cvector who f a b)]
        [(number? b) (cvector-op-scalar who f a b)]
        [else (cvector-map2 who f a b)]))
