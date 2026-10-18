#lang racket/base

;; ============================================================
;; Slang 方言 · slang/rewrite.rkt —— 表面语法 → Slang（完全编译期变换）
;;
;; ★ 本文件是 step 3d 的**骨架**：只实现「声明侧」——
;;   struct（带语义/修饰符注解）、cbuffer（set/binding）、特化常量、参数化类型。
;;   函数体/表达式/语句、入口属性（[shader("vertex")] / [numthreads]）留给 step 4。
;;
;; 目的：验证 core 的边界够用 —— 三个为 Slang 预留的槽都在这里被用到：
;;   shader-type.args         Texture2D<float4> / StructuredBuffer<T>
;;   shader-var.annotations   (float4 pos SV-Position)
;;   shader-var.owner         cbuffer 的成员属于哪个块
;;   再加上 shader-var.source-name：本方言在构造时算好（core 不做任何转换）
;;
;; 表面语法：
;;   (slang
;;     (struct vs-out (float4 pos SV-Position) (float2 uv TEXCOORD0))
;;     (cbuffer Camera (set 0) (binding 0)
;;       (float4x4 view) (float4x4 proj) ((texture-2d float4) albedo))
;;     (const-id 0 int TILE 8))
;;
;; 产物：shader-program（与 GLSL 方言同一个 core 类型），接口里的类型名是 canonical
;;       （'vec3 / 'mat4），写进源码的拼写由本方言决定（float3 / float4x4）。
;; ============================================================

(require (for-syntax racket/base racket/list
                     "names.rkt" "types.rkt" "core.rkt"
                     shader/type
                     shader/interface
                     shader/program)
         "names.rkt"
         "types.rkt"
         "core.rkt"
         shader/type
         shader/interface
         shader/program
         shader/pretty)

(provide slang)

