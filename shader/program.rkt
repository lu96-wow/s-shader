#lang racket/base

;; ============================================================
;; core · shader/program.rkt —— 着色程序的产物：文本 + 行级源映射 + 接口反射
;;
;;   shader-program(src forms)：
;;     src   = 美化后的 GLSL（可直接编译）
;;     forms = 每个顶层 form 的源映射（shader-form）
;;
;; make-shader-program 是运行时入口（宏展开后调用它）：
;;   「代码」（各 form 生成 GLSL 字符串，运行时求值）
;;   +「数据」（各 form 的源位置，宏展开期已剥好、quote 成字面量）
;;   → shader-program
;;
;; ★ 源映射只到「行」：GLSL 第 N 行 → 覆盖它的顶层 form → 该 form 的源文件行。
;;   不做列 / 标识符级定位（shader-error.rkt 只用行）。
;; ============================================================

(require racket/string "pretty.rkt" "interface.rkt")   ; string-join / string-split / shader-pretty

(provide shader-src make-shader-program shader-program-lookup
         shader-program->datum datum->shader-program
         (struct-out shader-program)
         (struct-out shader-form))

;; ---------- 数据 ----------

;; shader-program：src = 美化后的 GLSL；forms = 顶层 form 源映射；interface = 类型化接口反射
(struct shader-program (src forms interface) #:transparent)

;; shader-form：一个顶层 form 的源映射
;;   src-path = .rkt 源文件路径（拿不到则 #f）；src-line = 源文件里的起始行
;;   text = 该 form 的原始 s 表达式；start-line/end-line = 生成 GLSL 落在哪几行（闭区间）
(struct shader-form (src-path src-line text start-line end-line) #:transparent)

;; ---------- 构造 ----------

;; 取出 GLSL 源文本：shader-program → 它的 src；字符串 → 原样
(define (shader-src x)
  (if (shader-program? x) (shader-program-src x) x))

;; 片段美化后的行数：空串 0 行，否则按 \n 计数（shader-pretty 不产生尾随换行）
(define (pretty-line-count s)
  (if (string=? s "") 0 (length (string-split s "\n"))))

;; 把 (parts source-infos interface-datum) 拼成 shader-program：
;;   parts = 各顶层 form 生成的 GLSL（字符串或 shader-program，已求值，顺序对应）
;;   source-infos = 各 form 的 (src-path src-line text)
;;   interface-datum = 接口反射的 datum（宏展开期算好，见 shader-interface.rkt）
;;
;; ★ 行映射：顶层 form 都"平衡、且以 ; } \n 结尾"，在 form 边界处美化状态归零，
;;   所以「整体美化」==「各 form 单独美化后按 \n 拼」（见 pretty.rkt 的 pstate）。
;;   于是每个 form 占几行 = 它自己美化后的行数，行区间用累计行数直接算——
;;   不需要在原始串上打 marks、也不需要偏移量算术。空片段 = 0 行（映射不到任何行）。
(define (make-shader-program parts source-infos interface-datum)
  ;; 片段归一：字符串原样；shader-program 取 src；其它 → 报错
  (define strs
    (for/list ([p (in-list parts)])
      (cond
        [(string? p) p]
        [(shader-program? p) (shader-program-src p)]
        [else (error 'make-shader-program
                     "片段必须是字符串或 shader-program，得到：~s" p)])))
  (define pretty-parts (map shader-pretty strs))
  (define line-counts (map pretty-line-count pretty-parts))
  ;; pretty = 非空片段按 \n 拼（空片段不产生空行）
  (define pretty (string-join (filter (lambda (s) (not (string=? s ""))) pretty-parts) "\n"))
  ;; 每个 form 的 [start-line, end-line]（1 起闭区间）；0 行 → 退化为 start>end（匹配不到）
  (define ranges
    (let-values ([(acc _)
                 (for/fold ([acc '()] [cum 0]) ([c (in-list line-counts)])
                   (values (cons (cons (add1 cum) (+ cum c)) acc) (+ cum c)))])
      (reverse acc)))
  (define forms
    (for/list ([info source-infos] [r (in-list ranges)])
      (shader-form (list-ref info 0) (list-ref info 1) (list-ref info 2) (car r) (cdr r))))
  (shader-program pretty forms (datum->shader-interface interface-datum)))

;; ---------- 查询 ----------

;; 美化 GLSL 第 line 行落在哪个顶层 form；没有则 #f
(define (shader-program-lookup prog line)
  (for/first ([f (shader-program-forms prog)]
              #:when (<= (shader-form-start-line f) line (shader-form-end-line f)))
    f))

;; ---------- datum 往返 ----------
;; 编译期算好 → quote 进代码 → 运行期 datum->shader-program 重建（见 rewrite.rkt）。

(define (shader-form->datum f)
  (list (shader-form-src-path f) (shader-form-src-line f) (shader-form-text f)
        (shader-form-start-line f) (shader-form-end-line f)))

(define (datum->shader-form d)
  (shader-form (list-ref d 0) (list-ref d 1) (list-ref d 2) (list-ref d 3) (list-ref d 4)))

(define (shader-program->datum p)
  (list (shader-program-src p)
        (map shader-form->datum (shader-program-forms p))
        (shader-interface->datum (shader-program-interface p))))

(define (datum->shader-program d)
  (shader-program (list-ref d 0)
                (map datum->shader-form (list-ref d 1))
                (datum->shader-interface (list-ref d 2))))
