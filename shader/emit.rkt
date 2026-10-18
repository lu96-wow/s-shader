#lang racket/base

;; ============================================================
;; core · shader/emit.rkt —— 表达式 / 语句 / 函数的字符串原语（两方言共用）
;;
;; 这些形状在 GLSL 与 Slang 里逐字相同（C 系语法）：
;;   (a + b)   a[i]   a.b   f(x)   if (c) { … } else { … }   类型 名(参数) { … }
;; 方言自己的形状不在这里：
;;   GLSL：layout(...) / #version / 预处理指令
;;   Slang：[[vk::…]] / cbuffer / 语义注解 / 特化常量
;;
;; 规则：表达式不带分号；语句带分号/花括号；花括号内用空格；二元/一元/三元永远自带括号。
;; ============================================================

(require racket/string
         "emit-util.rkt")

(provide emit-stmt emit-block
         emit-if emit-for emit-while emit-do-while emit-switch
         emit-break emit-continue emit-return emit-discard
         emit-call emit-ctor emit-bin emit-unary emit-ternary
         emit-assign emit-cassign emit-inc emit-dec
         emit-swizzle emit-field emit-aref
         emit-fn emit-param emit-field-decl)

;; ---------- 表达式 ----------

(define (emit-call f . args)
  (format "~a(~a)" (->str f) (string-join (map ->str args) ", ")))

;; 构造器 = 类型名当函数调用
(define emit-ctor emit-call)

(define (emit-bin op . args)
  (format "(~a)" (string-join (map ->str args) (format " ~a " (->str op)))))

(define (emit-unary op x)
  (format "(~a~a)" (->str op) (->str x)))

(define (emit-ternary c t e)
  (format "(~a ? ~a : ~a)" (->str c) (->str t) (->str e)))

(define (emit-assign l r)
  (format "~a = ~a" (->str l) (->str r)))

(define (emit-cassign op l r)
  (format "~a ~a= ~a" (->str l) (->str op) (->str r)))

(define (emit-swizzle comps v)
  (format "~a.~a" (->str v) (->str comps)))

(define (emit-field f s)
  (format "~a.~a" (->str s) (->str f)))

(define (emit-aref a i)
  (format "~a[~a]" (->str a) (->str i)))

(define (emit-inc x [post #f])
  (if post (format "~a++" (->str x)) (format "++~a" (->str x))))

(define (emit-dec x [post #f])
  (if post (format "~a--" (->str x)) (format "--~a" (->str x))))

;; ---------- 语句 ----------

(define (emit-stmt e) (format "~a;" (->str e)))

(define (emit-block . stmts)
  (format "{ ~a }" (join-spaces stmts)))

(define (emit-if c t [e #f])
  (if e
      (format "if (~a) ~a else ~a"
              (->str c) (wrap-block t)
              ;; else 分支若本身是 if → 生成 else if（不套多余的 {}）
              (if (string-prefix? (->str e) "if ") (->str e) (wrap-block e)))
      (format "if (~a) ~a" (->str c) (wrap-block t))))

(define (emit-for init cond update . body)
  (format "for (~a; ~a; ~a) ~a"
          (trim-semicolon (->str init)) (->str cond) (->str update)
          (wrap-block (join-spaces body))))

(define (emit-while cond . body)
  (format "while (~a) ~a" (->str cond) (wrap-block (join-spaces body))))

(define (emit-do-while cond . body)
  (format "do ~a while (~a);" (wrap-block (join-spaces body)) (->str cond)))

;; switch：cases = (list (list "1" "{...}") ...)，default = "{...}" 或 #f
(define (emit-switch test cases [default #f])
  (format "switch (~a) { ~a ~a }"
          (->str test)
          (string-join (for/list ([c cases])
                         (format "case ~a: ~a" (->str (car c)) (cadr c)))
                       " ")
          (if default (format "default: ~a" default) "")))

(define (emit-break) "break;")
(define (emit-continue) "continue;")

(define (emit-return [v #f])
  (if v (format "return ~a;" (->str v)) "return;"))

(define (emit-discard) "discard;")

;; ---------- 函数 / 字段 ----------

;; 参数：限定符前缀 + 类型 + 名字（注解由方言自己拼）
(define (emit-param quals type name)
  (format "~a~a ~a" (quals->prefix quals) (->str type) (->str name)))

;; 函数：属性/注解由方言自己拼在前后的位置
(define (emit-fn name ret params . body)
  (format "~a ~a(~a) { ~a }"
          (->str ret) (->str name)
          (string-join (map ->str params) ", ")
          (join-spaces body)))

(define (emit-field-decl type name)
  (format "~a ~a;" (->str type) (->str name)))
