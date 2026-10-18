#lang racket/base
;; ============================================================
;; 边界情况测试：行级源映射 + shader-error 渲染（glsl-unquote 已移除）
;; 运行：racket test/edge-test.rkt
;; ============================================================
(require rackunit racket/string
         "../glsl/error.rkt"
         "../glsl/rewrite.rkt")

;; ---------- 小工具 ----------

(define (src-lines p)
  (define s (shader-program-src p))
  (if (string=? s "") 0 (length (string-split s "\n"))))

;; 每个 GLSL 行 → form（#f 表示没有 form 覆盖）
(define (line->form p)
  (for/list ([i (in-range 1 (add1 (src-lines p)))]) (shader-program-lookup p i)))

;; 每行都有 form 覆盖（没有"缝"）？
(define (no-gaps? p)
  (andmap (lambda (f) (not (eq? f #f))) (line->form p)))

(define (form->text f) (and f (shader-form-text f)))

;; ---------- ① 行映射：空 / 空拼接 ----------

(define p-empty (glsl))                     ; 零个 form
(check-equal? (shader-program-src p-empty) "")
(check-equal? (shader-program-forms p-empty) '())
(check-false (shader-program-lookup p-empty 1))

(define p-only-empty (glsl (raw "")))
(check-equal? (shader-program-src p-only-empty) "")
(check-equal? (length (shader-program-forms p-only-empty)) 1)
(define f0 (car (shader-program-forms p-only-empty)))
(check-equal? (shader-form-text f0) '(raw ""))
(check-equal? (shader-form-start-line f0) 1)
(check-equal? (shader-form-end-line f0) 0)          ; 0 行 → 区间退化为 start>end
(check-false (shader-program-lookup p-only-empty 1))

;; 中间空片段不"抢"行：第 2 行仍属于 out
(define p-mid-empty (glsl (version 330 core) (raw "") (out vec4 c)))
(check-equal? (form->text (shader-program-lookup p-mid-empty 1)) '(version 330 core))
(check-equal? (form->text (shader-program-lookup p-mid-empty 2)) '(out vec4 c))

;; 末尾/连续空片段
(define p-tail-empty (glsl (version 330 core) (out vec4 c) (raw "")))
(check-equal? (form->text (shader-program-lookup p-tail-empty 2)) '(out vec4 c))
(define p-two-empty (glsl (raw "") (raw "") (out vec4 c)))
(check-equal? (form->text (shader-program-lookup p-two-empty 1)) '(out vec4 c))

;; ---------- ② 行映射：多行拼接 / 子程序 / raw 含换行 ----------

(define p-multi
  (glsl (version 330 core)
        (raw "uniform float a;\nuniform float b;\nuniform float c;")
        (out vec4 d)))
(check-equal? (src-lines p-multi) 5)
(for ([i '(2 3 4)])                                         ; 2..4 全归同一个多行 form
  (check-equal? (form->text (shader-program-lookup p-multi i))
                '(raw "uniform float a;\nuniform float b;\nuniform float c;")))
(check-equal? (form->text (shader-program-lookup p-multi 5)) '(out vec4 d))

(define p-raw (glsl (version 330 core) (raw "int a = 1;\nint b = 2;") (out vec4 c)))
(for ([i '(2 3)]) (check-equal? (form->text (shader-program-lookup p-raw i)) '(raw "int a = 1;\nint b = 2;")))

;; ---------- ③ 行映射：预处理 / 同一源码行多 form / 多行函数 ----------

(define p-pp (glsl (ifdef FOO) (uniform float a) (else) (uniform float b) (endif)))
(check-equal? (src-lines p-pp) 5)
(check-equal? (map form->text (line->form p-pp))
              '((ifdef FOO) (uniform float a) (else) (uniform float b) (endif)))

;; 三个 form 写在同一行源码上 → 生成的 GLSL 仍是各自独立一行
(define p-oneline (glsl (version 330 core) (uniform float a) (out vec4 b)))
(check-equal? (map form->text (line->form p-oneline))
              '((version 330 core) (uniform float a) (out vec4 b)))

;; 多行函数：函数体每一 GLSL 行都归该 form
(define p-fn
  (glsl (version 330 core)
        (define (main) void
          (float x 1.0)
          (float y 2.0)
          (set! gl_Position (vec4 x y 0.0 1.0)))))
(check-equal? (src-lines p-fn) 6)
(check-equal? (form->text (shader-program-lookup p-fn 1)) '(version 330 core))
(for ([i '(2 3 4 5 6)])
  (check-equal? (form->text (shader-program-lookup p-fn i))
                '(define (main) void (float x 1.0) (float y 2.0)
                                      (set! gl_Position (vec4 x y 0.0 1.0)))))

;; ---------- ④ 行映射：越界 / 每行都有 form ----------

(for ([p (list p-multi p-raw p-pp p-oneline p-fn)])
  (check-true (no-gaps? p)))                       ; 没有缝
(check-false (shader-program-lookup p-fn -1))
(check-false (shader-program-lookup p-fn 0))
(check-false (shader-program-lookup p-fn 999))

;; 空 form 的区间退化（start>end）
(define empty-form (for/first ([f (shader-program-forms p-only-empty)]) f))
(check-true (> (shader-form-start-line empty-form) (shader-form-end-line empty-form)))

;; ---------- ⑤ shader-error：行定位 ----------

(define gp
  (glsl (version 330 core)
        (uniform float uTime)
        (out vec4 c)
        (define (main) void (set! c (vec4 uTime)))))

(define (located1 log) (locate-shader-error gp (car (parse-shader-error-log log))))

;; 正常：GLSL 行 5 → main form
(define le (located1 "0:5(15): error: `uTime' undeclared\n"))
(check-equal? (shader-form-text (located-error-form le))
              '(define (main) void (set! c (vec4 uTime))))

;; 第 1 行 → version form；② 在 GLSL 第 1 行标 >
(check-equal? (shader-form-text (located-error-form (located1 "0:1(0): error: x\n")))
              '(version 330 core))
(check-true (regexp-match? #rx"> +1 \\|" (render-gl-pretty gp (list (located1 "0:1(0): error: x\n")))))

;; 越界 / 行 0 / 无行号 → form #f，③ 空
(for ([log (list "0:99(1): error: boom\n" "0:0(0): error: boom\n" "note: hi\n")])
  (define e (locate-shader-error gp (car (parse-shader-error-log log))))
  (check-false (located-error-form e))
  (check-equal? (render-sexpr-pretty (list e)) ""))

;; 空日志 → 没有 located
(check-equal? (parse-shader-error-log "") '())

;; 多行日志 → 只取第一条错误驱动 ②/③
(define located-multi (map (lambda (e) (locate-shader-error gp e))
                           (parse-shader-error-log "0:2(1): error: a\n0:4(1): error: b\n")))
(check-equal? (length located-multi) 2)
(check-true (regexp-match? #rx"> +2 \\|" (render-gl-pretty gp located-multi)))  ; 第一条（行 2）

;; ---------- ⑥ shader-error：空程序 / 无源路径 / 裸字符串 ----------

;; 空程序：② 不再输出孤零零的 "OpenGL source:" 头
(define pe (glsl))
(define le-empty (locate-shader-error pe (car (parse-shader-error-log "0:1(0): error: x\n"))))
(check-equal? (render-gl-pretty pe (list le-empty)) "")
(check-equal? (render-error "0:1(0): error: x\n" pe (list le-empty))
              "OpenGL log:\n0:1(0): error: x\n")

;; 无源路径（手工构造 src-path/src-line = #f）→ 回退到格式化 datum
(define pe2 (make-shader-program (list (glsl-version 330 "core"))
                               (list (list #f #f '(version 330 core)))
                               '()))
(define le2 (locate-shader-error pe2 (car (parse-shader-error-log "0:1(0): error: y\n"))))
(check-equal? (render-sexpr-pretty (list le2))
              "s-expr source:\n(version 330 core)")

;; 裸字符串 src（非 shader-program）→ 无 form，③ 空
(define le3 (locate-shader-error "void main(){}" (car (parse-shader-error-log "0:1(0): error: z\n"))))
(check-false (located-error-form le3))
(check-equal? (render-sexpr-pretty (list le3)) "")

;; ---------- ⑦ 端到端：render-error 三段都在 ----------
(define full (render-error "0:5(15): error: `uTime' undeclared\n" gp (list le)))
(check-true (regexp-match? #rx"OpenGL log:" full))
(check-true (regexp-match? #rx"OpenGL source:" full))
(check-true (regexp-match? #rx"s-expr source:" full))
