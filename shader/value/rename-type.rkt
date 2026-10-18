#lang racket/base

;; ============================================================
;; 值层 · value/rename-type.rkt —— GLSL 风格命名（类型与存储）
;;
;; 纯 alias：value/type.rkt 的 Racket 名 → GLSL 名。零逻辑。
;; ============================================================

(require "type.rkt")

(provide shader-size shader-kind shader-byte-size shader-stride shader-stride-bytes shader-type-table
         ;; 新名（消歧；旧名保留为 deprecated）
         shader-element-count shader-storage-kind shader-stride-elements)

(define (shader-size t) (type-elements t))
(define (shader-kind t) (type-kind t))
(define (shader-byte-size t) (type-byte-size t))
(define (shader-stride . ts) (apply + (map type-elements ts)))
(define (shader-stride-bytes . ts) (apply type-stride ts))

;; 旧的 alist 形状：(类型名 . 元素数)
(define shader-type-table (map (lambda (e) (cons (car e) (cadr e))) type-table))

;; ---------- 新名（消歧） ----------
;; shader-element-count  元素/分量数（不是字节）
;; shader-storage-kind   存储类别 f32/f64/s32/u32（区别 interface 的 shader-type-kind）
;; shader-stride-elements  按“元素”计的 stride（字节版是 shader-stride-bytes）
(define shader-element-count shader-size)
(define shader-storage-kind shader-kind)
(define shader-stride-elements shader-stride)
