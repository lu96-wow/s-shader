#lang racket/base

;; ============================================================
;; composition-test.rkt —— surface chunk 组合（glsl-fragment / glsl-splice）
;; 运行：racket test/composition-test.rkt
;; 覆盖：片段复用、递归 glsl-splice、词表共享、interface 合并、定义处源映射、冲突报错
;; ============================================================

(require rackunit
         "../shader/type.rkt"
         "../shader/interface.rkt"
         racket/string
         "../glsl/rewrite.rkt"
         "../shader/program.rkt"
         "../shader/pretty.rkt")

;; ---------- 片段定义（定义处）----------
(glsl-fragment base
  (struct Light (vec3 position) (vec3 color))
  (uniform Light uLight))

(glsl-fragment lighting
  (glsl-splice base)                                   ; 嵌套 glsl-splice
  (define (lambert (vec3 n) (vec3 l)) float
    (max (dot n l) 0.0)))

(glsl-fragment fog
  (uniform float uFogDensity))

(define shader
  (glsl (version 330 core)
        (glsl-splice lighting)
        (glsl-splice fog)
        (uniform vec3 uEye)
        (in vec3 aPos)
        (define (main) void
          (set! gl_Position (vec4 aPos 1.0)))))

;; ---------- 文本：片段内容都在 ----------
(define src (shader-program-src shader))
(check-true (string-contains? src "struct Light"))
(check-true (string-contains? src "uniform Light uLight;"))
(check-true (string-contains? src "float lambert(vec3 n, vec3 l)"))
(check-true (string-contains? src "uniform float uFogDensity;"))
(check-true (string-contains? src "uniform vec3 uEye;"))
(check-true (string-contains? src "in vec3 aPos;"))

;; ---------- 词表共享 + interface 合并 ----------
;; base 里定义的 Light 被 lighting 用（否则 lambert 的 struct 引用会报错）
(check-equal? (map shader-var-name (shader-interface-vars (shader-program-interface shader)))
              '(uLight uFogDensity uEye aPos))

;; ---------- 定义处源映射：struct Light 那行应指向 base 定义处 ----------
(define light-glsl-line
  (for/first ([i (in-naturals 1)]
              [line (in-list (string-split src "\n"))]
              #:when (string-contains? line "struct Light"))
    i))
(define light-form (shader-program-lookup shader light-glsl-line))
(check-equal? (shader-form-text light-form) '(struct Light (vec3 position) (vec3 color)))
(check-true (regexp-match? #rx"composition-test[.]rkt$" (shader-form-src-path light-form)))
(check-true (< (shader-form-src-line light-form) 40))       ; 定义处（文件靠前），不是使用处
(check-equal? (shader-form-text (shader-program-lookup shader 1)) '(version 330 core))

;; ---------- 冲突检测（决策 3）：编译期报错 ----------
(glsl-fragment dup-a (uniform float uX))
(glsl-fragment dup-b (uniform float uX))
(check-exn exn:fail?
  (lambda () (expand #'(glsl (version 330 core) (glsl-splice dup-a) (glsl-splice dup-b)))))

;; 同名 struct 也算冲突
(glsl-fragment s1 (struct Foo (float x)))
(glsl-fragment s2 (struct Foo (float y)))
(check-exn exn:fail?
  (lambda () (expand #'(glsl (glsl-splice s1) (glsl-splice s2)))))

;; ---------- glsl-splice 的错误用法 ----------
;; glsl-splice 出现在 (glsl ...) / glsl-fragment 之外
(check-exn exn:fail? (lambda () (expand #'(glsl-splice base))))
;; glsl-splice 的目标不是片段宏
(define not-a-fragment 1)
(check-exn exn:fail? (lambda () (expand #'(glsl (glsl-splice not-a-fragment)))))
;; 形状错误
(check-exn exn:fail? (lambda () (expand #'(glsl (glsl-splice base extra)))))

(displayln "composition 全部测试通过")
