#lang racket/base

;; ============================================================
;; GLSL 方言 · glsl/core.rkt —— GLSL 字符串原语（语言实现，隔离），全部返回字符串、不含换行
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
;; 表达式 / 语句 / 函数这些「C 系共同形状」在 core 的 shader/emit.rkt；
;; 本模块只放 GLSL 特有的：`#version`、预处理指令、`layout(...)`，并把
;; 共同形状用 glsl- 前缀再导出（保持 (glsl ...) 实现侧的名字稳定）。
;; ============================================================

(require racket/format racket/string
         shader/emit-util
         shader/emit)

(provide
 ;; 拼装
 glsl-version glsl-raw
 ;; 预处理指令
 glsl-macro-define glsl-macro-undef
 glsl-macro-ifdef glsl-macro-ifndef glsl-macro-if glsl-macro-elif glsl-macro-else glsl-macro-endif
 glsl-macro-error glsl-macro-pragma glsl-macro-extension
 ;; 共享小工具
 ->str ident-char? join-spaces
 ;; 声明
 glsl-decl glsl-in glsl-out glsl-uniform glsl-const glsl-layout glsl-layout-qual
 ;; 表达式
 glsl-call glsl-ctor glsl-bin glsl-unary glsl-ternary
 glsl-assign glsl-cassign glsl-swizzle glsl-field glsl-aref glsl-inc glsl-dec
 ;; 语句
 glsl-stmt glsl-block glsl-if glsl-for glsl-while glsl-do-while
 glsl-switch glsl-break glsl-continue glsl-return glsl-discard
 ;; 函数 / 结构
 glsl-struct-decl glsl-param glsl-fn glsl-field-decl)

;; ---------- 内部工具 ----------

;; 拼装小工具（->str / ident-char? / block? / wrap-block / trim-semicolon /
;; quals->prefix / join-spaces）在 core 的 shader/emit-util.rkt —— 两个方言共用。

;; ---------- 0. 拼装 ----------

;; 拼装：片段之间用空格分隔 → 直接用 core 的 join-spaces（emit-util.rkt）

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

;; ---------- 2. 表达式 / 3. 语句 / 4. 函数 ----------
;; 共同形状由 shader/emit.rkt 提供；这里用 glsl- 前缀再导出。

(define glsl-call emit-call)
(define glsl-ctor emit-ctor)
(define glsl-bin emit-bin)
(define glsl-unary emit-unary)
(define glsl-ternary emit-ternary)
(define glsl-assign emit-assign)
(define glsl-cassign emit-cassign)
(define glsl-swizzle emit-swizzle)
(define glsl-field emit-field)
(define glsl-aref emit-aref)
(define glsl-inc emit-inc)
(define glsl-dec emit-dec)

(define glsl-stmt emit-stmt)
(define glsl-block emit-block)
(define glsl-if emit-if)
(define glsl-for emit-for)
(define glsl-while emit-while)
(define glsl-do-while emit-do-while)
(define glsl-switch emit-switch)
(define glsl-break emit-break)
(define glsl-continue emit-continue)
(define glsl-return emit-return)
(define glsl-discard emit-discard)

(define glsl-param emit-param)
(define glsl-fn emit-fn)
(define glsl-field-decl emit-field-decl)

(define (glsl-struct-decl name . fields)
  (format "struct ~a { ~a };"
          (->str name) (join-spaces fields)))
