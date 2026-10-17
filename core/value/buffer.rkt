#lang racket/base

;; ============================================================
;; 值层 · value/buffer.rkt —— 缓冲类型 + 构造 + 拼接
;;
;; 「逻辑：vec-buffer 这种数据类型（n 个同型向量）+ 拼接」。元素取用在 access.rkt。
;; 不调用任何 GL（纯 CPU 数据），命名：[Racket 传统]。
;; GLSL 名（vec-array/dvec-array/… 、concat-vecs）在 rename-buffer.rkt。
;;
;; ★ vec-buffer 存 (data width)：data 是任意 ffi 向量，**kind 由 data 的 Racket
;;   类型隐含**（f32vector→float、f64vector→double、s32vector→int、u32vector→uint），
;;   所以不需要额外的 kind 字段/参数。
;; ============================================================

(require ffi/vector "type.rkt" "cvector.rkt")

(provide concat-vectors concat-vectors! concat-dvectors concat-dvectors!
         concat-s32vectors concat-s32vectors! concat-u32vectors concat-u32vectors!
         vec-buffer vec-buffer? vec-buffer-width vec-buffer-data
         vec-buffer-from make-vec-buffer
         vec-buffer-from-kind make-vec-buffer-kind)

;; ---------- 拼接 ----------

;; 通用原地拼接：把若干同型 cvector 依次写进 dst（从下标 0 起），返回元素数。
(define (concat-cvector! get-len get-ref cset! dst vs)
  (define i 0)
  (for ([v vs])
    (for ([j (in-range (get-len v))])
      (cset! dst i (get-ref v j))
      (set! i (add1 i))))
  i)

(define (concat-vectors! dst vs) (concat-cvector! f32vector-length f32vector-ref f32vector-set! dst vs))
(define (concat-dvectors! dst vs) (concat-cvector! f64vector-length f64vector-ref f64vector-set! dst vs))
(define (concat-s32vectors! dst vs) (concat-cvector! s32vector-length s32vector-ref s32vector-set! dst vs))
(define (concat-u32vectors! dst vs) (concat-cvector! u32vector-length u32vector-ref u32vector-set! dst vs))

;; 静态：拼成一块新缓冲（只分配输出这一块）
(define (concat-cvector get-len get-ref cset! make vs)
  (define out (make (for/sum ([v vs]) (get-len v)) 0.0))
  (concat-cvector! get-len get-ref cset! out vs)
  out)

(define (concat-vectors . vs) (concat-cvector f32vector-length f32vector-ref f32vector-set! make-f32vector vs))
(define (concat-dvectors . vs) (concat-cvector f64vector-length f64vector-ref f64vector-set! make-f64vector vs))
(define (concat-s32vectors . vs)
  (concat-cvector s32vector-length s32vector-ref s32vector-set! (lambda (n _) (make-s32vector n 0)) vs))
(define (concat-u32vectors . vs)
  (concat-cvector u32vector-length u32vector-ref u32vector-set! (lambda (n _) (make-u32vector n 0)) vs))

;; ---------- 顶点缓冲：n 个同型向量 ----------

;; 内部结构：一个 ffi 向量 + 每个向量的宽度（分量数）。对应 GLSL 的 vecN[N]。
;; kind 由 data 的 Racket 向量类型决定，不另存。
(struct vec-buffer (data width) #:transparent)

;; 静态：从若干同型向量构造（kind 由输入推断）
(define (vec-buffer-from vs)
  (unless (pair? vs) (error 'vec-buffer-from "至少给一个向量"))
  (define k (value-kind (car vs) 'vec-buffer-from))
  (define w ((kind-length k) (car vs)))
  (for ([v (cdr vs)])
    (define kv (value-kind v 'vec-buffer-from))
    (unless (eq? kv k)
      (error 'vec-buffer-from "所有向量须同类别，实际 ~a 与 ~a" (kind->name k) (kind->name kv)))
    (unless (= ((kind-length k) v) w)
      (error 'vec-buffer-from "所有向量宽度须一致，实际 ~a 与 ~a" w ((kind-length k) v))))
  (define data ((kind-make k) (* w (length vs)) (if (float-kind? k) 0.0 0)))
  (define ref (kind-ref k))
  (define cset! (kind-set! k))
  (define i 0)
  (for ([v vs])
    (for ([j (in-range w)])
      (cset! data i (ref v j))
      (set! i (add1 i))))
  (vec-buffer data w))

;; 动态：预分配 n 个同型向量（都填 template），之后 vec-buffer-set! 原地覆写
(define (make-vec-buffer n template)
  (unless (and (exact? n) (integer? n) (>= n 0))
    (error 'make-vec-buffer "n 应为非负整数，实际 ~s" n))
  (define k (value-kind template 'make-vec-buffer))
  (define w ((kind-length k) template))
  (define data ((kind-make k) (* n w) (if (float-kind? k) 0.0 0)))
  (define ref (kind-ref k))
  (define cset! (kind-set! k))
  (for ([i (in-range n)])
    (for ([j (in-range w)])
      (cset! data (+ (* i w) j) (ref template j))))
  (vec-buffer data w))

;; kind 断言版：vec-array=f32 / dvec-array=f64 / ivec-array=s32 / uvec-array=u32
(define (vec-buffer-from-kind who k vs)
  (unless (pair? vs) (error who "至少给一个向量"))
  (for ([v vs])
    (define kv (value-kind v who))
    (unless (eq? kv k)
      (error who "期望 ~a 元素，实际 ~a" (kind->name k) (kind->name kv))))
  (vec-buffer-from vs))

(define (make-vec-buffer-kind who k n template)
  (define kt (value-kind template who))
  (unless (eq? kt k)
    (error who "期望 ~a 元素，实际 ~a" (kind->name k) (kind->name kt)))
  (make-vec-buffer n template))
