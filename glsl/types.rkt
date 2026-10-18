#lang racket/base

;; ============================================================
;; GLSL 方言 · glsl/types.rkt —— 类型目录（拼写 → shader-type）
;;
;; 只有「名字 → 类型结构」的方言知识：
;;   vec3 / ivec2 / mat4 / mat3x2 / sampler2D / image2D / atomic_uint / void …
;; 名字的**规范化与别名表**在 core 的 types.rkt（与 CPU 值层共享，
;; 因为 vec3 这些拼写是两个方言共同的 canonical 名）。
;;
;; Slang 方言会另有一份 slang/types.rkt：
;;   名字是 float3 / float4x4 / Texture2D<float4> / StructuredBuffer<T> …
;;   但 canonical 名仍归一成 vec3 / mat4（CPU 值层与接口反射共用同一套）。
;; ============================================================

(require racket/list racket/string
         shader/types
         shader/type)

(provide builtin-type-of base-of-prefix
         parse-vector parse-matrix sampler-base image-base)

(define (base-of-prefix prefix)
  (case prefix [("") 'float] [("i") 'int] [("u") 'uint] [("b") 'bool] [("d") 'double]
    [else #f]))

;; vec4 / ivec3 / uvec2 / bvec4 / dvec4
(define (parse-vector name)
  (define s (symbol->string name))
  (define n (string->number (substring s (sub1 (string-length s)))))
  (define base (base-of-prefix (substring s 0 (- (string-length s) 4))))
  (shader-type 'vector name base (list n) #f #f '() (* n (base-component-bytes base)) '()))

;; mat4 / mat3x2 / dmat4 / dmat2x3
(define (parse-matrix name)
  (define s (symbol->string name))
  (define dm? (string-prefix? s "dmat"))
  (define rest (substring s (if dm? 4 3)))
  (define dims
    (if (string-contains? rest "x")
        (map string->number (string-split rest "x"))
        (let ([n (string->number rest)]) (list n n))))
  (define base (if dm? 'double 'float))
  (shader-type 'matrix name base dims #f #f '()
               (* (car dims) (cadr dims) (base-component-bytes base)) '()))

(define (sampler-base name)
  (define s (symbol->string name))
  (cond [(string-prefix? s "isampler") 'int]
        [(string-prefix? s "usampler") 'uint]
        [else 'float]))

(define (image-base name)
  (define s (symbol->string name))
  (cond [(string-prefix? s "iimage") 'int]
        [(string-prefix? s "uimage") 'uint]
        [else 'float]))

;; 符号/别名 → shader-type；不是内建类型返回 #f（可能是 struct 名）。
;; 别名（vec-3 / sampler-2d …）先规范成 canonical（vec3 / sampler2D），
;; 所以反射里的 shader-type-name 永远是 canonical 名。
(define (builtin-type-of sym)
  (and (symbol? sym)
       (let ([sym (type-canonical-symbol sym)])
         (cond
           [(eq? sym 'void) (shader-type 'void 'void #f '() #f #f '() #f '())]
           [(eq? sym 'atomic_uint) (shader-type 'scalar 'atomic_uint 'uint '() #f #f '() 4 '())]
           [(memq sym '(float int uint bool double))
            (shader-type 'scalar sym sym '() #f #f '() (base-component-bytes sym) '())]
           [(memq sym builtin-vector-names) (parse-vector sym)]
           [(or (memq sym builtin-matrix-square-names) (memq sym builtin-matrix-rect-names))
            (parse-matrix sym)]
           [(memq sym builtin-sampler-names)
            (shader-type 'sampler sym (sampler-base sym) '() #f #f '() #f '())]
           [(memq sym builtin-image-names)
            (shader-type 'image sym (image-base sym) '() #f #f '() #f '())]
           [else #f]))))
