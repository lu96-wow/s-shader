#lang racket/base

;; ============================================================
;; 块 1 · (glsl) 内 · glsl/rewrite.rkt —— 表面语法 → GLSL（完全编译期变换）
;;
;; 设计：`(glsl ...)` 是一个**纯编译期**变换。
;;   surface datum（(vec2 1.0 2.0)、(set! x v)、(in vec2 aPos)...）
;;     ↓ rw-expr / rw-stmt / rw-top（编译期纯函数，直接调用 glsl-* 原语）
;;   字符串片段（每行一个顶层 form 的 GLSL 文本）
;;     ↓ make-shader-program（编译期美化 + 行映射 + 接口反射）
;;   shader-program 值（编译期常量）
;;     ↓ 生成代码
;;   (datum->shader-program '<program-datum>)   —— 运行期只重建，无逻辑
;;
;; ★ 没有运行期求值：`glsl-unquote` 已移除（见 ../COMPOSITION.md §2）。
;;   动态 shader 请在 Racket 里拼整段 GLSL 字符串，交给 opengl 包的 shader-compile。
;; ============================================================

(require (for-syntax racket/base
                     racket/string
                     racket/format
                     racket/set
                     racket/list
                     racket/syntax
                     "core.rkt"
                     "names.rkt"
                     "../types.rkt"
                     "interface.rkt"
                     "program.rkt")
         "core.rkt"
         "pretty.rkt"
         "names.rkt"
         "interface.rkt"
         "program.rkt")

(provide glsl glsl-fragment glsl-splice glsl-shader
         (all-from-out "core.rkt")
         (all-from-out "pretty.rkt")
         (all-from-out "names.rkt")
         (all-from-out "interface.rkt")
         (all-from-out "program.rkt"))

(begin-for-syntax

  ;; ---------- 内建类型名集合 ----------
  ;; 单一来源：shader-interface.rkt 的类型模型（保证与类型反射一致）
  (define builtin-types (list->seteq builtin-type-names))

  ;; 当前类型集合（含本块收集的 struct 名）
  (define type-names (make-parameter builtin-types))

  ;; ---------- 内部数据：entry = surface datum + 源（“list 挂表”） ----------
  ;; entry = (list datum source)    source = #f | (list path line text)
  ;; 用纯数据而非 struct：将来 chunk 可直接被 (quote …) 携带（COMPOSITION.md §4）。
  (define (make-entry datum source) (list datum source))
  (define (entry-datum e) (car e))
  (define (entry-source e) (cadr e))

  ;; 源文件路径 → 字符串（拿不到则 #f）
  (define (src-path-string f)
    (define src (syntax-source f))
    (cond [(path? src) (path->string src)]
          [src (format "~a" src)]
          [else #f]))
  ;; 一个 form 的源信息：(src-path src-line text) —— 源映射只到行
  (define (source-info f)
    (list (src-path-string f) (syntax-line f) (syntax->datum f)))

  ;; (glsl-splice <片段名>) → 该片段的 entries（片段宏展开为 (quote chunk)）
  (define (glsl-splice->entries stx)
    (define parts (syntax->list stx))
    (unless (and parts (= 2 (length parts)))
      (error 'glsl "bad glsl-splice：~s（应为 (glsl-splice 片段名)）" (syntax->datum stx)))
    (define frag-stx (cadr parts))
    (define d (syntax->datum (local-expand frag-stx 'expression '())))
    (unless (and (pair? d) (memq (car d) '(quote #%quote)) (= 2 (length d)))
      (error 'glsl "glsl-splice 的目标必须是片段宏（展开为 quote 数据）：~s" (syntax->datum frag-stx)))
    (cadr d))

  ;; forms（syntax 列表）→ entries；识别顶层 (glsl-splice …) 并拼入片段
  (define (forms->entries forms)
    (append*
     (for/list ([f (in-list forms)])
       (define d (syntax->datum f))
       (if (and (pair? d) (eq? (car d) 'glsl-splice))
           (glsl-splice->entries f)
           (list (make-entry d (source-info f)))))))

  ;; ---------- 运算符表 ----------
  (define bin-ops
    '((+ . "+") (- . "-") (* . "*") (/ . "/") (% . "%")
      (<< . "<<") (>> . ">>") (< . "<") (<= . "<=") (> . ">") (>= . ">=")
      (= . "==") (!= . "!=")
      (and . "&&") (or . "||") (xor . "^^")
      (bit-and . "&") (bit-or . "|") (bit-xor . "^")))

  (define unary-ops
    '((not . "!") (! . "!") (bit-not . "~")))

  (define assign-ops
    '((+= . "+") (-= . "-") (*= . "*") (/= . "/") (%= . "%")
      (<<= . "<<") (>>= . ">>")
      (bit-and= . "&") (bit-or= . "|") (bit-xor= . "^")))

  ;; swizzle 名：全由 x y z w r g b a s t p q 组成，长度 1-4
  (define (swizzle-name? sym)
    (define s (symbol->string sym))
    (and (> (string-length s) 0)
         (<= (string-length s) 4)
         (for/and ([ch (in-list (string->list s))])
           (member ch '(#\x #\y #\z #\w #\r #\g #\b #\a #\s #\t #\p #\q)))))

  ;; ---------- 类型位：内建类型符号 / (array 内层 [大小]) / (block 名 字段...) ----------
  ;; 数组大小缺省 → []（未定长：几何/细分着色器的 in/out、函数参数等）
  (define (array-type? t)
    (and (pair? t) (eq? (car t) 'array) (>= (length t) 2)))

  ;; 接口块：(block 名 (字段类型 字段名) ...) —— UBO/SSBO/in-out 块的"类型位"
  (define (block-type? t)
    (and (pair? t) (eq? (car t) 'block) (>= (length t) 2) (symbol? (cadr t))))

  (define (shader-type? t)
    (or (and (symbol? t)
             (or (builtin-type? t)          ; canonical 或类型别名
                 (set-member? (type-names) t)))  ; 用户 struct 名（表面名）
        (array-type? t)
        (block-type? t)))

  ;; 类型 → GLSL 文本：float → "float"；(array vec3 4) → "vec3[4]"；
  ;; (block Camera (mat4 view)) → "Camera { mat4 view; }"
  ;; ★ 类型名、struct/block 名、数组长度里的符号都走 glsl-name（用户标识符便携层）。
  (define (rw-array-size x)
    (if (symbol? x) (glsl-name x) (format "~a" x)))

  (define (rw-type t)
    (cond
      [(symbol? t)
       ;; 内建类型/别名 → canonical 拼写；用户 struct 名 → 标识符规则（- → _）
       (or (type-canonical-name t) (glsl-name t))]
      [(array-type? t)
       (define sz (if (null? (cddr t)) "[]" (format "[~a]" (rw-array-size (caddr t)))))
       (string-append (rw-type (cadr t)) sz)]
      [(block-type? t)
       (format "~a { ~a }"
               (glsl-name (cadr t))
               (string-join (map field->str (cddr t)) " "))]
      [else (error 'glsl "bad type: ~s" t)]))

  ;; 声明 vs 构造器：layout/限定符开头 → 声明；类型开头 → 第二元是符号才是声明
  ;; （否则是构造器表达式，如 ((array float 4) 1.0 2.0 3.0 4.0)）
  (define (declaration? s)
    (and (pair? s)
         (let ([h (car s)] [a (cdr s)])
           (cond
             [(eq? h 'layout) #t]
             [(glsl-qualifier? h) #t]
             [(shader-type? h) (and (pair? a) (symbol? (car a)))]
             [else #f]))))

  ;; ---------- 表达式 ----------
  (define (rw-expr e)
    (cond
      [(number? e)
       (when (and (exact? e) (rational? e) (not (integer? e)))
         (error 'glsl "GLSL 没有有理数字面量：~s。请写小数（如 0.5）或用 (/ 1.0 2.0)" e))
       e]
      [(boolean? e) (if e "true" "false")]
      [(symbol? e) (glsl-name e)]
      [(pair? e)
       (define head (car e))
       (define args (cdr e))
       (cond
         [(eq? head 'if)
          (glsl-ternary (rw-expr (car args)) (rw-expr (cadr args)) (rw-expr (caddr args)))]
         [(and (memq head '(+ -)) (= (length args) 1))
          (glsl-unary (symbol->string head) (rw-expr (car args)))]
         [(assq head unary-ops)
          (glsl-unary (cdr (assq head unary-ops)) (rw-expr (car args)))]
         [(assq head bin-ops)
          (apply glsl-bin (cdr (assq head bin-ops)) (map rw-expr args))]
         [(eq? head 'set!)
          (glsl-assign (rw-lvalue (car args)) (rw-expr (cadr args)))]
         [(assq head assign-ops)
          (glsl-cassign (cdr (assq head assign-ops))
                        (rw-lvalue (car args)) (rw-expr (cadr args)))]
         [(eq? head '++) (glsl-inc (rw-lvalue (car args)))]
         [(eq? head '--) (glsl-dec (rw-lvalue (car args)))]
         [(eq? head 'raw) (glsl-raw (car args))]  ; ★在 swizzle 之前：raw 由 r/a/w 组成，会被误判成 swizzle
         [(and (symbol? head) (swizzle-name? head) (pair? args))
          (glsl-swizzle (symbol->string head) (rw-expr (car args)))]
         [(and (symbol? head) (string-prefix? (symbol->string head) "."))
          (glsl-field (glsl-name (substring (symbol->string head) 1)) (rw-expr (car args)))]
         [(eq? head 'aref)
          (glsl-aref (rw-expr (car args)) (rw-expr (cadr args)))]
         [(shader-type? head)
          (apply glsl-ctor (rw-type head) (map rw-expr args))]
         [else
          (apply glsl-call (glsl-function-name head) (map rw-expr args))])]
      [else (error 'glsl "bad expression: ~s" e)]))

  (define (rw-lvalue e)
    (if (symbol? e) (glsl-name e) (rw-expr e)))

  ;; ---------- 语句 ----------
  (define (rw-body stmts)
    (apply glsl-block (map rw-stmt stmts)))

  (define (rw-cond clauses)
    (let go ([cs clauses])
      (cond
        [(null? cs) #f]
        [else
         (define cl (car cs))
         (if (eq? (car cl) 'else)
             ;; else 分支：单语句直接返回（避免 (cond [else x]) 多包一层裸块）；
             ;; 多语句没法拆成多个顶层 form，仍用块包。
             (let ([stmts (map rw-stmt (cdr cl))])
               (if (= 1 (length stmts)) (car stmts) (apply glsl-block stmts)))
             (glsl-if (rw-expr (car cl)) (rw-body (cdr cl)) (go (cdr cs))))])))

  (define (rw-switch args)
    (define test (rw-expr (car args)))
    (define cases '())
    (define default #f)
    (for ([cl (cdr args)])
      (cond
        [(eq? (car cl) 'case)
         (define lab (cadr cl))
         (define label (if (number? lab) lab (glsl-name lab)))
         (set! cases (cons (list label (rw-body (cddr cl))) cases))]
        [(eq? (car cl) 'default)
         (set! default (rw-body (cdr cl)))]))
    (if default
        (glsl-switch test (reverse cases) default)
        (glsl-switch test (reverse cases))))

  (define (rw-stmt s)
    (cond
      [(pair? s)
       (define head (car s))
       (define args (cdr s))
       (cond
         [(eq? head 'begin) (apply glsl-block (map rw-stmt args))]
         [(eq? head 'when)
          (glsl-if (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'unless)
          (glsl-if (glsl-unary "!" (rw-expr (car args))) (rw-body (cdr args)))]
         [(eq? head 'if)
          (error 'glsl "if 是表达式（三元 ?:）；语句位置的分支请用 when / unless / cond：~s" s)]
         [(eq? head 'cond) (rw-cond args)]
         [(eq? head 'for)
          (glsl-for (rw-decl (car args))
                    (rw-expr (cadr args)) (rw-expr (caddr args))
                    (rw-body (cdddr args)))]
         [(eq? head 'while)
          (glsl-while (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'do-while)
          (glsl-do-while (rw-expr (car args)) (rw-body (cdr args)))]
         [(eq? head 'break) (glsl-break)]
         [(eq? head 'continue) (glsl-continue)]
         [(eq? head 'discard) (glsl-discard)]
         [(eq? head 'raw) (glsl-raw (car args))]
         [(eq? head 'switch) (rw-switch args)]
         [(eq? head 'return)
          (if (null? args) (glsl-return) (glsl-return (rw-expr (car args))))]
         [(rw-directive s) => (lambda (d) d)]  ; ★ 预处理指令（ifdef/ifndef/else/endif/...）
         [(declaration? s)
          (rw-decl s)]
         [else (glsl-stmt (rw-expr s))])]
      [else (error 'glsl "bad statement: ~s" s)]))

  ;; ---------- 声明 ----------
  ;; 通用声明：(QUAL* TYPE name [init])，QUAL* 可为空或任意限定符（in/out/uniform/const/flat/...）
  (define (rw-decl s)
    (if (eq? (car s) 'layout)
        (rw-layout (cdr s))
        (let ()
          (define-values (quals after) (collect-quals s))
          (unless (and (pair? after) (pair? (cdr after)))
            (error 'glsl "bad declaration：缺少类型或变量名 ~s" s))
          ;; 声明只能是一个变量：(类型 名字 [初值])；多变量/坏形状给清晰报错
          (unless (and (symbol? (cadr after)) (<= (length after) 3))
            (error 'glsl "bad declaration：~s（应为 (类型 名字 [初值]) 单变量）" s))
          (define ty (rw-type (car after)))
          (define nm (glsl-name (cadr after)))
          (if (null? (cddr after))
              (glsl-decl quals ty nm)
              (glsl-decl quals ty nm (rw-expr (caddr after)))))))

  ;; layout item → 运行时值：裸项 (std140) → "std140"；(offset 0) → ("offset" 0)
  ;; layout 键走独立的关键字别名表（local-size-x → local_size_x 等）。
  (define (layout-item->val it)
    (cond
      [(string? it) it]
      [(and (pair? it) (null? (cdr it)))
       (if (string? (car it)) (car it) (glsl-layout-key-name (car it)))]
      [(pair? it)
       (list (if (string? (car it)) (car it) (glsl-layout-key-name (car it))) (cadr it))]
      [else (glsl-layout-key-name it)]))

  ;; 收集 layout 项，直到遇到类型或限定符关键字
  (define (collect-layout-items forms)
    (let loop ([fs forms] [acc '()])
      (define d (car fs))
      (cond
        [(shader-type? d) (values (reverse acc) fs)]          ; 类型（含 array/block）→ 结束
        [(glsl-qualifier? d) (values (reverse acc) fs)]      ; 限定符 → 结束
        [(pair? d) (loop (cdr fs) (cons d acc))]            ; (location 0) 等项
        [else (loop (cdr fs) (cons d acc))])))              ; 裸项 std140 等

  ;; layout：(layout (location 0) (binding 1) in vec2 aPos)
  (define (rw-layout args)
    (define-values (items rest) (collect-layout-items args))
    (define spec (map layout-item->val items))
    (define-values (quals after) (collect-quals rest))
    (if (null? after)                          ; 独立 layout：layout(...) in;（compute/几何/early_fragment_tests）
        (glsl-layout-qual spec quals)
        (let ()
          (define ty (rw-type (car after)))
          (define nm (glsl-name (cadr after)))
          (if (null? (cddr after))
              (glsl-layout spec quals ty nm)
              (glsl-layout spec quals ty nm (rw-expr (caddr after)))))))

  ;; 从 forms 头收集限定符符号，直到遇到类型（符号或 (array ...)）；返回 (quals rest)
  ;; ★ 限定符走独立的关键字别名表：
  ;;   规范名（in/uniform/readonly）原样；不规则别名（read-only/no-perspective/in-out）
  ;;   显式映射到 canonical；未知连字符仍按 `-`→`_` 兜底。
  (define (collect-quals forms)
    (let loop ([fs forms] [acc '()])
      (cond
        [(null? fs) (values (map glsl-qualifier-name (reverse acc)) '())]
        [(shader-type? (car fs))
         (values (map glsl-qualifier-name (reverse acc)) fs)]
        [(symbol? (car fs))
         (loop (cdr fs) (cons (car fs) acc))]
        [else (error 'glsl "bad declaration：~s 既不是限定符也不是类型" (car fs))])))

  ;; 接口块字段 → 字符串："mat4 view;" / "flat vec3 n;" / "layout(offset = 0) mat4 view;"
  (define (field->str f)
    (cond
      [(and (pair? f) (eq? (car f) 'layout))
       (define-values (items rest) (collect-layout-items (cdr f)))
       (define-values (quals after) (collect-quals rest))
       (define ty (rw-type (car after)))
       (define nm (glsl-name (cadr after)))
       (glsl-layout (map layout-item->val items) quals ty nm)]
      [else
       (define-values (quals after) (collect-quals f))
       (define ty (rw-type (car after)))
       (define nm (glsl-name (cadr after)))
       (glsl-decl quals ty nm)]))

  ;; ---------- 函数 / 结构 ----------
  (define stmt-keywords
    '(when unless cond for while do-while break continue return discard begin))

  ;; 语句位置的预处理指令头（不含 if：(if ...) 在表达式位置是三元，只在顶层才是 #if）
  (define directive-keywords
    '(define-macro undef ifdef ifndef elif else endif error pragma extension))

  ;; 是否为「表达式形态」：原子（符号/数字/布尔）也算表达式，
  ;; 否则函数体以裸符号/数字结尾时自动 return 会失效（落到语句位置报错）。
  (define (expr-form? f)
    (cond
      [(or (symbol? f) (number? f) (boolean? f)) #t]
      [(pair? f)
       (let ([h (car f)])
         (not (or (memq h stmt-keywords)
                  (memq h directive-keywords)
                  (declaration? f))))]
      [else #f]))

  (define (rw-param p)
    (define head (glsl-qualifier-name (car p)))
    (if (member head '("in" "out" "inout"))
        (glsl-param (list head) (rw-type (cadr p)) (glsl-name (caddr p)))
        (glsl-param '() (rw-type (car p)) (glsl-name (cadr p)))))

  (define (rw-fn args)
    (define sig (car args))
    (define fname (glsl-function-name (car sig)))
    (define params (map rw-param (cdr sig)))
    (define ret (rw-type (cadr args)))
    (define body-forms (cddr args))
    ;; 非 void 且最后一个 body 是表达式 → 作为 return
    (define body
      (if (and (not (null? body-forms))
               (not (equal? ret "void"))
               (expr-form? (last body-forms)))
          (append (map rw-stmt (drop-right body-forms 1))
                  (list (glsl-return (rw-expr (last body-forms)))))
          (map rw-stmt body-forms)))
    (apply glsl-fn fname ret params body))

  (define (rw-field f)
    (glsl-field-decl (rw-type (car f)) (glsl-name (cadr f))))

  (define (rw-struct args)
    (apply shader-struct-decl (glsl-name (car args)) (map rw-field (cdr args))))

  ;; ---------- 预处理指令 ----------
  ;; 预处理指令是语法无关的（编译前按行处理），所以顶层 / 语句位置都允许。
  ;; 但语句位置的 (if ...) 仍保持“三元表达式错误”语义（rw-stmt 里更早的分支拦截），
  ;; 因此 #if/#elif 只在顶层可用。

  ;; 指令 token：符号→字符串、字符串/数字原样（#if 0 / #if 1 / #if FOO）
  (define (rw-macro-token x)
    (cond
      [(symbol? x) (glsl-name x)]
      [(string? x) x]
      [(number? x) x]
      [else (error 'glsl "bad macro token: ~s" x)]))

  ;; 宏体：字符串 = 原样（任意 token 序列的逃生舱）；
  ;;       数字/符号/布尔/列表 = 按表面表达式重写（1→"1"、baz→"baz"、(+ a b)→(a + b)）
  (define (rw-macro-body body)
    (if (string? body) body (rw-expr body)))

  ;; (define-macro FOO 1)              → #define FOO 1
  ;; (define-macro FOO baz)            → #define FOO baz
  ;; (define-macro (ADD a b) (+ a b))  → #define ADD(a, b) (a + b)
  ;; (define-macro (MAX a b) "a + b")  → #define MAX(a, b) a + b（字符串=原样）
  (define (rw-macro-define args)
    (unless (and (= (length args) 2))
      (error 'glsl "bad define-macro：~s（应为 (define-macro 名 体) 或 (define-macro (名 参数...) 体)）" (cons 'define-macro args)))
    (define sig (car args))
    (define body (rw-macro-body (cadr args)))
    (cond
      [(symbol? sig)
       (glsl-macro-define (glsl-name sig) #f body)]
      [(and (pair? sig) (symbol? (car sig)) (andmap symbol? (cdr sig)))
       (glsl-macro-define (glsl-name (car sig))
                          (map glsl-name (cdr sig)) body)]
      [else (error 'glsl "bad define-macro 签名：~s（应为 名 或 (名 参数...)）" sig)]))

  ;; 一个预处理指令 datum → 其 GLSL 文本；不是指令则 #f
  (define (rw-directive s)
    (and (pair? s)
         (let ([head (car s)] [args (cdr s)])
           (case head
             [(define-macro) (rw-macro-define args)]
             [(undef ifdef ifndef)
              (unless (and (= (length args) 1) (symbol? (car args)))
                (error 'glsl "bad ~a：~s（应为 (~a 名字)）" head s head))
              ((case head [(undef) glsl-macro-undef]
                          [(ifdef) glsl-macro-ifdef]
                          [else glsl-macro-ifndef])
               (glsl-name (car args)))]
             [(if elif error)
              (unless (= (length args) 1)
                (error 'glsl "bad ~a：~s（应为 (~a 值)）" head s head))
              ((case head [(if) glsl-macro-if]
                          [(elif) glsl-macro-elif]
                          [else glsl-macro-error])
               (rw-macro-token (car args)))]
             [(else endif)
              (unless (null? args)
                (error 'glsl "bad ~a：~s（应为 (~a)）" head s head))
              ((if (eq? head 'else) glsl-macro-else glsl-macro-endif))]
             [(pragma)
              (unless (and (= (length args) 1) (string? (car args)))
                (error 'glsl "bad pragma：~s（应为 (pragma \"...\")）" s))
              (glsl-macro-pragma (car args))]
             [(extension)
              (unless (and (= (length args) 2) (symbol? (car args)) (symbol? (cadr args)))
                (error 'glsl "bad extension：~s（应为 (extension 名字 行为)）" s))
              (glsl-macro-extension (glsl-name (car args)) (glsl-name (cadr args)))]
             [else #f]))))

  ;; ---------- 接口反射：声明 → shader-type / shader-var ----------
  ;; 只"读"声明，不做组合（不合并多个 shader、不生成 setter）。
  ;; ★ 暂定：类型模型与反射形状见 shader-interface.rkt，尚未定稿，可能调整。

  ;; struct 定义：名字 → 字段 form 表
  (define (struct-def-of d)
    (and (pair? d) (eq? (car d) 'struct) (symbol? (cadr d))
         (cons (cadr d) (cddr d))))

  (define (collect-struct-defs datas)
    (for/fold ([h (hash)]) ([d (in-list datas)])
      (cond [(struct-def-of d) => (lambda (p) (hash-set h (car p) (cdr p)))]
            [else h])))

  ;; layout 项 → 接口里的统一表示：每项都是 (名) 或 (名 值)
  ;; 接口按 **GLSL 名** 存 layout 键（local-size-x → local_size_x）；
  ;; shader-var-layout-ref 同时接受表面名与 GLSL 名。
  (define (layout-item->iface it)
    (cond
      [(pair? it) (cons (glsl-layout-key-symbol (car it)) (cdr it))]
      [else (list (glsl-layout-key-symbol it))]))

  ;; 表面类型 → shader-type（struct 名查 struct-defs，其余查内建表）
  (define (surface->shader-type t struct-defs memo)
    (cond
      [(symbol? t)
       (or (hash-ref memo t #f)
           (cond
             [(hash-ref struct-defs t #f)
              => (lambda (fields)
                   (define ty (shader-struct-type t (for/list ([f (in-list fields)])
                                                    (field->shader-var f struct-defs memo))))
                   (hash-set! memo t ty) ty)]
             [else (or (builtin-type-of t)
                       (error 'glsl "接口反射：未知类型 ~s" t))]))]
      [(array-type? t)
       (shader-array-type (surface->shader-type (cadr t) struct-defs memo)
                        (if (null? (cddr t)) #f (caddr t)))]
      [(block-type? t)
       (shader-block-type (cadr t) (for/list ([f (in-list (cddr t))])
                                   (field->shader-var f struct-defs memo)))]
      [else (error 'glsl "接口反射：坏类型 ~s" t)]))

  ;; struct/block 成员 form → shader-var
  (define (field->shader-var f struct-defs memo)
    (define-values (quals after layout)
      (if (and (pair? f) (eq? (car f) 'layout))
          (let*-values ([(items rest) (collect-layout-items (cdr f))]
                        [(qs rest*) (collect-quals rest)])
            (values (map string->symbol qs) rest* (map layout-item->iface items)))
          (let-values ([(qs rest) (collect-quals f)])
            (values (map string->symbol qs) rest '()))))
    (shader-var (cadr after) (surface->shader-type (car after) struct-defs memo) quals layout '() #f))

  ;; 顶层声明 form → shader-var（不是声明、或没有变量名 → #f）
  (define (decl->shader-var d struct-defs memo)
    (define-values (quals after layout)
      (cond
        [(and (pair? d) (eq? (car d) 'layout))
         (let*-values ([(items rest) (collect-layout-items (cdr d))]
                       [(qs rest*) (collect-quals rest)])
           (values (map string->symbol qs) rest* (map layout-item->iface items)))]
        [(declaration? d)
         (let-values ([(qs rest) (collect-quals d)])
           (values (map string->symbol qs) rest '()))]
        [else (values '() '() '())]))
    (and (pair? after) (pair? (cdr after)) (symbol? (cadr after))
         (shader-var (cadr after) (surface->shader-type (car after) struct-defs memo) quals layout '() #f)))

  ;; 全部顶层声明 → 接口 datum
  (define (interface-datum datas)
    (define struct-defs (collect-struct-defs datas))
    (define memo (make-hash))
    (define vars
      (for/fold ([acc '()]) ([d (in-list datas)])
        (define v (decl->shader-var d struct-defs memo))
        (if v (cons v acc) acc)))
    (shader-interface->datum (shader-interface (reverse vars))))

  ;; 片段组合冲突检测：同一个 GLSL 标识符（结构名 / 函数名 / 顶层变量）
  ;; 只能定义一次。比较的是 **glsl-name 归一后**的名字：
  ;;   wow-name 与 wow_name 都生成 wow_name → 冲突
  ;;   gl-position 与 gl_Position 都生成 gl_Position → 冲突
  (define (check-duplicates datas)
    (define struct-defs (collect-struct-defs datas))
    (define memo (make-hash))
    (define seen (make-hash))
    (define (record! n what)
      (define g (glsl-name-symbol n))
      (cond
        [(hash-ref seen g #f)
         => (lambda (prev)
              (error 'glsl "片段组合冲突：~a（~a）与 ~a（~a）都会生成 GLSL 标识符 ~a"
                     (car prev) (cdr prev) n what g))]
        [else (hash-set! seen g (cons n what))]))
    (for ([d (in-list datas)])
      (cond
        [(struct-def-of d) => (lambda (p) (record! (car p) 'struct))]
        [(and (pair? d) (eq? (car d) 'define) (pair? (cadr d)) (symbol? (car (cadr d))))
         (record! (car (cadr d)) 'function)]
        [else
         (define v (decl->shader-var d struct-defs memo))
         (when v (record! (shader-var-name v) 'variable))])))

  ;; ---------- 顶层 ----------
  (define (rw-top t)
    (define head (car t))
    (define args (cdr t))
    (cond
      [(eq? head 'version)
       (define n (car args))
       (if (null? (cdr args))
           (glsl-version n)
           (glsl-version n (symbol->string (cadr args))))]
      [(eq? head 'define) (rw-fn args)]
      [(eq? head 'struct) (rw-struct args)]
      [(eq? head 'raw) (glsl-raw (car args))]
      [(rw-directive t) => (lambda (d) d)]  ; ★ 预处理指令（define-macro/ifdef/if/...）
      [(declaration? t)
       (rw-decl t)]
      [else (error 'glsl "bad top-level form: ~s" t)]))

  ;; 对一组 entries 跑完整编译期流程（词表 → 反射 → 重写 → 美化/组装）。
  ;; 返回 (values <shader-program> <iface-datum>)：后者是编译期表，供宏消费。
  (define (entries->program+iface entries)
    ;; 收集本块 struct 名，扩充类型集合
    (type-names builtin-types)
    (for ([e (in-list entries)])
      (define d (entry-datum e))
      (when (and (pair? d) (eq? 'struct (car d)))
        (when (builtin-type? (cadr d))
          (error 'glsl "struct 名不能与内建类型/别名冲突：~a" (cadr d)))
        (type-names (set-add (type-names) (cadr d)))))
    (define datas (map entry-datum entries))
    (check-duplicates datas)
    (define iface-datum (interface-datum datas))
    (define parts (map rw-top datas))
    (values (make-shader-program parts (map entry-source entries) iface-datum)
            iface-datum))

  (define (entries->program entries)
    (let-values ([(program _iface) (entries->program+iface entries)]) program)))

;; ---------- 入口宏：纯编译期变换 ----------

;; (glsl-fragment name form ...) —— 定义可复用的静态片段。
;; 展开为宏 name：(name ...) → (quote <chunk>)；chunk = (list entry ...)，已 flatten（含嵌套 glsl-splice）。
(define-syntax (glsl-fragment stx)
  (syntax-case stx ()
    [(_ name form ...)
     (identifier? #'name)
     (let ()
       (define entries (forms->entries (syntax->list #'(form ...))))
       (with-syntax ([entries-stx (datum->syntax stx entries)])
         #'(define-syntax name
             (lambda (use-stx)
               (syntax (quote entries-stx))))))]))

;; glsl-splice 只作为 (glsl ...) / glsl-fragment 顶层的 form 被识别；单独出现时清晰报错。
(define-syntax (glsl-splice stx)
  (raise-syntax-error 'glsl-splice "glsl-splice 只能写在 (glsl ...) 或 glsl-fragment 的顶层" stx))

;; (glsl form ...) —— 展开期跑完 S1–S8，产出 shader-program 常量。
(define-syntax (glsl stx)
  (syntax-case stx ()
    [(_ form ...)
     (let ()
       (define entries (forms->entries (syntax->list #'(form ...))))
       (define program (entries->program entries))
       ;; 产出运行期表达式：(datum->shader-program '<program-datum>)
       (datum->syntax #'glsl
                      (list 'datum->shader-program
                            (list 'quote (shader-program->datum program)))))]))

;; (glsl-shader name form ...) —— 定义具名 shader，并**额外把编译期接口表绑为 <name>-interface**。
;;   name          运行期：shader-program（datum->shader-program 重建）
;;   <name>-interface  编译期：宏，展开为 (quote <iface-datum>)，供其他宏读取（表驱动代码生成）
(define-syntax (glsl-shader stx)
  (syntax-case stx ()
    [(_ name form ...)
     (identifier? #'name)
     (let ()
       (define entries (forms->entries (syntax->list #'(form ...))))
       (define-values (program iface-datum) (entries->program+iface entries))
       (with-syntax ([prog-datum (datum->syntax stx (shader-program->datum program))]
                     [iface-datum-stx (datum->syntax stx iface-datum)]
                     [iface-id (format-id #'name "~a-interface" #'name)])
         #'(begin
             (define name (datum->shader-program 'prog-datum))
             (define-syntax iface-id
               (lambda (use-stx) (syntax (quote iface-datum-stx)))))))]))
