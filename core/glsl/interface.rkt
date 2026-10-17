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
;;   glsl-type  —— 类型（kind 区分；array 用 elem/len，struct/block 用 fields）
;;   glsl-var   —— 一条声明（接口变量 与 struct/block 成员**共用**同一结构）
;; ============================================================

(require racket/list racket/string racket/match
         "names.rkt"
         (only-in "../vocab/type-names.rkt"
                  builtin-glsl-type-names
                  [builtin-scalar-names scalar-names]
                  [builtin-vector-names vector-names]
                  [builtin-matrix-square-names matrix-square-names]
                  [builtin-matrix-rect-names matrix-rect-names]
                  [builtin-sampler-names sampler-names]
                  [builtin-image-names image-names]
                  glsl-type-canonical-name glsl-type-canonical-symbol
                  glsl-type-alias? glsl-type-alias-forms glsl-builtin-type?))

;; ★ 暂定 API（见文件头）：下面这些名/形都可能再变
(provide
 ;; ---- 类型 ----
 glsl-type? glsl-type
 glsl-type-kind glsl-type-name glsl-type-glsl-name glsl-type-base glsl-type-dims
 glsl-type-len glsl-type-elem glsl-type-size glsl-type-fields
 glsl-scalar? glsl-vector? glsl-matrix? glsl-sampler? glsl-image?
 glsl-array? glsl-struct? glsl-block? glsl-void?
 ;; 数组/结构/块的构造（尺寸一并算好）
 glsl-array-type glsl-struct-type glsl-block-type
 ;; ---- 声明（接口变量 / 结构成员共用）----
 glsl-var? glsl-var
 glsl-var-name glsl-var-glsl-name glsl-var-type glsl-var-qualifiers glsl-var-layout
 ;; ---- 查询（限定符 / kind / layout / 名字）----
 glsl-var-has-qualifier? glsl-var-layout-ref
 glsl-interface-ref
 glsl-interface-vars-with-qualifier
 glsl-interface-vars-with-kind
 glsl-interface-vars-with-layout
 ;; ---- 接口 ----
 glsl-interface? glsl-interface glsl-interface-vars
 ;; ---- 内建类型 / 类型别名 ----
 builtin-glsl-type builtin-glsl-type? builtin-glsl-type-names
 glsl-type-canonical-name glsl-type-canonical-symbol
 glsl-type-alias? glsl-type-alias-forms glsl-builtin-type?
 ;; ---- datum 往返（宏展开期 ↔ 运行期）----
 glsl-type->datum datum->glsl-type
 glsl-var->datum datum->glsl-var
 glsl-interface->datum datum->glsl-interface)

;; ============================================================
;; 数据结构
;; ============================================================

