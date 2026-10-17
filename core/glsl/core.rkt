#lang racket/base

;; ============================================================
;; 块 1 · (glsl) 内 · glsl/core.rkt —— GLSL 字符串原语（语言实现，隔离），全部返回字符串、不含换行
;;
;; 规则：
;;   1. 文本都是字符串（类型 "vec2"、变量 "aPos"、运算符 "+"）；
;;      数字是 Racket 数，~a 输出。
;;   2. 表达式不带分号；语句带分号/花括号；花括号内用空格而非换行。
;;   3. 二元/一元/三元永远自带括号，优先级天然安全。
;;   4. 名字全部 glsl- 前缀，与 Racket 核心零冲突。
;;   5. 换行/缩进不属于核心（见 pretty.rkt）；
;;      例外：#version 等预处理指令必须独占一行，所以 glsl-version 保留结尾 \n。
;;
;; 分层：
;;   core.rkt          本层：字符串生成原语
;;   pretty.rkt        美化（字符串 → 多行缩进文本）
;;   glsl-program.rkt  (glsl ...) 的产物：带源映射的 GLSL 程序
;;   rewrite.rkt       (glsl ...) 宏（表面语法 → core 调用）
;; ============================================================

(require racket/format racket/string)

(provide
 ;; 拼装
 glsl-shader glsl-version glsl-raw
 ;; 预处理指令
 glsl-macro-define glsl-macro-undef
 glsl-macro-ifdef glsl-macro-ifndef glsl-macro-if glsl-macro-elif glsl-macro-else glsl-macro-endif
 glsl-macro-error glsl-macro-pragma glsl-macro-extension
 ;; 共享小工具
 ->str ident-char?
 ;; 声明
 glsl-decl glsl-in glsl-out glsl-uniform glsl-const glsl-layout glsl-layout-qual
 ;; 表达式
 glsl-call glsl-ctor glsl-bin glsl-unary glsl-ternary
 glsl-assign glsl-cassign glsl-swizzle glsl-field glsl-aref glsl-inc glsl-dec
 ;; 语句
 glsl-stmt glsl-block glsl-if glsl-for glsl-while glsl-do-while
 glsl-switch glsl-break glsl-continue glsl-return glsl-discard
 ;; 函数 / 结构
 glsl-param glsl-fn glsl-field-decl glsl-struct-decl)

;; ---------- 内部工具 ----------

