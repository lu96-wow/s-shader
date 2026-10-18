#lang racket/base

;; ============================================================
;; Slang 方言 · slang/log.rkt —— 编译器日志的解析
;;
;; 只做「日志行 → shader-error」；定位/渲染在 core 的 shader/error.rkt。
;;
;; 支持的两种位置格式（slangc / DXC 风格）：
;;   foo.slang:12:5: error 30015: undefined identifier 'x'
;;   foo.slang(12): error X3000: syntax error
;; 匹配不到行号的行原样保留（shader-error 的 line = #f）。
;; ============================================================

(require racket/list racket/string
         shader/error)

(provide parse-error-log)

;; file:line:col:
(define line-col-pattern #rx"^.*?:([0-9]+):([0-9]+):")
;; file(line):
(define paren-pattern #rx"^.*?[(]([0-9]+)[)]")

(define (line-of ln)
  (cond
    [(regexp-match line-col-pattern ln) => (lambda (m) (string->number (list-ref m 1)))]
    [(regexp-match paren-pattern ln) => (lambda (m) (string->number (list-ref m 1)))]
    [else #f]))

(define (parse-error-log log)
  (for/list ([ln (string-split log "\n")]
             #:unless (string=? ln ""))
    (shader-error (line-of ln) ln)))
