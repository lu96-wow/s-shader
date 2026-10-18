#lang racket/base

;; ============================================================
;; 值层 · value/convert.rkt —— 精度转换
;;
;; 「逻辑：任意 GLSL 向量 / 缓冲 / 标量数组 → 指定精度的裸 cvector」。
;; 命名：[Racket 传统]（->f32vector / ->u16vector / …）。
;;
;; ★ vec-buffer 的转换按内部 data 的**实际 kind** 分派（不假定 f32）；
;;   输入也接受 u8/u16 标量数组（u8-array / u16-array）。
;;   注意与「取数据」的区别：
;;     - vec-array-data / u8-array-data：零拷贝取内部存储，不转换；
;;     - ->X：真正的类型转换，可能分配新向量。
;; ============================================================

(require ffi/vector "cvector.rkt" "buffer.rkt")

(provide ->f32vector ->f64vector ->s32vector ->u32vector ->u16vector ->u8vector)

(define (real->int who x)
  (cond [(exact-integer? x) x]
        [(real? x) (inexact->exact (truncate x))]
        [else (error who "不能转成整数：~s" x)]))

;; 输入归一成数值列表：vec-buffer 取内部 data；任意 cvector（含 u8/u16）→ list。
(define (number-list who x)
  (define v (if (vec-buffer? x) (vec-buffer-data x) x))
  (cond [(f32vector? v) (f32vector->list v)]
        [(f64vector? v) (f64vector->list v)]
        [(s32vector? v) (s32vector->list v)]
        [(u32vector? v) (u32vector->list v)]
        [(u16vector? v) (u16vector->list v)]
        [(u8vector? v) (u8vector->list v)]
        [else (error who "不能转成数值向量：~s" x)]))

;; 整数转换：逐元素取整并做范围检查
(define (int-list who lo hi xs)
  (map (lambda (y)
         (define i (real->int who y))
         (unless (<= lo i hi)
           (error who "元素 ~s 超出 ~a..~a" y lo hi))
         i)
       xs))

(define (->f32vector x)
  (if (f32vector? x) x
      (list->f32vector (map exact->inexact (number-list '->f32vector x)))))

(define (->f64vector x)
  (if (f64vector? x) x
      (list->f64vector (map exact->inexact (number-list '->f64vector x)))))

(define (->s32vector x)
  (if (s32vector? x) x
      (list->s32vector (int-list '->s32vector -2147483648 2147483647 (number-list '->s32vector x)))))

(define (->u32vector x)
  (if (u32vector? x) x
      (list->u32vector (int-list '->u32vector 0 4294967295 (number-list '->u32vector x)))))

(define (->u16vector x)
  (if (u16vector? x) x
      (list->u16vector (int-list '->u16vector 0 65535 (number-list '->u16vector x)))))

(define (->u8vector x)
  (if (u8vector? x) x
      (list->u8vector (int-list '->u8vector 0 255 (number-list '->u8vector x)))))