;; 任意值 → 字符串：字符串原样，其余用 ~a；拒绝有理数（GLSL 无此字面量）
(define (->str x)
  (cond
    [(string? x) x]
    [(and (exact? x) (rational? x) (not (integer? x)))
     (error 'glsl "GLSL 没有有理数字面量：~s。请写小数（如 0.5）或用 (/ 1.0 2.0)" x)]
    [else (~a x)]))

;; GLSL 标识符字符（pretty 的词边界 / gl-error 的标识符识别共用）
(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

;; 若是 "{" 开头的块就不重复包，否则包成块（单行，空格分隔）
(define (block? x) (and (string? x) (string-prefix? x "{")))
(define (wrap-block x)
  (if (block? x) x (format "{ ~a }" x)))

;; 去掉结尾分号（for 的 init 子句复用 glsl-decl 时用）
(define (trim-semicolon str)
  (if (string-suffix? str ";")
      (substring str 0 (sub1 (string-length str)))
      str))

;; 限定符列表 → 前缀字符串（空列表 → ""）
(define (quals->prefix quals)
  (if (null? quals) "" (string-append (string-join quals " ") " ")))

;; 一组片段拼成空格分隔文本
(define (join-spaces xs)
  (string-join (map ->str xs) " "))

;; ---------- 0. 拼装 ----------

;; 拼装：片段之间用空格分隔（换行交给 pretty.rkt 的 glsl-pretty）
(define (glsl-shader . parts)
  (string-join (map ->str parts) " "))

(define (glsl-version n [profile #f])
  (if profile
      (format "#version ~a ~a\n" (->str n) (->str profile))
      (format "#version ~a\n" (->str n))))

(define (glsl-raw s) (->str s))

;; ---------- 0.5 预处理指令 ----------

;; 预处理指令都必须独占一行，所以每个都带结尾 \n。
;; 内容不参与 pretty 的 ; { } ( ) 重排——pretty.rkt 对「行首 #」整行原样复制。

;; #define：object-like（params=#f）或 function-like（params=参数名字符串列表）
(define (glsl-macro-define name params body)
  (define b (->str body))
  (define body-part (if (string=? b "") "" (format " ~a" b)))
  (if params
      (format "#define ~a(~a)~a\n"
              (->str name) (string-join (map ->str params) ", ") body-part)
      (format "#define ~a~a\n" (->str name) body-part)))

(define (glsl-macro-undef name)
  (format "#undef ~a\n" (->str name)))

(define (glsl-macro-ifdef name)
  (format "#ifdef ~a\n" (->str name)))

(define (glsl-macro-ifndef name)
  (format "#ifndef ~a\n" (->str name)))

(define (glsl-macro-if expr)
  (format "#if ~a\n" (->str expr)))

(define (glsl-macro-elif expr)
  (format "#elif ~a\n" (->str expr)))

(define (glsl-macro-else)
  "#else\n")

(define (glsl-macro-endif)
  "#endif\n")

(define (glsl-macro-error msg)
  (format "#error ~a\n" (->str msg)))

(define (glsl-macro-pragma body)
  (format "#pragma ~a\n" (->str body)))

;; #extension 名字 : 行为（行为 = enable / disable / warn / require）
(define (glsl-macro-extension name behavior)
  (format "#extension ~a : ~a\n" (->str name) (->str behavior)))

;; ---------- 1. 声明 ----------

;; quals = 字符串列表，如 '("in")、'("in" "flat")，无则 '()
;; init  = 表达式字符串或 #f
(define (glsl-decl quals type name [init #f])
  (format "~a~a ~a~a;"
          (quals->prefix quals) (->str type) (->str name)
          (if init (format " = ~a" (->str init)) "")))

(define (glsl-in t n) (glsl-decl '("in") t n))
(define (glsl-out t n) (glsl-decl '("out") t n))
(define (glsl-uniform t n) (glsl-decl '("uniform") t n))
(define (glsl-const t n init) (glsl-decl '("const") t n init))

;; spec = 字符串或 (名 值) 的列表：'("std140" ("location" 0) ("binding" 1))
(define (layout-item->str p)
  (if (list? p)
      (format "~a = ~a" (car p) (->str (cadr p)))
      (->str p)))

(define (glsl-layout spec quals type name [init #f])
  (format "~a~a ~a ~a~a;"
          (format "layout(~a)" (string-join (map layout-item->str spec) ", "))
          (if (null? quals) "" (string-append " " (string-join quals " ")))
          (->str type) (->str name)
          (if init (format " = ~a" (->str init)) "")))

;; 独立 layout（无类型/变量名）：layout(...) in;（compute/几何/early_fragment_tests）
(define (glsl-layout-qual spec quals)
  (format "layout(~a)~a;"
          (string-join (map layout-item->str spec) ", ")
          (if (null? quals) "" (string-append " " (string-join quals " ")))))

;; ---------- 2. 表达式 ----------

(define (glsl-call f . args)
  (format "~a(~a)" (->str f) (string-join (map ->str args) ", ")))

;; 构造器 = 类型名当函数调用
(define glsl-ctor glsl-call)

(define (glsl-bin op . args)
  (format "(~a)" (string-join (map ->str args) (format " ~a " (->str op)))))

(define (glsl-unary op x)
  (format "(~a~a)" (->str op) (->str x)))

(define (glsl-ternary c t e)
  (format "(~a ? ~a : ~a)" (->str c) (->str t) (->str e)))

(define (glsl-assign l r)
  (format "~a = ~a" (->str l) (->str r)))

(define (glsl-cassign op l r)
  (format "~a ~a= ~a" (->str l) (->str op) (->str r)))

(define (glsl-swizzle comps v)
  (format "~a.~a" (->str v) (->str comps)))

(define (glsl-field f s)
  (format "~a.~a" (->str s) (->str f)))

(define (glsl-aref a i)
  (format "~a[~a]" (->str a) (->str i)))

(define (glsl-inc x [post #f])
  (if post (format "~a++" (->str x)) (format "++~a" (->str x))))

(define (glsl-dec x [post #f])
  (if post (format "~a--" (->str x)) (format "--~a" (->str x))))

;; ---------- 3. 语句 ----------

(define (glsl-stmt e) (format "~a;" (->str e)))

(define (glsl-block . stmts)
  (format "{ ~a }" (join-spaces stmts)))

(define (glsl-if c t [e #f])
  (if e
      (format "if (~a) ~a else ~a"
              (->str c) (wrap-block t)
              ;; else 分支若本身是 if → 生成 else if（不套多余的 {}）
              (if (string-prefix? (->str e) "if ") (->str e) (wrap-block e)))
      (format "if (~a) ~a" (->str c) (wrap-block t))))

(define (glsl-for init cond update . body)
  (format "for (~a; ~a; ~a) ~a"
          (trim-semicolon (->str init)) (->str cond) (->str update)
          (wrap-block (join-spaces body))))

(define (glsl-while cond . body)
  (format "while (~a) ~a" (->str cond) (wrap-block (join-spaces body))))

(define (glsl-do-while cond . body)
  (format "do ~a while (~a);" (wrap-block (join-spaces body)) (->str cond)))

;; switch：cases = (list (list "1" "{...}") ...)，default = "{...}" 或 #f
;; 每个 case 体是块，glsl-pretty 靠 {} 自动排版
(define (glsl-switch test cases [default #f])
  (format "switch (~a) { ~a ~a }"
          (->str test)
          (string-join (for/list ([c cases])
                         (format "case ~a: ~a" (->str (car c)) (cadr c)))
                       " ")
          (if default (format "default: ~a" default) "")))

(define (glsl-break) "break;")
(define (glsl-continue) "continue;")

(define (glsl-return [v #f])
  (if v (format "return ~a;" (->str v)) "return;"))

(define (glsl-discard) "discard;")

;; ---------- 4. 函数 / 结构 ----------

(define (glsl-param quals type name)
  (format "~a~a ~a" (quals->prefix quals) (->str type) (->str name)))

(define (glsl-fn name ret params . body)
  (format "~a ~a(~a) { ~a }"
          (->str ret) (->str name)
          (string-join (map ->str params) ", ")
          (join-spaces body)))

(define (glsl-field-decl type name)
  (format "~a ~a;" (->str type) (->str name)))

(define (glsl-struct-decl name . fields)
  (format "struct ~a { ~a };"
          (->str name) (join-spaces fields)))
