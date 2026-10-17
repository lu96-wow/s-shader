#lang racket/base

;; ============================================================
;; 值层 · value/rename-matrix.rkt —— GLSL 风格命名（矩阵运算）
;;
;; 纯 alias：value/matrix.rkt 的 Racket 名 → GLSL 名。零逻辑。
;; 元素取用的别名（mat4-ref / mat4-set!）在 rename-access.rkt。
;; ============================================================

(require "matrix.rkt" (for-syntax racket/base racket/syntax))

(provide (except-out (all-defined-out) define-matrix-glsl-names))

(define-syntax (define-matrix-glsl-names stx)
  (syntax-case stx ()
    [(_ prefix n kind)
     (with-syntax ([ident     (format-id #'prefix "~a-identity" #'prefix)]
                   [copy      (format-id #'prefix "~a-copy" #'prefix)]
                   [mul       (format-id #'prefix "~a-mul" #'prefix)]
                   [mulvec    (format-id #'prefix "~a-mul-vec" #'prefix)]
                   [vecmul    (format-id #'prefix "~a-vec-mul" #'prefix)]
                   [add       (format-id #'prefix "~a-add" #'prefix)]
                   [sub       (format-id #'prefix "~a-sub" #'prefix)]
                   [neg       (format-id #'prefix "~a-neg" #'prefix)]
                   [tr        (format-id #'prefix "~a-transpose" #'prefix)]
                   [inv       (format-id #'prefix "~a-inverse" #'prefix)]
                   [muls      (format-id #'prefix "~a-mul-scalar" #'prefix)])
       #'(begin
           (define (ident) (identity-matrix n 'kind))
           (define (copy m) (matrix-copy m))
           (define (mul a b) (matrix* a b))
           (define (mulvec m v) (matrix-vector* m v))
           (define (vecmul v m) (vector-matrix* v m))
           (define (add a b) (matrix+ a b))
           (define (sub a b) (matrix- a b))
           (define (neg m) (matrix-neg m))
           (define (tr m) (matrix-transpose m))
           (define (inv m) (matrix-inverse m))
           (define (muls m s) (matrix-scale m s))))]))

(define-matrix-glsl-names mat2 2 f32)
(define-matrix-glsl-names mat3 3 f32)
(define-matrix-glsl-names mat4 4 f32)
(define-matrix-glsl-names dmat2 2 f64)
(define-matrix-glsl-names dmat3 3 f64)
(define-matrix-glsl-names dmat4 4 f64)
