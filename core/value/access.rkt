#lang racket/base

;; ============================================================
;; 值层 · value/access.rkt —— 取用（按索引读 / 写）
;;
;; 「逻辑：从 CPU 数据里按索引读/写一个分量 / 元素」。
;; 覆盖三种数据形态：
;;   - 向量分量        vec-count / vec-ref / vec-set! / vec-x..vec-w
;;   - 矩阵元素        matrix-dim / matrix-ref / matrix-set!   （Racket 约定 row,col）
;;   - 顶点缓冲元素    vec-buffer-count / vec-buffer-ref / vec-buffer-set!
;;
;; 取用只做“索引 → 位置”的映射，不做数学（数学在 vec.rkt / matrix.rkt）。
;; 命名：[Racket 传统]。GLSL 名（vref / mat4-ref / …）在 rename-access.rkt。
;; ============================================================

(require ffi/vector "type.rkt" "cvector.rkt" "buffer.rkt")

(provide vec-count vec-ref vec-set! vec-x vec-y vec-z vec-w
         matrix-dim matrix-ref matrix-set!
         vec-buffer-count vec-buffer-ref vec-buffer-set!)

;; ---------- 向量分量 ----------

(define (vec-count v) ((kind-length (value-kind v 'vec-count)) v))
(define (vec-ref v i) ((kind-ref (value-kind v 'vec-ref)) v i))
(define (vec-set! v i x) ((kind-set! (value-kind v 'vec-set!)) v i x))

(define (vec-x v) (vec-ref v 0))
(define (vec-y v) (vec-ref v 1))
(define (vec-z v) (vec-ref v 2))
(define (vec-w v) (vec-ref v 3))

;; ---------- 矩阵元素（Racket 约定：row 在前；内部列主序） ----------

(define (matrix-dim who m)
  (define len ((kind-length (value-kind m who)) m))
  (define n (integer-sqrt len))
  (unless (= (* n n) len) (error who "不是方阵：长度 ~a 不是平方数" len))
  n)

;; 第 row 行、第 col 列。存储列主序 → idx = col*n + row。
(define (matrix-ref m row col)
  (define k (value-kind m 'matrix-ref))
  (define n (matrix-dim 'matrix-ref m))
  ((kind-ref k) m (+ (* col n) row)))

(define (matrix-set! m row col x)
  (define k (value-kind m 'matrix-set!))
  (define n (matrix-dim 'matrix-set! m))
  ((kind-set! k) m (+ (* col n) row) x))

;; ---------- 顶点缓冲元素（kind 由数组 data 的 Racket 类型决定）----------

(define (vec-buffer-count v)
  (define data (vec-buffer-data v))
  (define k (value-kind data 'vec-buffer-count))
  (quotient ((kind-length k) data) (vec-buffer-width v)))

(define (vec-buffer-ref v i)
  (define w (vec-buffer-width v))
  (define data (vec-buffer-data v))
  (define k (value-kind data 'vec-buffer-ref))
  (define ref (kind-ref k))
  (define cset! (kind-set! k))
  (define out ((kind-make k) w (if (float-kind? k) 0.0 0)))
  (for ([j (in-range w)])
    (cset! out j (ref data (+ (* i w) j))))
  out)

(define (vec-buffer-set! v i elem)
  (define width (vec-buffer-width v))
  (define data (vec-buffer-data v))
  (define k (value-kind data 'vec-buffer-set!))
  (define ke (value-kind elem 'vec-buffer-set!))
  (unless (eq? k ke)
    (error 'vec-buffer-set! "元素类别不匹配：数组 ~a，元素 ~a" (kind->name k) (kind->name ke)))
  (unless (= ((kind-length ke) elem) width)
    (error 'vec-buffer-set! "宽度不匹配：期望 ~a，实际 ~a" width ((kind-length ke) elem)))
  (define ref (kind-ref k))
  (define cset! (kind-set! k))
  (for ([j (in-range width)])
    (cset! data (+ (* i width) j) (ref elem j))))
