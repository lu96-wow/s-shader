#lang racket/base

;; ============================================================
;; 值层 · value/construct.rkt —— 构造
;;
;; 「逻辑：从分量 / 列 / 标量造出 cvector 值」。
;;   向量：make-f32-vec / make-f64-vec / make-s32-vec / make-u32-vec / make-bool-vec
;;   矩阵：make-matrix（对角 / 拷贝 / 列 / 标量）
;; 命名：[Racket 传统]。GLSL 名（vec3/mat4/…）在 rename-construct.rkt。
;; ============================================================

(require ffi/vector "cvector.rkt")

(provide make-f32-vec make-f64-vec make-s32-vec make-u32-vec make-bool-vec
         make-matrix)

;; ---------- 向量 ----------

(define (check-arity who n elems)
  (unless (= (length elems) n)
    (error who "需要 ~a 个分量，实际 ~a" n (length elems)))
  elems)

(define (build ctor check who n elems)
  (apply ctor (map (lambda (e) (check who e)) (check-arity who n elems))))

(define (make-f32-vec who n . elems) (build f32vector ensure-flonum who n elems))
(define (make-f64-vec who n . elems) (build f64vector ensure-flonum who n elems))
(define (make-s32-vec who n . elems) (build s32vector ensure-integer who n elems))
(define (make-u32-vec who n . elems) (build u32vector ensure-integer who n elems))
(define (make-bool-vec who n . elems) (build u32vector ensure-bool who n elems))

;; ---------- 矩阵 ----------

;; 列向量 → list（f32vector/f64vector/list，长度须为 n）
(define (column->list who c n)
  (cond
    [(f32vector? c)
     (unless (= (f32vector-length c) n) (error who "列向量长度应为 ~a，实际 ~a" n (f32vector-length c)))
     (f32vector->list c)]
    [(f64vector? c)
     (unless (= (f64vector-length c) n) (error who "列向量长度应为 ~a，实际 ~a" n (f64vector-length c)))
     (f64vector->list c)]
    [(list? c)
     (unless (= (length c) n) (error who "列向量长度应为 ~a，实际 ~a" n (length c)))
     (map (lambda (x) (ensure-flonum who x)) c)]
    [else (error who "列应为 f32vector/f64vector/list，实际 ~s" c)]))

;; 对角矩阵（列主序展开）
(define (diagonal-list who n x)
  (define f (ensure-flonum who x))
  (for*/list ([c (in-range n)] [r (in-range n)]) (if (= r c) f 0.0)))

;; 通用矩阵构造。ctor = f32vector / f64vector。
;;   (make-matrix n ctor 标量)        → 对角
;;   (make-matrix n ctor f32/f64[n²]) → 拷贝
;;   (make-matrix n ctor n 个列)      → 拼列
;;   (make-matrix n ctor n*n 个标量)  → 列主序
;;   零参数 → 报错（对齐 GLSL：未初始化不支持）
(define (make-matrix n ctor . args)
  (define who (or (object-name ctor) 'make-matrix))
  (define total (* n n))
  (cond
    [(null? args) (error who "不支持零参数构造（GLSL 里是未初始化）")]
    [(= (length args) 1)
     (define x (car args))
     (cond
       [(number? x) (apply ctor (diagonal-list who n x))]
       [(and (f32vector? x) (= (f32vector-length x) total)) (apply ctor (f32vector->list x))]
       [(and (f64vector? x) (= (f64vector-length x) total)) (apply ctor (f64vector->list x))]
       [(and (list? x) (= (length x) total)) (apply ctor (map (lambda (y) (ensure-flonum who y)) x))]
       [else (error who "单参数应为标量或长度 ~a 的 f32/f64 向量/表，实际 ~s" total x)])]
    [(= (length args) n) (apply ctor (apply append (map (lambda (c) (column->list who c n)) args)))]
    [(= (length args) total) (apply ctor (map (lambda (x) (ensure-flonum who x)) args))]
    [else (error who "参数个数应为 1、~a 或 ~a，实际 ~a" n total (length args))]))
