#lang racket/base

;; ============================================================
;; GLSL 方言 · glsl/log.rkt —— 驱动编译器日志的解析（方言知识）
;;
;; 只做「日志行 → shader-error」，不做定位/渲染（那在 core 的 shader/error.rkt）：
;;   定位/渲染是方言无关的（都是「美化源码第 N 行 → 顶层 form → 源文件行」）。
;;
;; 位置格式是驱动/编译器相关的：
;;   Mesa / GLSL：  0:12(5): error: ...
;;   Slang：        file.slang:12:5: error ...
;;   DXC：          file.hlsl:12:5: error: ...
;; 所以每方言一个解析器，返回统一的 shader-error。
;; ============================================================

(require racket/list racket/string
         shader/error)

(provide parse-error-log)

;; Mesa：group1 = 着色器号，group2 = 行，group3 = 列（匹配但不用）
(define log-line-pattern #rx"([0-9]+):([0-9]+)[(]([0-9]+)[)]:")

(define (parse-error-log log)
  (for/list ([ln (string-split log "\n")]
             #:unless (string=? ln ""))
    (define m (regexp-match log-line-pattern ln))
    (if m
        (shader-error (string->number (list-ref m 2)) ln)
        (shader-error #f ln))))
