#lang racket/base

;; ============================================================
;; Slang 方言 · slang/log.rkt —— 编译器日志的解析
;;
;; 只做「日志 → shader-error 列表」；定位/渲染在 core 的 shader/error.rkt。
;;
;; slangc 的默认诊断是**两行**：
;;     error[E30015]: undefined identifier
;;      --> /tmp/x.slang:1:25
;;        |
;;      1 | void main() { float x = y; }
;; 所以「位置」在 `-->` 行，「消息」在上一行 `error[...]` 行。
;; 也兼容单行形式（DXC / 其它工具链）：
;;     foo.slang:12:5: error 30015: …
;;     foo.slang(12): error X3000: …
;; 匹配不到行号的行保留，line = #f。
;; ============================================================

(require racket/list racket/string
         shader/error)

(provide parse-error-log)

;; --> file:line:col      ← slangc
(define arrow-pattern #rx"^[ \t]*-->[ \t]+.*?:([0-9]+):([0-9]+)[ \t]*$")
;; file:line:col:          ← 单行形式（冒号结尾）
(define line-col-pattern #rx"^.*?:([0-9]+):([0-9]+):")
;; file(line):
(define paren-pattern #rx"^.*?[(]([0-9]+)[)]")
;; 诊断头：error[...]: msg / warning[...]: msg
(define head-pattern #rx"^[ \t]*(error|warning)")

(define (line-of ln)
  (cond
    [(regexp-match arrow-pattern ln) => (lambda (m) (string->number (list-ref m 1)))]
    [(regexp-match line-col-pattern ln) => (lambda (m) (string->number (list-ref m 1)))]
    [(regexp-match paren-pattern ln) => (lambda (m) (string->number (list-ref m 1)))]
    [else #f]))

(define (parse-error-log log)
  (define out '())
  (define pending-head #f)
  (for ([ln (in-list (string-split log "\n"))]
        #:unless (string=? ln ""))
    (cond
      ;; 诊断头：记下来，等位置行
      [(regexp-match head-pattern ln)
       (set! pending-head (string-trim ln))]
      ;; 位置行之后的源码片段 / 竖线行：不是独立诊断，跳过
      [(regexp-match #rx"^[ \t]*([|]|[0-9]+ [|])" ln) (void)]
      [else
       (define line (line-of ln))
       (cond
         [line
          (set! out (cons (shader-error line (or pending-head ln)) out))
          (set! pending-head #f)]
         [(string? pending-head)
          (set! out (cons (shader-error #f pending-head) out))
          (set! pending-head #f)]
         [else
          (set! out (cons (shader-error #f ln) out))])]))
  ;; 收尾：只有头没有位置
  (when pending-head
    (set! out (cons (shader-error #f pending-head) out)))
  (reverse out))
