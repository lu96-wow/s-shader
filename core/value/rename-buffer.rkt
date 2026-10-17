#lang racket/base

;; ============================================================
;; 值层 · value/rename-buffer.rkt —— GLSL 风格命名（缓冲 / 拼接 / 标量数组）
;;
;; 主要是 alias：value/buffer.rkt 的 Racket 名 → GLSL 名。零逻辑。
;; CPU 向量数组（vecN[]）按 **名字区分元素类型**，对齐 vec3/dvec3/ivec3/uvec3：
;;   vec-array=f32  dvec-array=f64  ivec-array=s32  uvec-array=u32
;; kind 由内部 data 的 Racket 向量类型隐含，不传参、不存字段。
;; 元素取用的别名（vec-array-count/ref/set!）在 rename-access.rkt。
;;
;; u8/u16 标量数组（u8-array / u16-array）表示直接是 ffi u8vector/u16vector（零包装）：
;; GLSL 没有 u8/u16 类型，它们只作 CPU 标量序列（索引缓冲 / 纹理像素）。
;; ============================================================

(require ffi/vector "buffer.rkt")

(provide vec-array dvec-array ivec-array uvec-array
         make-vec-array make-dvec-array make-ivec-array make-uvec-array
         vec-array? vec-array-width vec-array-data
         ;; u8/u16 标量数组（索引 / 像素）
         u8-array make-u8-array u8-array? u8-array-length u8-array-ref u8-array-set! u8-array-data
         u16-array make-u16-array u16-array? u16-array-length u16-array-ref u16-array-set! u16-array-data
         ;; 旧名（deprecated，等价别名，下个大版本删）
         gl-vec make-gl-vec gl-vec? gl-vec-width gl-vec->f32vector
         concat-vecs concat-vecs! concat-dvecs concat-dvecs!
         concat-ivecs concat-ivecs! concat-uvecs concat-uvecs!)

;; ---------- CPU 向量数组（vecN[]），按名字区分元素类型 ----------
;; vec-array-data 是零拷贝取内部 ffi 向量（f32/f64/s32/u32 都可能）；
;; 需要“转换”（如 f64→f32）时用 convert.rkt 的 ->f32vector。
(define (vec-array . vs)  (vec-buffer-from-kind 'vec-array  'f32 vs))
(define (dvec-array . vs) (vec-buffer-from-kind 'dvec-array 'f64 vs))
(define (ivec-array . vs) (vec-buffer-from-kind 'ivec-array 's32 vs))
(define (uvec-array . vs) (vec-buffer-from-kind 'uvec-array 'u32 vs))

(define (make-vec-array n template)  (make-vec-buffer-kind 'make-vec-array  'f32 n template))
(define (make-dvec-array n template) (make-vec-buffer-kind 'make-dvec-array 'f64 n template))
(define (make-ivec-array n template) (make-vec-buffer-kind 'make-ivec-array 's32 n template))
(define (make-uvec-array n template) (make-vec-buffer-kind 'make-uvec-array 'u32 n template))

(define vec-array? vec-buffer?)
(define vec-array-width vec-buffer-width)
(define vec-array-data vec-buffer-data)

;; ---------- 旧名（deprecated，等价别名）----------
(define gl-vec vec-array)
(define make-gl-vec make-vec-array)
(define gl-vec? vec-array?)
(define gl-vec-width vec-array-width)
(define gl-vec->f32vector vec-array-data)

;; ---------- 拼接（名字区分元素类型）----------
(define concat-vecs concat-vectors)
(define concat-vecs! concat-vectors!)
(define concat-dvecs concat-dvectors)
(define concat-dvecs! concat-dvectors!)
(define concat-ivecs concat-s32vectors)
(define concat-ivecs! concat-s32vectors!)
(define concat-uvecs concat-u32vectors)
(define concat-uvecs! concat-u32vectors!)

;; ---------- u8 / u16 标量数组（索引 / 像素）----------
;; 表示就是裸 ffi u8vector/u16vector（u8vector 即 bytes），零包装；
;; u8-array-data / u16-array-data 是零拷贝恒等。

(define (ensure-u8 who x)
  (unless (and (exact? x) (integer? x) (<= 0 x 255))
    (error who "u8 元素应为 0..255 的整数，实际 ~s" x))
  x)

(define (ensure-u16 who x)
  (unless (and (exact? x) (integer? x) (<= 0 x 65535))
    (error who "u16 元素应为 0..65535 的整数，实际 ~s" x))
  x)

(define (u8-array . xs) (apply u8vector (for/list ([x xs]) (ensure-u8 'u8-array x))))
(define (make-u8-array n init) (make-u8vector n (ensure-u8 'make-u8-array init)))
(define u8-array? u8vector?)
(define u8-array-length u8vector-length)
(define u8-array-ref u8vector-ref)
(define u8-array-set! u8vector-set!)
(define (u8-array-data a) a)

(define (u16-array . xs) (apply u16vector (for/list ([x xs]) (ensure-u16 'u16-array x))))
(define (make-u16-array n init) (make-u16vector n (ensure-u16 'make-u16-array init)))
(define u16-array? u16vector?)
(define u16-array-length u16vector-length)
(define u16-array-ref u16vector-ref)
(define u16-array-set! u16vector-set!)
(define (u16-array-data a) a)
