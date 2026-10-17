#lang racket/base

;; ============================================================
;; 值层 · value/rename-access.rkt —— GLSL 风格命名（取用）
;;
;; 纯 alias：value/access.rkt 的 Racket 名 → GLSL 名。零逻辑。
;; 唯一动作：GLSL 的 mat4-ref m col row ↔ Racket 的 matrix-ref m row col（交换参数）。
;; ============================================================

(require ffi/vector "access.rkt" (for-syntax racket/base racket/syntax))

(provide (except-out (all-defined-out) define-matrix-access-names))

;; ---------- 向量分量 ----------

(define vcount vec-count)
(define vref vec-ref)
(define vset! vec-set!)
(define vx vec-x)
(define vy vec-y)
(define vz vec-z)
(define vw vec-w)

;; ---------- CPU 向量数组（新名） ----------

(define vec-array-count vec-buffer-count)
(define vec-array-ref vec-buffer-ref)
(define vec-array-set! vec-buffer-set!)

;; ---------- 旧名（deprecated，等价别名）----------

(define gl-vec-count vec-array-count)
(define gl-vec-ref vec-array-ref)
(define gl-vec-set! vec-array-set!)

;; ---------- 矩阵元素（GLSL 顺序 col,row → Racket row,col） ----------

(define-syntax (define-matrix-access-names stx)
  (syntax-case stx ()
    [(_ prefix)
     (with-syntax ([ref  (format-id #'prefix "~a-ref" #'prefix)]
                   [setv (format-id #'prefix "~a-set!" #'prefix)])
       #'(begin
           (define (ref m col row) (matrix-ref m row col))
           (define (setv m col row x) (matrix-set! m row col x))))]))

(define-matrix-access-names mat2)
(define-matrix-access-names mat3)
(define-matrix-access-names mat4)
(define-matrix-access-names dmat2)
(define-matrix-access-names dmat3)
(define-matrix-access-names dmat4)
