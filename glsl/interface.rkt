#lang racket/base
;; ============================================================
;; 块 1 · (glsl) 内 · glsl/interface.rkt —— GLSL 类型模型 + 一个 shader 的接口反射
;;
;; ★★★ 暂定（tentative）★★★
;;   本模块是"获取类型信息"的实现，命名与数据结构**尚未定稿**，仍可能调整：
;;     - 字段名 / 枚举取值（kind、qualifier、layout 形状）可能变；
;;     - 反射范围（收哪些声明、是否含 struct 定义）可能变；
;;     - 可能拆分/合并模块。
;;   在定稿前，请把它当作「先能用」的版本，不要在上面堆过多、过脆的依赖。
;;
;; 本模块只做「读」，且不做组合（不合并多个 shader、不生成 setter、不碰 GL）：
;;   ① 用一种结构表达**所有** GLSL 类型：
;;        scalar / vector / matrix / sampler / image / array / struct / block / void
;;   ② 把 shader 声明出来的东西（uniform/in/out/const/buffer/shared 及其 struct/block）
;;      表达成统一的「名字 + 类型 + 限定符 + layout」。
;;   ③ 提供只读查询：按限定符 / 类型 kind / layout 键取子集，按名字查声明。
;;
;; 统一的两把数据结构（暂定）：
;;   shader-type  —— 类型（kind 区分；array 用 elem/len，struct/block 用 fields）
;;   shader-var   —— 一条声明（接口变量 与 struct/block 成员**共用**同一结构）
;; ============================================================

(require racket/list racket/string racket/match
         "names.rkt"
         (only-in "../types.rkt"
                  builtin-type-names
                  [builtin-scalar-names scalar-names]
                  [builtin-vector-names vector-names]
                  [builtin-matrix-square-names matrix-square-names]
                  [builtin-matrix-rect-names matrix-rect-names]
                  [builtin-sampler-names sampler-names]
                  [builtin-image-names image-names]
                  type-canonical-name type-canonical-symbol
                  type-alias? type-alias-forms builtin-type?))

;; ★ 暂定 API（见文件头）：下面这些名/形都可能再变
(provide
 ;; ---- 类型 ----
 shader-type? shader-type
 shader-type-kind shader-type-name shader-type-source-name shader-type-base shader-type-dims
 shader-type-len shader-type-elem shader-type-args shader-type-size shader-type-fields
 shader-type-scalar? shader-type-vector? shader-type-matrix? shader-type-sampler? shader-type-image?
 shader-type-array? shader-type-struct? shader-type-block? shader-type-void?
 ;; 数组/结构/块的构造（尺寸一并算好）
 shader-array-type shader-struct-type shader-block-type
 ;; ---- 声明（接口变量 / 结构成员共用）----
 shader-var? shader-var
 shader-var-name shader-var-source-name shader-var-type shader-var-qualifiers shader-var-layout
 shader-var-annotations shader-var-owner
 ;; ---- 查询（限定符 / kind / layout / 名字）----
 shader-var-has-qualifier? shader-var-layout-ref
 shader-interface-ref
 shader-interface-vars-with-qualifier
 shader-interface-vars-with-kind
 shader-interface-vars-with-layout
 ;; ---- 接口 ----
 shader-interface? shader-interface shader-interface-vars
 ;; ---- 内建类型 / 类型别名 ----
 builtin-type-of builtin-type-names
 type-canonical-name type-canonical-symbol
 type-alias? type-alias-forms builtin-type?
 ;; ---- datum 往返（宏展开期 ↔ 运行期）----
 shader-type->datum datum->shader-type
 shader-var->datum datum->shader-var
 shader-interface->datum datum->shader-interface)

;; ============================================================
;; 数据结构
;; ============================================================

