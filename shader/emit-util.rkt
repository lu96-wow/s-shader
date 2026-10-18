#lang racket/base

;; ============================================================
;; core · shader/emit-util.rkt —— 两个方言共用的字符串拼装小工具
;;
;; 纯函数，全部返回字符串、不含换行。方言的 core.rkt 在此基础上加自己的原语：
;;   GLSL：layout(...) / #version / 预处理指令 …
;;   Slang：[[vk::binding]] / [numthreads] / 语义注解 …
;;
;; 规则（两方言一致）：
;;   1. 文本都是字符串，数字是 Racket 数
;;   2. 表达式不带分号；语句带分号/花括号；花括号内用空格而非换行
;;   3. 二元/一元/三元永远自带括号，优先级天然安全
;;   4. 换行/缩进不属于本层（见 pretty.rkt）；预处理指令等必须独占一行的由方言负责带 \n
;; ============================================================

(require racket/format racket/string)

(provide ->str ident-char?
         block? wrap-block trim-semicolon quals->prefix join-spaces)

;; ---------- 值 → 文本 ----------

;; 任意值 → 字符串：字符串原样，其余用 ~a；拒绝有理数（着色语言都没有这种字面量）
(define (->str x)
  (cond
    [(string? x) x]
    [(and (exact? x) (rational? x) (not (integer? x)))
     (error '->str "没有有理数字面量：~s。请写小数（如 0.5）或用 (/ 1.0 2.0)" x)]
    [else (~a x)]))

;; 标识符字符（pretty 的词边界 / 错误日志的标识符识别共用）
(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

;; ---------- 块的拼装 ----------

;; 若是 "{" 开头的块就不重复包，否则包成块（单行，空格分隔）
(define (block? x) (and (string? x) (string-prefix? x "{")))

(define (wrap-block x)
  (if (block? x) x (format "{ ~a }" x)))

;; 去掉结尾分号（for 的 init 子句复用声明原语时用）
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
