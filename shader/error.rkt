#lang racket/base

;; ============================================================
;; core · shader/error.rkt —— 编译报错的定位与渲染（两个方言共用）
;;
;; ★ 只保证「行」正确，不做列 / 标识符级精确定位：
;;     源码第 N 行 → 覆盖该行的顶层 form → 该 form 的源文件行。
;;   源行用 ">" 前缀标出（不画列级 caret）。
;;
;; 报错拆成三个独立的"视角"，每个只做一件事：
;;   ① 编译器原始日志
;;   ② 美化后的源码 + 标出报错行
;;   ③ s 表达式源文件 + 标出对应源行
;;
;; 全部是 数据 → lambda → 数据 的纯函数（读源文件是报错路径上唯一的 IO）。
;; 日志 → shader-error 的**解析**是方言知识（位置格式不同），在 glsl/log.rkt 等。
;; ============================================================

(require racket/string racket/file "program.rkt")

(provide locate-error render-error
         render-log render-source render-sexpr
         (struct-out shader-error) (struct-out located-error))

;; ---------- 数据 ----------

;; 一条编译器错误：只要行（列不用）
(struct shader-error (line msg) #:transparent)

;; 一条定位后的错误：line/msg = 源码行与原始消息；form = 覆盖该行的顶层 form（#f = 无）
(struct located-error (line msg form) #:transparent)

;; ---------- 定位（行级） ----------

;; 源码行 → 覆盖它的顶层 form。行级，足够。
(define (locate-error src err)
  (define line (shader-error-line err))
  (define form (and line (shader-program? src) (shader-program-lookup src line)))
  (located-error line (shader-error-msg err) form))

;; ---------- 三个渲染器 ----------

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

;; ① 编译器原始日志
(define (render-log log)
  (string-append "compiler log:\n" log))

;; ② 美化后的源码 + 标出报错行（源码为空则输出空）
(define (render-source src located)
  (define e (first-located located located-error-line))
  (define body (and e (render-numbered-lines (shader-src src) (located-error-line e))))
  (if (and body (not (string=? body "")))
      (string-append "shader source:\n" body)
      ""))

;; ③ s 表达式源文件：读 .rkt 源文件，标出该 form 所在行；
;;    读不到文件（如 REPL / 无源路径）才回退到格式化 datum。
(define (render-sexpr located)
  (define e (first-located located located-error-form))
  (if (not e)
      ""
      (let* ([f (located-error-form e)]
             [path (shader-form-src-path f)]
             [line (shader-form-src-line f)]
             [header (if (and path line)
                         (format "s-expr source: ~a:~a\n" path line)
                         "s-expr source:\n")])
        (string-append
         header
         (cond
           [(and path line (read-file-text path))
            => (lambda (text) (render-numbered-lines text line))]
           [else (pretty-sexpr (shader-form-text f))])))))

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

;; ---------- 组合 ----------

;; 三段拼起来；空段跳过
(define (render-error log src located)
  (string-join
   (filter (lambda (s) (not (string=? s "")))
           (list (render-log log)
                 (render-source src located)
                 (render-sexpr located)))
   "\n\n"))
