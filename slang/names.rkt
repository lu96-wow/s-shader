#lang racket/base

;; ============================================================
;; Slang 方言 · slang/names.rkt —— 标识符 / 注解 / 属性表
;;
;; 引擎（camel→kebab、表构造、用户标识符 '-'→'_'、查表）在 core 的 shader/ident.rkt。
;; 本模块提供 Slang 自己的三张表：
;;   1. 语义（semantic）  SV-Position / sv_position / SV_Position → SV_Position（**后缀**注解）
;;   2. 修饰符            no-interpolation → nointerpolation …（**前缀**注解）
;;   3. 属性（attribute）  vk-binding → vk::binding；numthreads …（`[[...]]` / `[...]`）
;;
;; ★ 与 GLSL 的根本差异：Slang 没有可写的 `gl_Position` 这类内建变量，
;;   内建输入/输出是**挂在结构体字段或参数上的语义注解**。
;;   所以「内建变量表」在这里变成「语义表」。
;;
;; ★ 查表对大小写与 `-`/`_` 不敏感（SV-Position / sv_position / SV_Position 等价），
;;   因为语义名本来就从别的 API（D3D/GLSL）抄来，写法不统一。
;; ============================================================

(require racket/list racket/string
         "../shader/ident.rkt")

(provide slang-name slang-name-symbol slang-identifier?
         slang-semantic-name slang-semantic-name-symbol slang-semantic?
         slang-semantic-names
         slang-modifier-name slang-modifier-name-symbol slang-modifier?
         slang-modifier-names
         slang-annotation-role
         slang-attribute-name slang-attribute-name-symbol)

(define slang-identifier? identifier?)

;; 通用标识符（变量 / 函数 / struct 名）：只做 '-'→'_'
(define (slang-name x) (user-identifier-name 'slang-name x))
(define (slang-name-symbol x) (string->symbol (slang-name x)))

;; ---------- 查表：大小写 + '-'/'_' 不敏感 ----------

(define (normalize-key x)
  (string-downcase (string-replace (as-string 'normalize-key x) "-" "_")))

(define (names->table names)
  (for/hash ([n (in-list names)]) (values (normalize-key n) (symbol->string n))))

;; ============================================================
;; 表 1 · 语义（后缀注解：`float4 pos : SV_Position`）
;; ============================================================

(define semantic-names
  '(;; 系统值
    SV_Position SV_Target SV_Target0 SV_Depth SV_Coverage SV_ClipDistance SV_CullDistance
    SV_VertexID SV_InstanceID SV_PrimitiveID SV_DispatchThreadID SV_GroupID
    SV_GroupThreadID SV_GroupIndex
    ;; 常见用户语义
    POSITION NORMAL TANGENT BINORMAL TEXCOORD0 TEXCOORD1 TEXCOORD2 TEXCOORD3
    TEXCOORD4 TEXCOORD5 TEXCOORD6 TEXCOORD7 COLOR0 COLOR1 BLENDWEIGHT BLENDINDICES))

(define semantic-table (names->table semantic-names))

(define slang-semantic-names semantic-names)

;; ============================================================
;; 表 2 · 修饰符（前缀注解：`nointerpolation float3 n : NORMAL`）
;; ============================================================

(define modifier-names
  '(nointerpolation linear centroid noperspective sample precise
    groupshared static const extern inline))

;; 不规则别名（通用 '-'→'_' 会给出 no_interpolation 这种错拼写）
(define modifier-explicit-aliases
  '((no-interpolation . "nointerpolation")
    (no-perspective   . "noperspective")
    (group-shared     . "groupshared")))

(define modifier-table
  (for*/fold ([h (names->table modifier-names)]) ([p (in-list modifier-explicit-aliases)])
    (hash-set h (normalize-key (car p)) (cdr p))))

(define slang-modifier-names modifier-names)

;; ============================================================
;; 表 3 · 属性（`[[vk::binding]]` / `[numthreads]`）
;; ============================================================

;; 属性名有的不是合法标识符（含 `::`），所以显式给「表面别名 → 源码拼写」。
(define attribute-aliases
  '((vk-binding       . "vk::binding")
    (vk-constant-id   . "vk::constant_id")
    (vk-push-constant . "vk::push_constant")
    (vk-image-format  . "vk::image_format")
    (vk-location      . "vk::location")
    (shader           . "shader")
    (numthreads       . "numthreads")
    (unroll           . "unroll")
    (fastopt          . "fastopt")
    (noinline         . "noinline")))

(define attribute-table
  (for/hash ([p (in-list attribute-aliases)]) (values (normalize-key (car p)) (cdr p))))

;; ============================================================
;; 入口函数
;; ============================================================

(define (slang-semantic-name x)
  (or (hash-ref semantic-table (normalize-key x) #f)
      (user-identifier-name 'slang-semantic-name x)))

(define (slang-semantic-name-symbol x)
  (string->symbol (slang-semantic-name x)))

(define (slang-semantic? x)
  (and (or (symbol? x) (string? x))
       (and (hash-ref semantic-table (normalize-key x) #f) #t)))

(define (slang-modifier-name x)
  (or (hash-ref modifier-table (normalize-key x) #f)
      (user-identifier-name 'slang-modifier-name x)))

(define (slang-modifier-name-symbol x)
  (string->symbol (slang-modifier-name x)))

(define (slang-modifier? x)
  (and (or (symbol? x) (string? x))
       (and (hash-ref modifier-table (normalize-key x) #f) #t)))

(define (slang-attribute-name x)
  (or (hash-ref attribute-table (normalize-key x) #f)
      (user-identifier-name 'slang-attribute-name x)))

(define (slang-attribute-name-symbol x)
  (string->symbol (slang-attribute-name x)))

;; 注解在源码里的位置：语义 → 后缀（`name : SEM`）；修饰符 → 前缀
(define (slang-annotation-role x)
  (cond
    [(slang-semantic? x) 'suffix]
    [(slang-modifier? x) 'prefix]
    [else (error 'slang-annotation-role "未知注解：~s（语义表 / 修饰符表里都没有）" x)]))
