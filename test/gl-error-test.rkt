#lang racket/base
;; ============================================================
;; gl-error 的行级源映射测试
;; 运行：racket test/gl-error-test.rkt
;; ============================================================
(require rackunit racket/string
         "../glsl/error.rkt"
         "../glsl/rewrite.rkt")

;; 定位辅助：log → located-error
(define (loc log prog)
  (locate-gl-error prog (car (parse-gl-error-log log))))

(define prog
  (glsl (version 330 core)
        (uniform float uTime)
        (out vec4 c)
        (define (main) void
          (set! c (vec4 uTime)))))

;; ---------- 行 → form ----------
;; GLSL 第 5 行（main 函数体）→ 覆盖它的顶层 form
(define le (loc "0:5(21): error: `uTime' undeclared\n" prog))
(check-not-false (located-error-form le))
(check-equal? (glsl-form-text (located-error-form le))
              '(define (main) void (set! c (vec4 uTime))))

;; ---------- ② 美化 GLSL：标出报错行 ----------
(define g (render-gl-pretty prog (list le)))
(check-true (regexp-match? #rx"OpenGL source:" g))
(check-true (regexp-match? #rx"> +5 \\|" g))                 ; 第 5 行前有 >

;; ---------- ③ 源文件：标出该 form 的源行 ----------
(define s (render-sexpr-pretty (list le)))
(check-true (regexp-match? #rx"s-expr source:" s))
(check-true (regexp-match?
             (regexp (format "> +~a \\|" (glsl-form-src-line (located-error-form le))))
             s))

;; ---------- 行号越界 → form=#f，③ 空（不崩）----------
(define le2 (loc "0:99(1): error: boom\n" prog))
(check-false (located-error-form le2))
(check-equal? (render-sexpr-pretty (list le2)) "")

;; ---------- 无行号的日志行 → line/form 都 #f ----------
(define le3 (loc "note: something happened\n" prog))
(check-false (located-error-line le3))
(check-false (located-error-form le3))

;; ---------- render-error 三段拼装 ----------
(define r (render-error "0:5(21): error: `uTime' undeclared\n" prog (list le)))
(check-true (regexp-match? #rx"OpenGL log:" r))
(check-true (regexp-match? #rx"OpenGL source:" r))
(check-true (regexp-match? #rx"s-expr source:" r))

;; ---------- 第一个 form 的行也对 ----------
(define le4 (loc "0:2(9): error: `uTime' undeclared\n" prog))
(check-equal? (glsl-form-text (located-error-form le4)) '(uniform float uTime))
