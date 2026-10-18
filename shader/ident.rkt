#lang racket/base

;; ============================================================
;; core · shader/ident.rkt —— 标识符别名引擎（表由方言传入）
;;
;; 一个着色语言的标识符命名空间有三类来源：
;;   1. 内建名（GLSL 的 gl_Position / textureSize / noperspective；Slang 的 SV_Position / numthreads）
;;   2. 关键字（qualifier / layout key / attribute）
;;   3. 用户标识符（wow-name-type → wow_name_type）
;;
;; 引擎只做「查表 + 兜底」这一件事；**表的内容是方言的事**
;;   （glsl/names.rkt、slang/names.rkt）。
;;
;; 规则（每个命名空间内，优先级从高到低）：
;;   1. 命中该命名空间的别名表 → 用表里的规范拼写
;;   2. 否则 → 通用 '-'→'_'
;;   3. 结果必须是合法标识符，否则报错
;; ============================================================

(require racket/string)

(provide as-string camel->kebab camel-alias-symbols
         make-camel-alias-table hash->sorted-pairs
         user-identifier-name identifier? alias-ref)

;; ---------- 基础 ----------

(define (as-string who x)
  (cond
    [(symbol? x) (symbol->string x)]
    [(string? x) x]
    [else (error who "需要 symbol 或 string，实际 ~s" x)]))

;; 标识符：ASCII 字母/下划线开头，后续字母/数字/下划线
(define (identifier? x)
  (and (regexp-match? #rx"^[A-Za-z_][A-Za-z0-9_]*$" (as-string 'identifier? x)) #t))

;; camelCase / 下划线名 → kebab-case
;;   gl_Position → gl-position
;;   gl_VertexID → gl-vertex-id
;;   dFdx        → d-fdx
;;   findLSB     → find-lsb
(define (camel->kebab str)
  (define n (string-length str))
  (define out (open-output-string))
  (for ([ch (in-string str)] [i (in-naturals)])
    (cond
      [(char=? ch #\_) (write-char #\- out)]
      [(and (char-upper-case? ch)
            (> i 0)
            (let ([prev (string-ref str (sub1 i))])
              (or (char-lower-case? prev)
                  (char-numeric? prev)
                  (and (char-upper-case? prev)
                       (< (add1 i) n)
                       (char-lower-case? (string-ref str (add1 i)))))))
       (write-char #\- out)
       (write-char (char-downcase ch) out)]
      [else (write-char (char-downcase ch) out)]))
  (get-output-string out))

;; ---------- 表 ----------

;; 一个 canonical 名的候选别名（kebab + 全小写下划线；去掉与 canonical 相同的）
(define (camel-alias-symbols name)
  (define s (symbol->string name))
  (define kebab (camel->kebab s))
  (define snake (string-replace kebab "-" "_"))
  (define forms (if (string=? kebab snake) (list kebab) (list kebab snake)))
  (for/list ([f (in-list forms)] #:unless (string=? f s))
    (string->symbol f)))

;; 从「canonical 名清单」生成 alias-symbol → canonical-string 的 hash
(define (make-camel-alias-table who names)
  (for*/fold ([h (hash)]) ([n (in-list names)]
                           [a (in-list (camel-alias-symbols n))])
    (when (hash-has-key? h a)
      (error who "别名冲突：~a → ~a" a n))
    (hash-set h a (symbol->string n))))

(define (hash->sorted-pairs h)
  (sort (for/list ([(k v) (in-hash h)]) (cons k (string->symbol v)))
        (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))))

;; ---------- 转换 ----------

;; 通用用户标识符：只做 '-'→'_'，再校验
(define (user-identifier-name who x)
  (define s (as-string who x))
  (define mapped (string-replace s "-" "_"))
  (unless (identifier? mapped)
    (error who "非法标识符：~a → ~a（只允许字母/数字/下划线；连字符会转成 _）"
           s mapped))
  mapped)

;; 查别名表；不命中返回 #f
(define (alias-ref table who x)
  (hash-ref table (string->symbol (as-string who x)) #f))
