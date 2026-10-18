#lang racket/base

;; ============================================================
;; core · shader/type.rkt —— 类型模型 + 声明模型（两个方言共用）
;;
;; 只做「读」的**数据模型**，不含任何方言知识：
;;   ① 用一种结构表达**所有**着色语言类型：
;;        scalar / vector / matrix / sampler / image / array / struct / block / void
;;   ② 把声明表达成统一的「名字 + 类型 + 限定符 + layout + 注解 + 所属块」。
;;
;; 两把数据结构：
;;   shader-type —— 类型（kind 区分；array 用 elem/len；struct/block 用 fields；
;;                  Slang 的参数化类型用 args）
;;   shader-var  —— 一条声明（接口变量 与 struct/block 成员**共用**同一结构）
;;
;; ★ 方言无关性：本模块不知道 vec3 是不是内建类型，也不知道名字怎么写进源码。
;;   类型名 → shader-type 的目录在方言层（glsl/types.rkt、slang/types.rkt）；
;;   「表面名 → 源码里的标识符」由方言在构造时算好，存进 source-name 字段。
;;
;; 接口反射（按名字/限定符/kind 查询 + datum 往返）见 interface.rkt。
;; ============================================================

(require racket/string)

(provide
 ;; ---- 类型 ----
 shader-type? shader-type
 shader-type-kind shader-type-name shader-type-base shader-type-dims
 shader-type-len shader-type-elem shader-type-args shader-type-size shader-type-fields
 shader-type-scalar? shader-type-vector? shader-type-matrix? shader-type-sampler?
 shader-type-image? shader-type-array? shader-type-struct? shader-type-block? shader-type-void?
 ;; 数组/结构/块的构造（尺寸一并算好）
 shader-array-type shader-struct-type shader-block-type
 base-component-bytes sum-member-size
 ;; ---- 声明（接口变量 / 结构成员共用）----
 shader-var? shader-var
 shader-var-name shader-var-source-name shader-var-type shader-var-qualifiers
 shader-var-layout shader-var-annotations shader-var-owner
 shader-var-has-qualifier? shader-var-layout-ref)

;; ============================================================
;; 数据结构
;; ============================================================

;; 一个类型。
;;   kind   'scalar 'vector 'matrix 'sampler 'image 'array 'struct 'block 'void
;;   name   canonical 名（'float 'vec4 'mat3 'sampler2D，由方言目录规范化）或 struct/block 的表面名；数组固定 'array
;;   base   元素基类型符号：'float 'int 'uint 'bool 'double；采样器/图像为其采样基类型；其余 #f
;;   dims   向量 (list 分量数)；矩阵 (list 列数 行数)；其余 '()
;;   len    数组长度（整数）或 #f（未定长）；其余 #f
;;   elem   数组元素类型（shader-type）；其余 #f
;;   args   类型参数（(listof shader-type)）——Slang 的 Texture2D<float4> / ConstantBuffer<T> 用；其余 '()
;;   size   字节数（自然布局，非 std140）；未知 #f
;;   fields struct/block 的成员（(listof shader-var)）；其余 '()
(struct shader-type (kind name base dims len elem args size fields) #:transparent)

;; 一条声明：接口变量、struct/block 成员都用它。
;;   name        符号（**表面名**：用户在 (glsl ...) / (slang ...) 里写的 Racket 标识符）
;;   source-name 符号（**写进源码的标识符**：由方言在构造时算好）
;;                  GLSL: u-model-view → u_model_view、gl-position → gl_Position
;;                  Slang: 同样走它自己的规则
;;   type        shader-type
;;   qualifiers  (listof symbol)  如 '(uniform) '(flat out) '(const)
;;   layout      (listof (list symbol value?))  如 '((location 0)) '((std140))；键已由方言规范化
;;   annotations (listof symbol)  语义/修饰符注解（Slang：'SV_Position 'nointerpolation）；GLSL 恒 '()
;;   owner       所属块的名字（Slang 的 cbuffer/ParameterBlock 成员）；顶层声明为 #f
;;
;; ★ 保留表面名是为了 Racket 侧生成 setter / 与 CPU struct 对齐；
;;   和驱动/编译器打交道的名字用 source-name。
(struct shader-var (name source-name type qualifiers layout annotations owner) #:transparent)

;; ============================================================
;; 尺寸
;; ============================================================

(define (base-component-bytes base) (if (eq? base 'double) 8 4))

(define (sum-member-size fields)
  (for/fold ([acc 0]) ([f (in-list fields)])
    (define sz (shader-type-size (shader-var-type f)))
    (and acc sz (+ acc sz))))

;; ============================================================
;; 类型谓词
;; ============================================================

(define (shader-type-scalar? t) (eq? (shader-type-kind t) 'scalar))
(define (shader-type-vector? t) (eq? (shader-type-kind t) 'vector))
(define (shader-type-matrix? t) (eq? (shader-type-kind t) 'matrix))
(define (shader-type-sampler? t) (eq? (shader-type-kind t) 'sampler))
(define (shader-type-image? t) (eq? (shader-type-kind t) 'image))
(define (shader-type-array? t) (eq? (shader-type-kind t) 'array))
(define (shader-type-struct? t) (eq? (shader-type-kind t) 'struct))
(define (shader-type-block? t) (eq? (shader-type-kind t) 'block))
(define (shader-type-void? t) (eq? (shader-type-kind t) 'void))

;; ============================================================
;; 数组 / 结构 / 块 的构造（尺寸一并算好）
;; ============================================================

;; 数组：elem 类型 + 长度（#f = 未定长）
(define (shader-array-type elem len)
  (shader-type 'array 'array #f '() len elem '()
               (and len (shader-type-size elem) (* len (shader-type-size elem))) '()))

(define (shader-struct-type name fields)
  (shader-type 'struct name #f '() #f #f '() (sum-member-size fields) fields))

(define (shader-block-type name fields)
  (shader-type 'block name #f '() #f #f '() (sum-member-size fields) fields))

;; ============================================================
;; 声明查询（只读；不做组合、不生成 setter、不碰 GL/Vulkan）
;; ============================================================

;; 这条声明带某个限定符吗？qualifiers 是符号列表、顺序保留（如 (flat out)）
(define (shader-var-has-qualifier? v q)
  (and (memq q (shader-var-qualifiers v)) #t))

;; 取某个 layout 项的值：
;;   (location 0) → 0      (std140) → #t（有键无值）    没有该键 → default
;; 0 在 Racket 是真值，所以它也能当「有没有这个 layout 键」用。
;; ★ layout 键在构造时已由方言规范化（local-size-x → local_size_x）；
;;   查询时两种拼写都接受（只做通用的 '-'→'_'，不含任何方言表）。
(define (shader-var-layout-ref v key [default #f])
  (define target (string->symbol (string-replace (format "~a" key) "-" "_")))
  (or (for/first ([it (in-list (shader-var-layout v))]
                  #:when (eq? (car it) target))
        (if (null? (cdr it)) #t (cadr it)))
      default))
