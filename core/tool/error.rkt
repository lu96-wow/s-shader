#lang racket/base

;; ============================================================
;; 胶水 · tool/error.rkt —— OpenGL 报错的解析/定位/渲染（纯函数层）
;;
;; ★ 只保证「行」正确，不做列 / 标识符级精确定位：
;;     GLSL 行 → 覆盖该行的顶层 form → 该 form 的源文件行。
;;   源行用 ">" 前缀标出（不画列级 caret）。
;;
;; 报错拆成三个独立的"视角"，每个只做一件事：
;;   ① OpenGL 行列报错   原始编译器日志
;;   ② OpenGL 美化报错   美化后的 GLSL 源码 + 标出报错行
;;   ③ s表达式 源文件     源文件 + 标出对应源行
;;
;; 全部是 数据 → lambda → 数据 的纯函数（读源文件是报错路径上唯一的 IO）。
;; ============================================================

(require racket/string racket/file "../glsl/program.rkt")

(provide parse-gl-error-log locate-gl-error render-error
         render-gl-linecol render-gl-pretty render-sexpr-pretty
         (struct-out gl-error) (struct-out located-error))

;; ---------- 数据 ----------

;; 一条解析出的编译器错误：只要行（列不用）
(struct gl-error (line msg) #:transparent)

;; 一条定位后的错误：line/msg = GLSL 行与原始消息；form = 覆盖该行的顶层 form（#f = 无）
(struct located-error (line msg form) #:transparent)

;; ---------- ① 解析 ----------

;; 驱动数据：日志行的位置格式。Mesa：0:行(列): error: 消息
;; 正则 group2 = 行，group3 = 列（匹配但不用）
(define log-line-pattern #rx"([0-9]+):([0-9]+)[(]([0-9]+)[)]:")

(define (parse-gl-error-log log)
  (for/list ([ln (string-split log "\n")]
             #:when (not (string=? ln "")))
    (define m (regexp-match log-line-pattern ln))
    (if m
        (gl-error (string->number (list-ref m 2)) ln)
        (gl-error #f ln))))

;; ---------- ② 定位（行级） ----------

;; GLSL 行 → 覆盖它的顶层 form。行级，足够。
(define (locate-gl-error src err)
  (define line (gl-error-line err))
  (define form (and line (glsl-program? src) (glsl-program-lookup src line)))
  (located-error line (gl-error-msg err) form))

;; ---------- ③ 三个渲染器 ----------

;; 取第一条满足条件的定位错误
(define (first-located located pred)
  (for/first ([e located] #:when (pred e)) e))

;; 源码 + 行号；mark-line 行用 ">" 标出（不画列 caret）。mark-line=#f 则不标。
(define (render-numbered-lines src mark-line)
  (define ls (string-split src "\n"))
  (define w (string-length (number->string (length ls))))
  (define (pad s) (string-append (make-string (- w (string-length s)) #\space) s))
  (string-join
   (for/list ([i (in-naturals 1)] [l ls])
     (format "~a ~a | ~a"
             (if (equal? i mark-line) ">" " ")
             (pad (number->string i))
             l))
   "\n"))

;; ① OpenGL 行列报错：原始日志
(define (render-gl-linecol log)
  (string-append "OpenGL log:\n" log))

;; ② OpenGL 美化报错：美化 GLSL 源码 + 标出报错行（源为空则输出空）
(define (render-gl-pretty src located)
  (define e (first-located located located-error-line))
  (define body (and e (render-numbered-lines (glsl-src src) (located-error-line e))))
  (if (and body (not (string=? body "")))
      (string-append "OpenGL source:\n" body)
      ""))

;; ③ s表达式 源文件：读 .rkt 源文件，标出该 form 所在行；
;;    读不到文件（如 REPL / 无源路径）才回退到格式化 datum。
(define (render-sexpr-pretty located)
  (define e (first-located located located-error-form))
  (if (not e)
      ""
      (let* ([f (located-error-form e)]
             [path (glsl-form-src-path f)]
             [line (glsl-form-src-line f)]
             [header (if (and path line)
                         (format "s-expr source: ~a:~a\n" path line)
                         "s-expr source:\n")])
        (string-append
         header
         (cond
           [(and path line (read-file-text path))
            => (lambda (text) (render-numbered-lines text line))]
           [else (pretty-sexpr (glsl-form-text f))])))))

;; ---------- 渲染工具 ----------

;; 读源文件全文；失败返回 #f（报错层唯一的 IO，只在报错路径上发生）
(define (read-file-text path)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (file->string path)))

;; s 表达式 → 美化文本（短列表一行；长列表按深度换行缩进）
(define (pretty-sexpr d)
  (let go ([d d] [depth 0])
    (cond
      [(pair? d)
       (define parts (map (lambda (x) (go x (add1 depth))) d))
       (define one (string-append "(" (string-join parts " ") ")"))
       (if (<= (string-length one) 70)
           one
           (string-append "(" (string-join parts (string-append "\n" (make-string (* 2 (add1 depth)) #\space))) ")"))]
      [else (format "~s" d)])))

;; ---------- ④ 组合 ----------

;; 三段拼起来；空段跳过
(define (render-error log src located)
  (string-join
   (filter (lambda (s) (not (string=? s "")))
           (list (render-gl-linecol log)
                 (render-gl-pretty src located)
                 (render-sexpr-pretty located)))
   "\n\n"))
