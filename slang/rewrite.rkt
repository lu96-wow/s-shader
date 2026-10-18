#lang racket/base

;; ============================================================
;; Slang 方言 · slang/rewrite.rkt —— 表面语法 → Slang（完全编译期变换）
;;
;; 与 GLSL 方言是**两份实现**（不互相 require）：表达式/语句骨架同形，
;; 但类型目录、注解、属性、`*` 的语义都不同。共同的字符串形状来自 shader/emit.rkt。
;;
;; 表面语法：
;;   (slang
;;     (struct vs-out (float4 pos SV-Position) (float2 uv TEXCOORD0))
;;     (cbuffer Camera (set 0) (binding 0) (float4x4 view) (float4x4 proj))
;;     (const-id 0 int TILE 8)
;;     (define (vs-main (vs-in i)) (attr (shader vertex)) vs-out
;;       (vs-out o (set! (.pos o) (mul uMVP (float4 (.pos i) 1.0))))
;;       o))
;;
;; 语义差异（相对 GLSL 方言）：
;;   *           逐分量乘（各语言原生语义）；矩阵乘用 (mul a b) → mul(a, b)
;;   xor         布尔异或 → (a != b)（HLSL/Slang 没有 ^^）
;;   texture     → (sample tex samp uv) → tex.Sample(samp, uv)；(sample-level …) → SampleLevel
;;   入口        (attr (shader vertex) (numthreads 8 8 1)) 写在参数表与返回类型之间
;;   系统值      (uint3 id SV-DispatchThreadID) —— 参数/字段上的语义后缀
;; ============================================================