;; 一个 GLSL 类型。
;;   kind   'scalar 'vector 'matrix 'sampler 'image 'array 'struct 'block 'void
;;   name   **canonical** 内建类型名（'float 'vec4 'mat3 'sampler2D）或 struct/block 的表面名；数组固定 'array
;;   base   元素基类型符号：'float 'int 'uint 'bool 'double；采样器/图像为其采样基类型；其余 #f
;;   dims   向量 (list 分量数)；矩阵 (list 列数 行数)；其余 '()
;;   len    数组长度（整数）或 #f（未定长）；其余 #f
;;   elem   数组元素类型（glsl-type）；其余 #f
;;   size   字节数（自然布局，非 std140）；未知 #f
;;   fields struct/block 的成员（(listof glsl-var)）；其余 '()
(struct glsl-type (kind name base dims len elem size fields) #:transparent)

;; 一条声明：接口变量、struct/block 成员都用它。
;;   name        符号（**表面名**：用户在 (glsl ...) 里写的 Racket 标识符）
;;   type        glsl-type
;;   qualifiers  (listof symbol)  如 '(uniform) '(flat out) '(const)
;;   layout      (listof (or symbol (list symbol value)))  如 '((location 0)) '((std140) (binding 0))
;;
;; ★ name 与真正写进 GLSL 文本的标识符可能不同：
;;   表面名 wow-name-type → GLSL 名 wow_name_type
;;   表面名 gl-position   → GLSL 名 gl_Position
;;   glsl-var-glsl-name 给出后者；保留前者是为了 Racket 侧生成 setter / 与 CPU struct 对齐。
(struct glsl-var (name type qualifiers layout) #:transparent)

;; 这个声明在 GLSL 文本里的标识符（symbol）。
(define (glsl-var-glsl-name v)
  (glsl-name-symbol (glsl-var-name v)))

;; 类型名在 GLSL 文本里的拼写；数组取元素类型名（'array 本身不是 GLSL 类型标识符）。
(define (glsl-type-glsl-name t)
  (if (glsl-array? t)
      (glsl-type-glsl-name (glsl-type-elem t))
      (glsl-name-symbol (glsl-type-name t))))

;; 一段 shader 源码声明的全部接口变量（按源码出现顺序）
(struct glsl-interface (vars) #:transparent)

;; ============================================================
;; 内建类型：名字 → glsl-type
;; ============================================================

;; 规范类型名清单与别名表在 core/vocab/type-names.rkt（与值层共享）。

(define (base-component-bytes base) (if (eq? base 'double) 8 4))

(define (base-of-prefix prefix)
  (case prefix [("") 'float] [("i") 'int] [("u") 'uint] [("b") 'bool] [("d") 'double]
    [else #f]))

;; vec4 / ivec3 / uvec2 / bvec4 / dvec4
(define (parse-vector name)
  (define s (symbol->string name))
  (define n (string->number (substring s (sub1 (string-length s)))))
  (define base (base-of-prefix (substring s 0 (- (string-length s) 4))))
  (glsl-type 'vector name base (list n) #f #f (* n (base-component-bytes base)) '()))

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
  (glsl-type 'matrix name base dims #f #f
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

;; 符号/别名 → glsl-type；不是内建类型返回 #f（可能是 struct 名）。
;; 别名（vec-3 / sampler-2d …）先规范成 canonical（vec3 / sampler2D），
;; 所以反射里的 glsl-type-name 永远是 canonical 名。
(define (builtin-glsl-type sym)
  (and (symbol? sym)
       (let ([sym (glsl-type-canonical-symbol sym)])
         (cond
           [(eq? sym 'void) (glsl-type 'void 'void #f '() #f #f #f '())]
           [(eq? sym 'atomic_uint) (glsl-type 'scalar 'atomic_uint 'uint '() #f #f 4 '())]
           [(memq sym '(float int uint bool double))
            (glsl-type 'scalar sym sym '() #f #f (base-component-bytes sym) '())]
           [(memq sym vector-names) (parse-vector sym)]
           [(memq sym matrix-square-names) (parse-matrix sym)]
           [(memq sym matrix-rect-names) (parse-matrix sym)]
           [(memq sym sampler-names) (glsl-type 'sampler sym (sampler-base sym) '() #f #f #f '())]
           [(memq sym image-names) (glsl-type 'image sym (image-base sym) '() #f #f #f '())]
           [else #f]))))

(define (builtin-glsl-type? sym) (and (builtin-glsl-type sym) #t))

;; ============================================================
;; 类型谓词
;; ============================================================

(define (glsl-scalar? t) (eq? (glsl-type-kind t) 'scalar))
(define (glsl-vector? t) (eq? (glsl-type-kind t) 'vector))
(define (glsl-matrix? t) (eq? (glsl-type-kind t) 'matrix))
(define (glsl-sampler? t) (eq? (glsl-type-kind t) 'sampler))
(define (glsl-image? t) (eq? (glsl-type-kind t) 'image))
(define (glsl-array? t) (eq? (glsl-type-kind t) 'array))
(define (glsl-struct? t) (eq? (glsl-type-kind t) 'struct))
(define (glsl-block? t) (eq? (glsl-type-kind t) 'block))
(define (glsl-void? t) (eq? (glsl-type-kind t) 'void))

;; ============================================================
;; 查询：在反射出的接口上按「限定符 / 类型 kind / layout / 名字」取子集
;;
;;   只读，不做组合（不合并阶段、不生成 setter、不碰 GL）。
;;   名字 lookup 是线性扫描：接口通常几十条，够用、也不额外存索引。
;;   三个 vars-with-* 都保持源码顺序。
;; ============================================================

;; 这条声明带某个限定符吗？qualifiers 是符号列表、顺序保留（如 (flat out)）
(define (glsl-var-has-qualifier? v q)
  (and (memq q (glsl-var-qualifiers v)) #t))

;; 取某个 layout 项的值：
;;   (location 0) → 0      (std140) → #t（有键无值）    没有该键 → default
;; 0 在 Racket 是真值，所以它也能当「有没有这个 layout 键」用。
;; 键名按标识符规则归一：'local-size-x 与 'local_size_x 等价。
(define (glsl-var-layout-ref v key [default #f])
  (define target (glsl-name-symbol key))
  (or (for/first ([it (in-list (glsl-var-layout v))]
                  #:when (eq? (glsl-name-symbol (car it)) target))
        (if (null? (cdr it)) #t (cadr it)))
      default))

;; 名字 → 声明；找不到 #f。名字可以写符号 'uColor 或字符串 "uColor"。
;; 同时接受表面名（u-color）与 GLSL 名（u_color）；内建变量别名也按同一规则处理。
(define (glsl-interface-ref ifc name)
  (define sym (if (string? name) (string->symbol name) name))
  (define target (glsl-name-symbol sym))
  (for/first ([v (in-list (glsl-interface-vars ifc))]
              #:when (or (eq? (glsl-var-name v) sym)
                         (eq? (glsl-var-glsl-name v) target)))
    v))

;; 带某个限定符的全部声明
(define (glsl-interface-vars-with-qualifier ifc q)
  (for/list ([v (in-list (glsl-interface-vars ifc))]
             #:when (glsl-var-has-qualifier? v q))
    v))

;; 类型 kind 匹配的全部声明（kind 取 glsl-type-kind 的取值：'scalar 'vector … 'block）
(define (glsl-interface-vars-with-kind ifc kind)
  (for/list ([v (in-list (glsl-interface-vars ifc))]
             #:when (eq? (glsl-type-kind (glsl-var-type v)) kind))
    v))

;; 带某个 layout 键的全部声明
(define (glsl-interface-vars-with-layout ifc key)
  (for/list ([v (in-list (glsl-interface-vars ifc))]
             #:when (glsl-var-layout-ref v key))
    v))

;; ============================================================
;; 数组 / 结构 / 块 的构造（尺寸一并算好）
;; ============================================================

(define (sum-member-size fields)
  (for/fold ([acc 0]) ([f (in-list fields)])
    (define sz (glsl-type-size (glsl-var-type f)))
    (and acc sz (+ acc sz))))

;; 数组：elem 类型 + 长度（#f = 未定长）
(define (glsl-array-type elem len)
  (glsl-type 'array 'array #f '() len elem
             (and len (glsl-type-size elem) (* len (glsl-type-size elem))) '()))

(define (glsl-struct-type name fields)
  (glsl-type 'struct name #f '() #f #f (sum-member-size fields) fields))

(define (glsl-block-type name fields)
  (glsl-type 'block name #f '() #f #f (sum-member-size fields) fields))

;; ============================================================
;; datum 往返：宏展开期算好 → quote 进代码 → 运行期重建
;;   type-datum = (kind name base dims len elem-datum size (var-datum ...))
;;   var-datum  = (name type-datum qualifiers layout)
;;   interface-datum = (listof var-datum)
;; ============================================================

(define (glsl-type->datum t)
  (list (glsl-type-kind t) (glsl-type-name t) (glsl-type-base t) (glsl-type-dims t)
        (glsl-type-len t)
        (and (glsl-type-elem t) (glsl-type->datum (glsl-type-elem t)))
        (glsl-type-size t)
        (map glsl-var->datum (glsl-type-fields t))))

(define (datum->glsl-type d)
  (match d
    [(list kind name base dims len elem size fields)
     (glsl-type kind name base dims len
                (and elem (datum->glsl-type elem)) size
                (map datum->glsl-var fields))]))

(define (glsl-var->datum v)
  (list (glsl-var-name v) (glsl-type->datum (glsl-var-type v))
        (glsl-var-qualifiers v) (glsl-var-layout v)))

(define (datum->glsl-var d)
  (match d
    [(list name type qualifiers layout)
     (glsl-var name (datum->glsl-type type) qualifiers layout)]))

(define (glsl-interface->datum i)
  (map glsl-var->datum (glsl-interface-vars i)))

(define (datum->glsl-interface d)
  (glsl-interface (map datum->glsl-var d)))