(begin-for-syntax

  ;; ---------- 类型 ----------

  ;; 表面类型 → (values 源码拼写 shader-type 或 #f)
  (define (rw-type t struct-names)
    (cond
      [(symbol? t)
       (cond
         [(slang-type-of t)
          => (lambda (ty) (values (symbol->string (slang-type-spelling (shader-type-name ty))) ty))]
         [(memq t struct-names) (values (slang-name t) #f)]
         [else (error 'slang "未知类型：~s" t)])]
      [(pair? t)
       (case (car t)
         ;; Texture2D<T>：采样器，args 记元素类型
         [(texture-2d)
          (unless (= 2 (length t)) (error 'slang "texture-2d 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty) (rw-type (cadr t) struct-names))
          (values (format "Texture2D<~a>" elem-str)
                  (shader-type 'sampler 'sampler2D (and elem-ty (shader-type-base elem-ty))
                               '() #f #f (if elem-ty (list elem-ty) '()) #f '()))]
         ;; StructuredBuffer<T>：资源，args 记元素类型
         [(sbuffer)
          (unless (= 2 (length t)) (error 'slang "sbuffer 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty) (rw-type (cadr t) struct-names))
          (values (format "StructuredBuffer<~a>" elem-str)
                  (shader-type 'resource 'StructuredBuffer #f '() #f #f
                               (if elem-ty (list elem-ty) '()) #f '()))]
         ;; 数组：T[N] / T[]
         [(array)
          (define len (and (pair? (cddr t)) (caddr t)))
          (define-values (elem-str elem-ty) (rw-type (cadr t) struct-names))
          (values (if len (format "~a[~a]" elem-str len) (format "~a[]" elem-str))
                  (and elem-ty (shader-array-type elem-ty len)))]
         [else (error 'slang "未知类型：~s" t)])]
      [else (error 'slang "坏类型：~s" t)]))

  ;; ---------- 注解 ----------

  ;; (SV-Position nointerpolation) → (values 前缀修饰符列表 语义字符串或 #f 注解符号列表)
  (define (split-annotations anns)
    (define prefixes '())
    (define semantic #f)
    (for ([a (in-list anns)])
      (case (slang-annotation-role a)
        [(prefix) (set! prefixes (cons (slang-modifier-name a) prefixes))]
        [(suffix)
         (when semantic (error 'slang "一个字段只能有一个语义：~s" anns))
         (set! semantic (slang-semantic-name a))]))
    (values (reverse prefixes) semantic
            (map (lambda (a) (string->symbol
                              (case (slang-annotation-role a)
                                [(prefix) (slang-modifier-name a)]
                                [else (slang-semantic-name a)])))
                 anns)))

  ;; (类型 名字 注解...) → (values 字段源码 shader-var)
  (define (field->decl f struct-names)
    (unless (and (>= (length f) 2) (symbol? (cadr f)))
      (error 'slang "坏字段：~s（应为 (类型 名字 注解...)）" f))
    (define-values (ty-str ty-obj) (rw-type (car f) struct-names))
    (define-values (prefixes semantic ann-syms) (split-annotations (cddr f)))
    (values (slang-field-decl prefixes ty-str (slang-name (cadr f)) semantic)
            (shader-var (cadr f) (slang-name-symbol (cadr f))
                        (or ty-obj (shader-type 'struct (cadr f) #f '() #f #f '() #f '()))
                        '() '() ann-syms #f)))

  ;; cbuffer 的字段列表 → (values 字段源码列表 成员 shader-var 列表)
  (define (fields->decls fields struct-names owner)
    (for/fold ([ds '()] [vs '()]) ([f (in-list fields)])
      (define-values (d v) (field->decl f struct-names))
      (values (append ds (list d))
              (append vs (list (struct-copy shader-var v [owner owner]))))))

  ;; ---------- 顶层 form ----------

  ;; (struct Name (类型 字段 注解...)...)  —— 只定义类型，不进接口
  (define (rw-struct f struct-names)
    (define name (cadr f))
    (define-values (decls _vars) (fields->decls (cddr f) struct-names #f))
    (values (apply slang-struct-decl (slang-name name) decls) '()))

  ;; 从 (set N) / (binding N) 里取值；其余项当字段
  (define (split-set-binding items)
    (define set #f) (define binding #f) (define fields '())
    (for ([it (in-list items)])
      (cond
        [(and (pair? it) (eq? (car it) 'set)) (set! set (cadr it))]
        [(and (pair? it) (eq? (car it) 'binding)) (set! binding (cadr it))]
        [else (set! fields (append fields (list it)))]))
    (values set binding fields))

  ;; (cbuffer Name (set S) (binding B) 字段...)
  ;; → [[vk::binding(B, S)]] cbuffer Name { … };
  (define (rw-cbuffer f struct-names)
    (define name (cadr f))
    (define-values (set binding fields) (split-set-binding (cddr f)))
    (unless (and set binding)
      (error 'slang "cbuffer 需要 (set N) 和 (binding N)：~s" f))
    (define-values (decls members) (fields->decls fields struct-names name))
    (define block-type (shader-block-type name members))
    (define block-var (shader-var name (slang-name-symbol name) block-type
                                  '() (list (list 'set set) (list 'binding binding))
                                  '() #f))
    (values (apply slang-cbuffer (list (list "vk::binding" binding set)) (slang-name name) decls)
            (append (list block-var) members)))

  ;; (const-id ID 类型 名字 值)  → [[vk::constant_id(ID)]] const 类型 名字 = 值;
  (define (rw-const-id f struct-names)
    (define id (cadr f))
    (define-values (ty-str ty-obj) (rw-type (caddr f) struct-names))
    (define name (cadddr f))
    (define value (car (cddddr f)))
    (define v (shader-var name (slang-name-symbol name)
                          (or ty-obj (shader-type 'scalar 'int #f '() #f #f '() #f '()))
                          '(const) (list (list 'constant_id id)) '() #f))
    (values (slang-const-id id ty-str (slang-name name) value) (list v)))

  ;; 一个顶层 form → (values 源码片段 接口变量列表)
  (define (rw-top d struct-names)
    (cond
      [(and (pair? d) (eq? (car d) 'struct)) (rw-struct d struct-names)]
      [(and (pair? d) (eq? (car d) 'cbuffer)) (rw-cbuffer d struct-names)]
      [(and (pair? d) (eq? (car d) 'const-id)) (rw-const-id d struct-names)]
      [(and (pair? d) (eq? (car d) 'raw)) (values (cadr d) '())]
      [else (error 'slang "bad top-level form: ~s" d)]))

  (define (struct-names-of datas)
    (for/list ([d (in-list datas)]
               #:when (and (pair? d) (eq? (car d) 'struct)))
      (cadr d)))

  ;; 全部 form → (values 片段列表 接口 datum)
  (define (forms->program-datum datas)
    (define struct-names (struct-names-of datas))
    (define parts '())
    (define vars '())
    (for ([d (in-list datas)])
      (define-values (text vs) (rw-top d struct-names))
      (set! parts (append parts (list text)))
      (set! vars (append vars vs)))
    (values parts (map shader-var->datum vars))))

;; ============================================================
;; 入口宏
;; ============================================================

;; (slang form ...) —— 展开期拼字符串 + 接口，产出 shader-program 常量
(define-syntax (slang stx)
  (syntax-case stx ()
    [(_ form ...)
     (let ()
       (define datas (map syntax->datum (syntax->list #'(form ...))))
       (define-values (parts iface-datum) (forms->program-datum datas))
       (define program (make-shader-program parts
                                           (for/list ([d (in-list datas)]) (list #f #f d))
                                           iface-datum))
       (datum->syntax #'slang
                      (list 'datum->shader-program
                            (list 'quote (shader-program->datum program)))))]))
