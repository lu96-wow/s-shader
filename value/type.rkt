#lang racket/base

;; ============================================================
;; 值层 · value/type.rkt —— GLSL 类型 → 存储属性的唯一来源
;;
;; 「逻辑：类型与存储」。这是整个项目里「类型 → 分量数 / 存储类别 / 字节数」的唯一一张表。
;; 只覆盖「CPU 有数据表示」的类型；sampler*/image*/void/atomic_uint 属于
;; shader/type.rkt 的完整类型模型。
;;
;; 存储类别 kind：
;;   f32 → float/vec*/mat*        （f32vector）
;;   f64 → double/dvec*/dmat*     （f64vector）
;;   s32 → int/ivec*              （s32vector）
;;   u32 → uint/uvec*/bool/bvec*  （u32vector；GLSL bool 在内存是 32 位 0/1）
;;   u16 → 无 GLSL 对应（索引缓冲） （u16vector）
;;   u8  → 无 GLSL 对应（纹理像素） （u8vector，即 bytes）
;;
;; 命名：[Racket 传统]。GLSL 名（shader-size/shader-kind/…）在 rename-type.rkt。
;; ============================================================

(require ffi/vector
         "../types.rkt")

(provide type-table type-entry type-known? type-elements type-kind
         type-component-bytes type-byte-size type-stride
         kind-component-bytes kind-vector? kind-length kind-ref kind-set!
         kind-ctor kind-make kind->name
         float-kind? double-kind? int-kind?)

;; ---------- 表 ----------

;; 每项：(类型名 元素/分量数 存储类别)；矩阵列主序。
;; 矩形矩阵 matCxR / dmatCxR（C 列 R 行）也在表里：GLSL 有、CPU 也能表示（c*r 个标量），
;; 其 size/kind 与方阵同源。构造器与四则运算目前只覆盖方阵。
(define square-matrix-table
  '((mat2    4 f32) (mat3   9 f32) (mat4  16 f32)
    (dmat2   4 f64) (dmat3  9 f64) (dmat4 16 f64)))

(define rectangular-matrix-table
  (for*/list ([pre+kind '((mat . f32) (dmat . f64))]
              [c '(2 3 4)] [r '(2 3 4)] #:unless (= c r))
    (list (string->symbol (format "~a~ax~a" (car pre+kind) c r)) (* c r) (cdr pre+kind))))

(define type-table
  (append
   '((float   1 f32) (vec2   2 f32) (vec3   3 f32) (vec4   4 f32)
     (double  1 f64) (dvec2  2 f64) (dvec3  3 f64) (dvec4  4 f64)
     (int     1 s32) (ivec2  2 s32) (ivec3  3 s32) (ivec4  4 s32)
     (uint    1 u32) (uvec2  2 u32) (uvec3  3 u32) (uvec4  4 u32)
     (bool    1 u32) (bvec2  2 u32) (bvec3  3 u32) (bvec4  4 u32))
   square-matrix-table
   rectangular-matrix-table))

;; 类型名先规范化：vec-3 / vec_3 → vec3；未知类型原样。
(define (type-canonical t) (type-canonical-symbol t))

(define (type-entry t)
  (or (assq (type-canonical t) type-table)
      (error 'type "未知 GLSL 类型（或无可表示的 CPU 类型）：~s" t)))

(define (type-known? t)
  (and (or (symbol? t) (string? t))
       (and (assq (type-canonical t) type-table) #t)))
(define (type-elements t) (cadr (type-entry t)))
(define (type-kind t) (caddr (type-entry t)))

;; ---------- 字节 ----------

(define (kind-component-bytes k)
  (case k [(u8) 1] [(u16) 2] [(f64) 8] [else 4]))
(define (type-component-bytes t) (kind-component-bytes (type-kind t)))
(define (type-byte-size t) (* (type-elements t) (type-component-bytes t)))

;; 交错属性总字节数（既算 stride，也算前缀 offset）
(define (type-stride . types) (apply + (map type-byte-size types)))

;; ---------- 类别谓词 ----------

(define (float-kind? k) (or (eq? k 'f32) (eq? k 'f64)))
(define (double-kind? k) (eq? k 'f64))
(define (int-kind? k) (or (eq? k 's32) (eq? k 'u32) (eq? k 'u16) (eq? k 'u8)))

;; ---------- 类别 → cvector 操作 ----------

(define (kind-vector? k)
  (case k [(f32) f32vector?] [(f64) f64vector?] [(s32) s32vector?] [(u32) u32vector?]
          [(u16) u16vector?] [(u8) u8vector?]))
(define (kind-length k)
  (case k [(f32) f32vector-length] [(f64) f64vector-length]
          [(s32) s32vector-length] [(u32) u32vector-length]
          [(u16) u16vector-length] [(u8) u8vector-length]))
(define (kind-ref k)
  (case k [(f32) f32vector-ref] [(f64) f64vector-ref]
          [(s32) s32vector-ref] [(u32) u32vector-ref]
          [(u16) u16vector-ref] [(u8) u8vector-ref]))
(define (kind-set! k)
  (case k [(f32) f32vector-set!] [(f64) f64vector-set!]
          [(s32) s32vector-set!] [(u32) u32vector-set!]
          [(u16) u16vector-set!] [(u8) u8vector-set!]))
(define (kind-ctor k)
  (case k [(f32) f32vector] [(f64) f64vector] [(s32) s32vector] [(u32) u32vector]
          [(u16) u16vector] [(u8) u8vector]))
(define (kind-make k)
  (case k [(f32) make-f32vector] [(f64) make-f64vector]
          [(s32) make-s32vector] [(u32) make-u32vector]
          [(u16) make-u16vector] [(u8) make-u8vector]))
(define (kind->name k)
  (case k [(f32) "f32vector"] [(f64) "f64vector"]
          [(s32) "s32vector"] [(u32) "u32vector"]
          [(u16) "u16vector"] [(u8) "u8vector"]))
