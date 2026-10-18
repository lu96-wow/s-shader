#lang racket/base

;; ============================================================
;; 值层 · value/layout.rkt —— 交错记录布局
;;
;; 「逻辑：把若干字段按类型清单铺成一条交错记录，并算 stride / offset」。
;; 供 glVertexAttribPointer 用；不是 GLSL 语言概念，所以实现层用 record-*。
;; 命名：[Racket 传统]。GLSL 名（glsl-struct/glsl-stride-bytes/…）在 rename-layout.rkt。
;; ============================================================

(require ffi/vector "type.rkt" "cvector.rkt")

(provide pack-record record-stride-bytes record-field-offsets record-field-size)

;; 分量 → 本机字节序字节串（GL 直接吃本机字节序）
(define (component->bytes kind x)
  (case kind
    [(f32) (real->floating-point-bytes x 4 (system-big-endian?))]
    [(f64) (real->floating-point-bytes x 8 (system-big-endian?))]
    [(s32) (integer->integer-bytes x 4 #t (system-big-endian?))]
    [(u32) (integer->integer-bytes x 4 #f (system-big-endian?))]))

;; 一个字段值 → 分量列表（长度 = type-elements t），同时做类型/长度检查。
(define (field->components who t f)
  (define kind (type-kind t))
  (define n (type-elements t))
  (define (scalar x)
    (case kind
      [(f32 f64) (ensure-flonum who x)]
      [(s32)     (ensure-integer who x)]
      [(u32)     (if (eq? t 'bool)
                     (ensure-bool who x)
                     (begin (ensure-integer who x)
                            (when (negative? x) (error who "uint 分量不能为负：~s" x))
                            x))]))
  (cond
    [(= n 1) (list (scalar f))]
    [else
     (define v? (kind-vector? kind))
     (unless (v? f)
       (error who "字段 ~s 应为长度 ~a 的 ~a，实际 ~s" t n (kind->name kind) f))
     (define len (kind-length kind))
     (unless (= (len f) n)
       (error who "字段 ~s 应为长度 ~a 的 ~a，实际长度 ~a" t n (kind->name kind) (len f)))
     (define ref (kind-ref kind))
     (for/list ([j (in-range n)]) (ref f j))]))

;; 按类型清单把字段值铺成一条交错记录。
;; 结果类型：全同类 → 对应 cvector；混合类别 → u8vector；f32/f64 混用报错。
(define (pack-record types . fields)
  (unless (= (length types) (length fields))
    (error 'pack-record "字段数与类型清单不一致：~a 个字段 vs ~a 个类型" (length fields) (length types)))
  (when (null? types) (error 'pack-record "至少要一个字段"))
  (define kinds (map type-kind types))
  (when (and (memq 'f32 kinds) (memq 'f64 kinds))
    (error 'pack-record "交错缓冲不能混用 float/double 精度：~s" types))
  (define comps (for/list ([t (in-list types)] [f (in-list fields)])
                  (field->components 'pack-record t f)))
  (cond
    [(andmap (lambda (k) (eq? k (car kinds))) kinds)
     (apply (kind-ctor (car kinds)) (apply append comps))]
    [else
     (define out (make-u8vector (apply type-stride types) 0))
     (for/fold ([off 0]) ([t (in-list types)] [cs (in-list comps)])
       (define kind (type-kind t))
       (define bs (kind-component-bytes kind))
       (for ([x (in-list cs)] [j (in-naturals)])
         (for ([b (in-bytes (component->bytes kind x))] [k (in-naturals)])
           (u8vector-set! out (+ off (* j bs) k) b)))
       (+ off (* (length cs) bs)))
     out]))

;; 交错布局里每个字段的字节偏移
(define (record-field-offsets types)
  (let loop ([ts types] [off 0] [acc '()])
    (if (null? ts)
        (reverse acc)
        (loop (cdr ts) (+ off (type-byte-size (car ts))) (cons off acc)))))

;; 交错布局总字节步长
(define (record-stride-bytes types) (apply type-stride types))

;; 第 i 个字段的分量数
(define (record-field-size types i) (type-elements (list-ref types i)))