;; 一个 GLSL 类型。
;;   kind   'scalar 'vector 'matrix 'sampler 'image 'array 'struct 'block 'void
;;   name   **canonical** 内建类型名（'float 'vec4 'mat3 'sampler2D）或 struct/block 的表面名；数组固定 'array
;;   base   元素基类型符号：'float 'int 'uint 'bool 'double；采样器/图像为其采样基类型；其余 #f
;;   dims   向量 (list 分量数)；矩阵 (list 列数 行数)；其余 '()
;;   len    数组长度（整数）或 #f（未定长）；其余 #f
;;   elem   数组元素类型（shader-type）；其余 #f
;;   args   类型参数（(listof shader-type)）——Slang 的 Texture2D<float4> / ConstantBuffer<T> 用；其余 '()
;;   size   字节数（自然布局，非 std140）；未知 #f
;;   fields struct/block 的成员（(listof shader-var)）；其余 '()
(struct shader-type (kind name base dims len elem args size fields) #:transparent)

;; 一条声明：接口变量、struct/block 成员都用它。
;;   name        符号（**表面名**：用户在 (glsl ...) 里写的 Racket 标识符）
;;   type        shader-type
;;   qualifiers  (listof symbol)  如 '(uniform) '(flat out) '(const)
;;   layout      (listof (or symbol (list symbol value)))  如 '((location 0)) '((std140) (binding 0))
;;   annotations (listof symbol)  语义/修饰符注解（Slang：'SV_Position 'nointerpolation）；GLSL 恒 '()
;;   owner       所属块的名字（Slang 的 cbuffer/ParameterBlock 成员）；顶层声明为 #f
;;
;; ★ name 与真正写进 GLSL 文本的标识符可能不同：
;;   表面名 wow-name-type → GLSL 名 wow_name_type
;;   表面名 gl-position   → GLSL 名 gl_Position
;;   shader-var-source-name 给出后者；保留前者是为了 Racket 侧生成 setter / 与 CPU struct 对齐。
(struct shader-var (name type qualifiers layout annotations owner) #:transparent)

;; 这个声明在 GLSL 文本里的标识符（symbol）。
(define (shader-var-source-name v)
  (glsl-name-symbol (shader-var-name v)))

;; 类型名在 GLSL 文本里的拼写；数组取元素类型名（'array 本身不是 GLSL 类型标识符）。
(define (shader-type-source-name t)
  (if (shader-type-array? t)
      (shader-type-source-name (shader-type-elem t))
      (glsl-name-symbol (shader-type-name t))))

;; 一段 shader 源码声明的全部接口变量（按源码出现顺序）
(struct shader-interface (vars) #:transparent)

;; ============================================================
;; 内建类型：名字 → shader-type
;; ============================================================

;; 规范类型名清单与别名表在 types.rkt（与值层共享）。

(define (base-component-bytes base) (if (eq? base 'double) 8 4))

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
           [(memq sym vector-names) (parse-vector sym)]
           [(memq sym matrix-square-names) (parse-matrix sym)]
           [(memq sym matrix-rect-names) (parse-matrix sym)]
           [(memq sym sampler-names) (shader-type 'sampler sym (sampler-base sym) '() #f #f '() #f '())]
           [(memq sym image-names) (shader-type 'image sym (image-base sym) '() #f #f '() #f '())]
           [else #f]))))

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
;; 查询：在反射出的接口上按「限定符 / 类型 kind / layout / 名字」取子集
;;
;;   只读，不做组合（不合并阶段、不生成 setter、不碰 GL）。
;;   名字 lookup 是线性扫描：接口通常几十条，够用、也不额外存索引。
;;   三个 vars-with-* 都保持源码顺序。
;; ============================================================

;; 这条声明带某个限定符吗？qualifiers 是符号列表、顺序保留（如 (flat out)）
(define (shader-var-has-qualifier? v q)
  (and (memq q (shader-var-qualifiers v)) #t))

;; 取某个 layout 项的值：
;;   (location 0) → 0      (std140) → #t（有键无值）    没有该键 → default
;; 0 在 Racket 是真值，所以它也能当「有没有这个 layout 键」用。
;; 键名按标识符规则归一：'local-size-x 与 'local_size_x 等价。
(define (shader-var-layout-ref v key [default #f])
  (define target (glsl-name-symbol key))
  (or (for/first ([it (in-list (shader-var-layout v))]
                  #:when (eq? (glsl-name-symbol (car it)) target))
        (if (null? (cdr it)) #t (cadr it)))
      default))

;; 名字 → 声明；找不到 #f。名字可以写符号 'uColor 或字符串 "uColor"。
;; 同时接受表面名（u-color）与 GLSL 名（u_color）；内建变量别名也按同一规则处理。
(define (shader-interface-ref ifc name)
  (define sym (if (string? name) (string->symbol name) name))
  (define target (glsl-name-symbol sym))
  (for/first ([v (in-list (shader-interface-vars ifc))]
              #:when (or (eq? (shader-var-name v) sym)
                         (eq? (shader-var-source-name v) target)))
    v))

;; 带某个限定符的全部声明
(define (shader-interface-vars-with-qualifier ifc q)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (shader-var-has-qualifier? v q))
    v))

;; 类型 kind 匹配的全部声明（kind 取 shader-type-kind 的取值：'scalar 'vector … 'block）
(define (shader-interface-vars-with-kind ifc kind)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (eq? (shader-type-kind (shader-var-type v)) kind))
    v))

;; 带某个 layout 键的全部声明
(define (shader-interface-vars-with-layout ifc key)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (shader-var-layout-ref v key))
    v))

;; ============================================================
;; 数组 / 结构 / 块 的构造（尺寸一并算好）
;; ============================================================

(define (sum-member-size fields)
  (for/fold ([acc 0]) ([f (in-list fields)])
    (define sz (shader-type-size (shader-var-type f)))
    (and acc sz (+ acc sz))))

;; 数组：elem 类型 + 长度（#f = 未定长）
(define (shader-array-type elem len)
  (shader-type 'array 'array #f '() len elem '()
             (and len (shader-type-size elem) (* len (shader-type-size elem))) '()))

(define (shader-struct-type name fields)
  (shader-type 'struct name #f '() #f #f '() (sum-member-size fields) fields))

(define (shader-block-type name fields)
  (shader-type 'block name #f '() #f #f '() (sum-member-size fields) fields))

;; ============================================================
;; datum 往返：宏展开期算好 → quote 进代码 → 运行期重建
;;   type-datum = (kind name base dims len elem-datum (arg-datum ...) size (var-datum ...))
;;   var-datum  = (name type-datum qualifiers layout annotations owner)
;;   interface-datum = (listof var-datum)
;; ============================================================

(define (shader-type->datum t)
  (list (shader-type-kind t) (shader-type-name t) (shader-type-base t) (shader-type-dims t)
        (shader-type-len t)
        (and (shader-type-elem t) (shader-type->datum (shader-type-elem t)))
        (map shader-type->datum (shader-type-args t))
        (shader-type-size t)
        (map shader-var->datum (shader-type-fields t))))

(define (datum->shader-type d)
  (match d
    [(list kind name base dims len elem args size fields)
     (shader-type kind name base dims len
                (and elem (datum->shader-type elem))
                (map datum->shader-type args) size
                (map datum->shader-var fields))]))

(define (shader-var->datum v)
  (list (shader-var-name v) (shader-type->datum (shader-var-type v))
        (shader-var-qualifiers v) (shader-var-layout v)
        (shader-var-annotations v) (shader-var-owner v)))

(define (datum->shader-var d)
  (match d
    [(list name type qualifiers layout annotations owner)
     (shader-var name (datum->shader-type type) qualifiers layout annotations owner)]))

(define (shader-interface->datum i)
  (map shader-var->datum (shader-interface-vars i)))

(define (datum->shader-interface d)
  (shader-interface (map datum->shader-var d)))