(require (for-syntax racket/base racket/list racket/string racket/set
                     "names.rkt" "types.rkt" "core.rkt"
                     shader/emit
                     shader/emit-util
                     shader/type shader/interface shader/program)
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

  ;; 本块声明的 struct 名
  (define type-names (make-parameter '()))

  (define (struct-name? t) (memq t (type-names)))

  ;; 表面类型 → (values 基类型拼写 shader-type 或 #f 声明符后缀)
  ;;   HLSL/Slang 的数组写在**名字后面**：`float data[64];`（不是 `float[64] data;`），
  ;;   所以数组维度单独作为第三个值返回，由声明处拼到名字后面。
  (define (rw-type t)
    (cond
      [(symbol? t)
       (cond
         [(eq? t 'sampler-state)
          (values "SamplerState"
                  (shader-type 'sampler 'SamplerState 'float '() #f #f '() #f '())
                  "")]
         [(slang-type-of t)
          => (lambda (ty) (values (symbol->string (slang-type-spelling (shader-type-name ty))) ty ""))]
         [(struct-name? t) (values (slang-name t) #f "")]
         [else (error 'slang "未知类型：~s" t)])]
      [(pair? t)
       (case (car t)
         [(texture-2d)
          (unless (= 2 (length t)) (error 'slang "texture-2d 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty _) (rw-type (cadr t)))
          (values (format "Texture2D<~a>" elem-str)
                  (shader-type 'sampler 'sampler2D (and elem-ty (shader-type-base elem-ty))
                               '() #f #f (if elem-ty (list elem-ty) '()) #f '())
                  "")]
         [(sbuffer)
          (unless (= 2 (length t)) (error 'slang "sbuffer 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty _) (rw-type (cadr t)))
          (values (format "StructuredBuffer<~a>" elem-str)
                  (shader-type 'resource 'StructuredBuffer #f '() #f #f
                               (if elem-ty (list elem-ty) '()) #f '())
                  "")]
         [(rw-sbuffer)
          (unless (= 2 (length t)) (error 'slang "rw-sbuffer 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty _) (rw-type (cadr t)))
          (values (format "RWStructuredBuffer<~a>" elem-str)
                  (shader-type 'resource 'RWStructuredBuffer #f '() #f #f
                               (if elem-ty (list elem-ty) '()) #f '())
                  "")]
         [(sampler-state)
          (unless (= 1 (length t)) (error 'slang "sampler-state 不带参数：~s" t))
          (values "SamplerState"
                  (shader-type 'sampler 'SamplerState 'float '() #f #f '() #f '())
                  "")]
         [(rw-texture-2d)
          (unless (= 2 (length t)) (error 'slang "rw-texture-2d 需要 1 个元素类型：~s" t))
          (define-values (elem-str elem-ty _) (rw-type (cadr t)))
          (values (format "RWTexture2D<~a>" elem-str)
                  (shader-type 'image 'RWTexture2D (and elem-ty (shader-type-base elem-ty))
                               '() #f #f (if elem-ty (list elem-ty) '()) #f '())
                  "")]
         [(array)
          (define len (and (pair? (cddr t)) (caddr t)))
          (define-values (elem-str elem-ty elem-suffix) (rw-type (cadr t)))
          (values elem-str
                  (and elem-ty (shader-array-type elem-ty len))
                  (string-append elem-suffix (if len (format "[~a]" len) "[]")))]
         [else (error 'slang "未知类型：~s" t)])]
      [else (error 'slang "坏类型：~s" t)]))

  (define (type-form? t)
    (or (and (symbol? t) (or (slang-type-of t) (eq? t 'sampler-state) (struct-name? t)))
        (and (pair? t) (memq (car t) '(texture-2d sbuffer rw-sbuffer rw-texture-2d sampler-state array)))))

  ;; ---------- 限定符 ----------

  ;; 前缀限定符/修饰符：in out inout uniform groupshared static const …
  (define (collect-quals fs)
    (let loop ([fs fs] [acc '()])
      (cond
        [(null? fs) (values (reverse acc) '())]
        [(and (symbol? (car fs)) (slang-storage-qualifier? (car fs)))
         (loop (cdr fs) (cons (slang-modifier-name (car fs)) acc))]
        [else (values (reverse acc) fs)])))

  ;; 声明 vs 表达式：限定符开头 → 声明；类型开头且第二元是符号 → 声明
  (define (declaration? f)
    (and (pair? f)
         (let ([h (car f)] [a (cdr f)])
           (cond
             [(and (symbol? h) (slang-storage-qualifier? h)) #t]
             [(type-form? h) (and (pair? a) (symbol? (car a)))]
             [else #f]))))

  ;; ---------- 注解 ----------

  (define (split-annotations anns)
    (define prefixes '())
    (define semantic #f)
    (for ([a (in-list anns)])
      (case (slang-annotation-role a)
        [(prefix) (set! prefixes (cons (slang-modifier-name a) prefixes))]
        [(suffix)
         (when semantic (error 'slang "一个字段/参数只能有一个语义：~s" anns))
         (set! semantic (slang-semantic-name a))]))
    (values (reverse prefixes) semantic
            (map (lambda (a) (string->symbol
                              (case (slang-annotation-role a)
                                [(prefix) (slang-modifier-name a)]
                                [else (slang-semantic-name a)])))
                 anns)))

  ;; (类型 名字 注解...) → (values 字段源码 shader-var)
  (define (field->decl f)
    (unless (and (>= (length f) 2) (symbol? (cadr f)))
      (error 'slang "坏字段：~s（应为 (类型 名字 注解...)）" f))
    (define-values (ty-str ty-obj suffix) (rw-type (car f)))
    (define-values (prefixes semantic ann-syms) (split-annotations (cddr f)))
    (values (slang-field-decl prefixes ty-str (string-append (slang-name (cadr f)) suffix) semantic)
            (shader-var (cadr f) (slang-name-symbol (cadr f))
                        (or ty-obj (shader-type 'struct (cadr f) #f '() #f #f '() #f '()))
                        '() '() ann-syms #f)))

  ;; 参数：(限定符...) 类型 名字 注解...
  (define (rw-param p)
    (define-values (quals rest) (collect-quals p))
    (unless (and (pair? rest) (>= (length rest) 2) (symbol? (cadr rest)))
      (error 'slang "坏参数：~s（应为 (类型 名字 注解...)，可带 in/out/inout）" p))
    (define-values (ty-str _ty suffix) (rw-type (car rest)))
    (define-values (prefixes semantic _anns) (split-annotations (cddr rest)))
    (string-append
     (emit-param (append quals prefixes) ty-str (string-append (slang-name (cadr rest)) suffix))
     (if semantic (format " : ~a" semantic) "")))

  ;; 字段列表 → (values 字段源码列表 shader-var 列表)
  (define (fields->decls fields owner)
    (for/fold ([ds '()] [vs '()]) ([f (in-list fields)])
      (define-values (d v) (field->decl f))
      (values (append ds (list d))
              (append vs (list (struct-copy shader-var v [owner owner]))))))

  ;; ---------- 表达式 ----------

  (define bin-ops
    '((+ . "+") (- . "-") (* . "*") (/ . "/") (% . "%")
      (<< . "<<") (>> . ">>") (< . "<") (<= . "<=") (> . ">") (>= . ">=")
      (= . "==") (!= . "!=")
      (and . "&&") (or . "||")
      (bit-and . "&") (bit-or . "|") (bit-xor . "^")))

  (define unary-ops
    '((not . "!") (! . "!") (bit-not . "~")))

  (define assign-ops
    '((+= . "+") (-= . "-") (*= . "*") (/= . "/") (%= . "%")
      (<<= . "<<") (>>= . ">>")
      (bit-and= . "&") (bit-or= . "|") (bit-xor= . "^")))

  ;; swizzle 名：全由 x y z w r g b a s t p q 组成，长度 1-4
  (define (swizzle-name? sym)
    (and (symbol? sym)
         (let ([s (symbol->string sym)])
           (and (<= 1 (string-length s) 4)
                (for/and ([c (in-string s)]) (memv c '(#\x #\y #\z #\w #\r #\g #\b #\a #\s #\t #\p #\q)))))))

  ;; 方法调用：tex.Sample(samp, uv) / tex.SampleLevel(samp, uv, lod)
  (define (method-call obj method . args)
    (format "~a.~a(~a)" (->str obj) method (string-join (map ->str args) ", ")))

  (define (rw-expr e)
    (cond
      [(number? e)
       (when (and (exact? e) (rational? e) (not (integer? e)))
         (error 'slang "没有有理数字面量：~s。请写小数（如 0.5）或用 (/ 1.0 2.0)" e))
       e]
      [(boolean? e) (if e "true" "false")]
      [(symbol? e) (slang-name e)]
      [(pair? e)
       (define head (car e))
       (define args (cdr e))
       (cond
         [(eq? head 'if)
          (error 'slang "if 在表达式位置不可用（~s）；三元请写 (if-ternary c t e)" e)]
         [(eq? head 'if-ternary)
          (unless (= 3 (length args)) (error 'slang "if-ternary 需要 3 个参数：~s" e))
          (apply emit-ternary (map rw-expr args))]
         ;; 矩阵乘：Slang 的 * 是逐分量，所以用 mul()
         [(eq? head 'mul)
          (unless (= 2 (length args)) (error 'slang "mul 需要 2 个参数：~s" e))
          (apply emit-call "mul" (map rw-expr args))]
         ;; 采样：GLSL 的 texture() 在 Slang 里是方法调用
         [(eq? head 'sample)
          (unless (= 3 (length args)) (error 'slang "sample 需要 (tex samp uv)：~s" e))
          (apply method-call (rw-expr (car args)) "Sample" (map rw-expr (cdr args)))]
         [(eq? head 'sample-level)
          (unless (= 4 (length args)) (error 'slang "sample-level 需要 (tex samp uv lod)：~s" e))
          (apply method-call (rw-expr (car args)) "SampleLevel" (map rw-expr (cdr args)))]
         ;; 逻辑异或：Slang 没有 ^^，对 bool 用 !=
         [(eq? head 'xor)
          (unless (= 2 (length args)) (error 'slang "xor 需要 2 个参数：~s" e))
          (apply emit-bin "!=" (map rw-expr args))]
         [(and (memq head '(+ -)) (= (length args) 1))
          (emit-unary (symbol->string head) (rw-expr (car args)))]
         [(assq head unary-ops)
          (emit-unary (cdr (assq head unary-ops)) (rw-expr (car args)))]
         [(assq head bin-ops)
          (apply emit-bin (cdr (assq head bin-ops)) (map rw-expr args))]
         [(eq? head 'set!)
          (emit-assign (rw-lvalue (car args)) (rw-expr (cadr args)))]
         [(assq head assign-ops)
          (emit-cassign (cdr (assq head assign-ops))
                        (rw-lvalue (car args)) (rw-expr (cadr args)))]
         [(eq? head '++) (emit-inc (rw-lvalue (car args)))]
         [(eq? head '--) (emit-dec (rw-lvalue (car args)))]
         [(eq? head 'raw) (->str (car args))]
         [(and (symbol? head) (swizzle-name? head) (pair? args))
          (emit-swizzle (symbol->string head) (rw-expr (car args)))]
         [(and (symbol? head) (string-prefix? (symbol->string head) "."))
          (emit-field (slang-name (substring (symbol->string head) 1)) (rw-expr (car args)))]
         [(eq? head 'aref)
          (emit-aref (rw-expr (car args)) (rw-expr (cadr args)))]
         [(type-form? head)
          (define-values (ty-str _ty _suffix) (rw-type head))
          (apply emit-ctor ty-str (map rw-expr args))]
         [else
          (apply emit-call (slang-function-name head) (map rw-expr args))])]
      [else (error 'slang "bad expression: ~s" e)]))

  (define (rw-lvalue e)
    (if (symbol? e) (slang-name e) (rw-expr e)))

  ;; ---------- 语句 ----------

  (define (rw-body stmts)
    (apply emit-block (map rw-stmt stmts)))

  (define (rw-cond clauses)
    (let go ([cs clauses])
      (cond
        [(null? cs) #f]
        [else
         (define cl (car cs))
         (if (eq? (car cl) 'else)
             (let ([stmts (map rw-stmt (cdr cl))])
               (if (= 1 (length stmts)) (car stmts) (apply emit-block stmts)))
             (emit-if (rw-expr (car cl)) (rw-body (cdr cl)) (go (cdr cs))))])))

  (define (rw-switch args)
    (define test (rw-expr (car args)))
    (define cases '())
    (define default #f)
    (for ([cl (cdr args)])
      (cond
        [(eq? (car cl) 'case)
         (define lab (cadr cl))
         (define label (if (number? lab) lab (slang-name lab)))
         (set! cases (cons (list label (rw-body (cddr cl))) cases))]
        [(eq? (car cl) 'default)
         (set! default (rw-body (cdr cl)))]))
    (if default
        (emit-switch test (reverse cases) default)
        (emit-switch test (reverse cases))))

  (define (rw-decl f)
    (define-values (quals rest) (collect-quals f))
    (unless (and (pair? rest) (pair? (cdr rest)) (symbol? (cadr rest)))
      (error 'slang "bad declaration：~s（应为 (类型 名字 [初值]) 单变量）" f))
    (when (> (length rest) 3)
      (error 'slang "bad declaration：~s（只能一个变量一个初值）" f))
    (define-values (ty-str _ty suffix) (rw-type (car rest)))
    (slang-decl '() quals ty-str (string-append (slang-name (cadr rest)) suffix)
                (and (pair? (cddr rest)) (rw-expr (caddr rest)))))

  (define (rw-stmt s)
    (cond
      [(pair? s)
       (define head (car s))
       (define args (cdr s))
       (cond
         [(eq? head 'begin) (apply emit-block (map rw-stmt args))]
         [(eq? head 'when)
          (emit-if (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'unless)
          (emit-if (emit-unary "!" (rw-expr (car args))) (rw-body (cdr args)))]
         [(eq? head 'if)
          (unless (or (= 2 (length args)) (= 3 (length args)))
            (error 'slang "if 需要 2 或 3 个参数（条件 + then [+ else]）：~s" s))
          (emit-if (rw-expr (car args))
                   (rw-stmt (cadr args))
                   (and (= 3 (length args)) (rw-stmt (caddr args))))]
         [(eq? head 'cond) (rw-cond args)]
         [(eq? head 'for)
          (emit-for (rw-decl (car args))
                    (rw-expr (cadr args)) (rw-expr (caddr args))
                    (rw-body (cdddr args)))]
         [(eq? head 'while)
          (emit-while (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'do-while)
          (emit-do-while (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'switch) (rw-switch args)]
         [(eq? head 'break) (emit-break)]
         [(eq? head 'continue) (emit-continue)]
         [(eq? head 'discard) (emit-discard)]
         [(eq? head 'raw) (->str (car args))]
         [(eq? head 'return)
          (if (null? args) (emit-return) (emit-return (rw-expr (car args))))]
         [(declaration? s) (rw-decl s)]
         [else (emit-stmt (rw-expr s))])]
      [else (error 'slang "bad statement: ~s" s)]))

  ;; 是否是表达式（用于函数体末尾自动 return）
  (define stmt-heads
    '(begin when unless if cond for while do-while switch break continue return discard raw))

  (define (expr-form? f)
    (cond
      [(pair? f)
       (define h (car f))
       (not (or (memq h stmt-heads) (declaration? f)))]
      [else #t]))

  ;; ---------- 函数 ----------

  ;; (define (name 参数...) [(attr ...)] 返回类型 body...)
  (define (rw-fn args)
    (define sig (car args))
    (define fname (slang-name (car sig)))
    (define params (map rw-param (cdr sig)))
    (define rest (cdr args))
    ;; 入口属性：(attr (shader vertex) (numthreads 8 8 1))
    (define attrs '())
    (when (and (pair? rest) (pair? (car rest)) (eq? (car (car rest)) 'attr))
      (set! attrs
            (for/list ([a (in-list (cdr (car rest)))])
              (cons (slang-attribute-name (car a))
                    (map (lambda (x) (if (symbol? x) (symbol->string x) x)) (cdr a)))))
      (set! rest (cdr rest)))
    (unless (pair? rest) (error 'slang "函数缺少返回类型：~s" args))
    (define-values (ret-str ret-ty ret-suffix) (rw-type (car rest)))
    (when (not (string=? ret-suffix ""))
      (error 'slang "函数返回类型不能是数组：~s" (car rest)))
    (define body-forms (cdr rest))
    ;; 非 void 且最后一个 body 是表达式 → 自动 return
    (define body
      (if (and (not (null? body-forms))
               (not (string=? ret-str "void"))
               (expr-form? (last body-forms)))
          (append (map rw-stmt (drop-right body-forms 1))
                  (list (emit-return (rw-expr (last body-forms)))))
          (map rw-stmt body-forms)))
    (string-append (slang-attr attrs)
                   (apply emit-fn fname ret-str params body)))

  ;; ---------- 顶层 form ----------

  (define (rw-struct f)
    (define name (cadr f))
    (define-values (decls _vars) (fields->decls (cddr f) #f))
    (values (apply slang-struct-decl (slang-name name) decls) '()))

  ;; (set N) / (binding N) 从字段列表里分出来
  (define (split-set-binding items)
    (define set #f) (define binding #f) (define fields '())
    (for ([it (in-list items)])
      (cond
        [(and (pair? it) (eq? (car it) 'set)) (set! set (cadr it))]
        [(and (pair? it) (eq? (car it) 'binding)) (set! binding (cadr it))]
        [else (set! fields (append fields (list it)))]))
    (values set binding fields))

  (define (rw-cbuffer f)
    (define name (cadr f))
    (define-values (set binding fields) (split-set-binding (cddr f)))
    (unless (and set binding)
      (error 'slang "cbuffer 需要 (set N) 和 (binding N)：~s" f))
    (define-values (decls members) (fields->decls fields name))
    (define block-type (shader-block-type name members))
    (define block-var (shader-var name (slang-name-symbol name) block-type
                                  '() (list (list 'set set) (list 'binding binding))
                                  '() #f))
    (values (apply slang-cbuffer (list (list "vk::binding" binding set)) (slang-name name) decls)
            (append (list block-var) members)))

  ;; (push-const Name 字段...) → [[vk::push_constant]] cbuffer Name { … };
  ;; 字段当全局用（mvp / time），与 cbuffer 一致。
  (define (rw-push-const f)
    (define name (cadr f))
    (define-values (decls members) (fields->decls (cddr f) name))
    (define block-type (shader-block-type name members))
    (define block-var (shader-var name (slang-name-symbol name) block-type
                                  '() (list (list 'push_constant)) '() #f))
    (values (apply slang-cbuffer (list (list "vk::push_constant")) (slang-name name) decls)
            (append (list block-var) members)))

  ;; (param-block Name inst (set S) (binding B) 字段...)
  ;; → struct Name { … }; [[vk::binding(B, S)]] ParameterBlock<Name> inst;
  ;; 字段通过 inst.field 访问；成员 owner = Name。
  (define (rw-param-block f)
    (define name (cadr f))
    (define inst (caddr f))
    (define-values (set binding fields) (split-set-binding (cdddr f)))
    (unless (and set binding)
      (error 'slang "param-block 需要 (set N) 和 (binding N)：~s" f))
    ;; 参数块是「块类型 + 实例」：接口里的块变量用**实例名**（mat），
    ;; 成员的 owner 也用实例名，便于从块走到成员。
    (define-values (decls members) (fields->decls fields inst))
    (define block-type (shader-block-type name members))
    (define block-var (shader-var inst (slang-name-symbol inst) block-type
                                  '() (list (list 'set set) (list 'binding binding)) '() #f))
    (values (apply slang-param-block
                   (list (list "vk::binding" binding set)) (slang-name name) (slang-name inst) decls)
            (append (list block-var) members)))

  ;; (resource 名字 类型 (set S) (binding B))
  ;; 任意资源声明：StructuredBuffer / RWStructuredBuffer / Texture2D / RWTexture2D / SamplerState
  (define (rw-resource f)
    (define name (cadr f))
    (define-values (ty-str ty-obj suffix) (rw-type (caddr f)))
    (unless (string=? suffix "")
      (error 'slang "resource 的类型不能是数组：~s" f))
    (define-values (set binding fields) (split-set-binding (cdddr f)))
    (unless (and set binding (null? fields))
      (error 'slang "resource 需要 (set N) 和 (binding N)，且后面不再有字段：~s" f))
    (values (slang-resource (list (list "vk::binding" binding set)) ty-str (slang-name name))
            (list (shader-var name (slang-name-symbol name)
                              (or ty-obj (shader-type 'resource 'unknown #f '() #f #f '() #f '()))
                              '() (list (list 'set set) (list 'binding binding)) '() #f))))

  (define (rw-const-id f)
    (define id (cadr f))
    (define-values (ty-str _ty suffix) (rw-type (caddr f)))
    (when (not (string=? suffix ""))
      (error 'slang "const-id 的类型不能是数组：~s" f))
    (define name (cadddr f))
    (define value (car (cddddr f)))
    (define v (shader-var name (slang-name-symbol name)
                          (or (slang-type-of (caddr f))
                              (shader-type 'scalar 'int #f '() #f #f '() #f '()))
                          '(const) (list (list 'constant_id id)) '() #f))
    (values (slang-const-id id ty-str (slang-name name) value) (list v)))

  (define (rw-top d)
    (cond
      [(and (pair? d) (eq? (car d) 'struct)) (rw-struct d)]
      [(and (pair? d) (eq? (car d) 'cbuffer)) (rw-cbuffer d)]
      [(and (pair? d) (eq? (car d) 'const-id)) (rw-const-id d)]
      [(and (pair? d) (eq? (car d) 'push-const)) (rw-push-const d)]
      [(and (pair? d) (eq? (car d) 'param-block)) (rw-param-block d)]
      [(and (pair? d) (eq? (car d) 'resource)) (rw-resource d)]
      [(and (pair? d) (eq? (car d) 'define)) (values (rw-fn (cdr d)) '())]
      [(and (pair? d) (eq? (car d) 'raw)) (values (cadr d) '())]
      [else (error 'slang "bad top-level form: ~s" d)]))

  (define (forms->program-datum datas)
    ;; struct 名先全部收集，字段/参数里可以互相引用
    (type-names (for/list ([d (in-list datas)]
                           #:when (and (pair? d) (eq? (car d) 'struct)))
                  (cadr d)))
    (for ([d (in-list datas)])
      (when (and (pair? d) (eq? (car d) 'struct))
        (when (slang-type-of (cadr d))
          (error 'slang "struct 名不能与内建类型冲突：~a" (cadr d)))))
    (define parts '())
    (define vars '())
    (for ([d (in-list datas)])
      (define-values (text vs) (rw-top d))
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
