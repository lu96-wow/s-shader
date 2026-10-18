#lang racket/base

;; ============================================================
;; Slang 方言 · slang/types.rkt —— 类型目录（拼写 ↔ canonical）
;;
;; 两个方向：
;;   slang-type-of        Slang 拼写（float3 / float4x4）→ shader-type
;;   slang-type-spelling  canonical（vec3 / mat4）      → Slang 拼写
;;
;; ★ canonical 名沿用 core 的类型名词汇（vec3 / mat4 / sampler2D …）：
;;   CPU 值层、接口反射、两个方言都认同一套 canonical 名，
;;   只是**写进源码的拼写**不同（GLSL: vec3，Slang: float3）。
;;
;; 参数化类型（Texture2D<float4> / StructuredBuffer<T> / ConstantBuffer<T>）
;; 由 rewrite 用 shader-type 的 args 槽构造，不走本表。
;; ============================================================

(require racket/list racket/string
         shader/types
         shader/type)

(provide slang-type-of slang-type-spelling
         slang-vector-spelling slang-matrix-spelling)

;; ---------- 双向表 ----------

;; 标量：两边同名
(define scalar-pairs '((void . void) (float . float) (int . int) (uint . uint) (bool . bool) (double . double)))

;; 向量：canonical vec3 ⇄ float3
(define vector-pairs
  (for*/list ([pre '((#f . "float") (i . "int") (u . "uint") (b . "bool") (d . "double"))]
              [n '(2 3 4)])
    (define glsl-pre (car pre))
    (define slang-pre (cdr pre))
    (cons (string->symbol (format "~avec~a" (if glsl-pre (symbol->string glsl-pre) "") n))
          (string->symbol (format "~a~a" slang-pre n)))))

;; 矩阵：canonical mat3x2（3 列 2 行）⇄ Slang/HLSL float2x3（2 行 3 列）
;; ★ 注意命名约定相反：GLSL 写「列 x 行」，HLSL/Slang 写「行 x 列」。
;;   方阵两边同形（mat4 ⇄ float4x4）。
(define matrix-pairs
  (for*/list ([pre '((#f . "float") (d . "double"))]
              [c '(2 3 4)] [r '(2 3 4)])
    (define glsl-pre (car pre))
    (define slang-pre (cdr pre))
    (define canon (string->symbol
                   (format "~amat~a~a~a"
                           (if glsl-pre (symbol->string glsl-pre) "")
                           c (if (= c r) "" "x") (if (= c r) "" (format "~a" r)))))
    (define slang (string->symbol (format "~a~ax~a" slang-pre r c)))
    (cons canon slang)))

(define canon->slang
  (for/hash ([p (in-list (append scalar-pairs vector-pairs matrix-pairs))])
    (values (car p) (cdr p))))

(define slang->canon
  (for/hash ([p (in-list (append scalar-pairs vector-pairs matrix-pairs))])
    (values (cdr p) (car p))))

;; ---------- 查询 ----------

;; canonical 名 → Slang 拼写（'vec3 → 'float3；未知则原样）
(define (slang-type-spelling canon)
  (hash-ref canon->slang canon canon))

;; canonical 名 → Slang 的向量/矩阵拼写（发射类型时用；kind 不符则原样）
(define (slang-vector-spelling canon) (slang-type-spelling canon))
(define (slang-matrix-spelling canon) (slang-type-spelling canon))

;; Slang 拼写 → shader-type；不是内建类型返回 #f（可能是 struct 名）
(define (slang-type-of sym)
  (and (symbol? sym)
       (let* ([canon (hash-ref slang->canon sym #f)]
              [t (and canon (builtin-type-of-canonical canon))])
         t)))

;; 由 canonical 名构造 shader-type（尺寸按自然布局算）
(define (builtin-type-of-canonical canon)
  (cond
    [(memq canon '(void)) (shader-type 'void 'void #f '() #f #f '() #f '())]
    [(memq canon '(float int uint bool double))
     (shader-type 'scalar canon canon '() #f #f '() (base-component-bytes canon) '())]
    [(regexp-match #rx"^[iubd]?vec([234])$" (symbol->string canon))
     => (lambda (m)
          (define base (case (string-ref (symbol->string canon) 0)
                         [(#\i) 'int] [(#\u) 'uint] [(#\b) 'bool] [(#\d) 'double]
                         [else 'float]))
          (define n (string->number (list-ref m 1)))
          (shader-type 'vector canon base (list n) #f #f '()
                       (* n (base-component-bytes base)) '()))]
    [(regexp-match #rx"^(d)?mat([234])(x([234]))?$" (symbol->string canon))
     => (lambda (m)
          (define base (if (list-ref m 1) 'double 'float))
          (define c (string->number (list-ref m 2)))
          (define r (if (list-ref m 4) (string->number (list-ref m 4)) c))
          (shader-type 'matrix canon base (list c r) #f #f '()
                       (* c r (base-component-bytes base)) '()))]
    [else #f]))
