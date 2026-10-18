#lang racket/base

;; ============================================================
;; control-flow-test.rkt —— (glsl ...) 控制流嵌套测试（非 GL）
;;
;; 运行：racket test/control-flow-test.rkt
;; 用「重写输出 == 原始 GLSL 的美化」来断言，跟 rewrite-test.rkt 同一套路。
;; 覆盖：when/unless/cond/for/while/do-while/switch 的多层嵌套，break/continue/return/discard，
;;       嵌套三元，以及两个已知修复点：
;;         ① 函数体以裸原子（符号/数字）结尾时的自动 return
;;         ② `}` 后接 return/break/... 语句时不被误并到同行
;; ============================================================

(require rackunit
         "../glsl/rewrite.rkt")

(define-syntax-rule (check-glsl raw (form ...))
  (check-equal? (glsl-program-src (glsl form ...))
                (glsl-pretty raw)))

;; ---------- 基本嵌套 ----------

;; when 套 when
(check-glsl "void main() { if (a) { if (b) { c = 1; } } }"
            ((define (main) void
               (when a (when b (set! c 1))))))

;; unless 套 for
(check-glsl "void main() { if ((!done)) { for (int i = 0; (i < 2); ++i) { c = i; } } }"
            ((define (main) void
               (unless done
                 (for (int i 0) (< i 2) (++ i) (set! c i))))))

;; cond → if / else if / else
(check-glsl "void main() { if ((a == 1)) { c = 1; } else if ((a == 2)) { c = 2; } else { c = 3; } }"
            ((define (main) void
               (cond [(= a 1) (set! c 1)]
                     [(= a 2) (set! c 2)]
                     [else    (set! c 3)]))))

;; for 套 for
(check-glsl "void main() { for (int i = 0; (i < 4); ++i) { for (int j = 0; (j < 4); ++j) { s = (s + (i * j)); } } }"
            ((define (main) void
               (for (int i 0) (< i 4) (++ i)
                 (for (int j 0) (< j 4) (++ j)
                   (set! s (+ s (* i j))))))))

;; while 套 do-while
(check-glsl "void main() { while ((k < p)) { do { ++q; } while ((q < r)); ++k; } }"
            ((define (main) void
               (while (< k p)
                 (do-while (< q r) (++ q))
                 (++ k)))))

;; do-while 套 while
(check-glsl "void main() { do { while ((j < m)) { ++j; } ++i; } while ((i < n)); }"
            ((define (main) void
               (do-while (< i n)
                 (while (< j m) (++ j))
                 (++ i)))))

;; switch 套 switch（无 default 也算覆盖）
(check-glsl "void main() { switch (a) { case 0: { switch (b) { case 1: { c = 1; } } } default: { c = 0; } } }"
            ((define (main) void
               (switch a
                 [case 0 (switch b [case 1 (set! c 1)])]
                 [default (set! c 0)]))))

;; 四层：for > while > cond > when，且 cond 含 break
(check-glsl
 "void main() { for (int i = 0; (i < n); ++i) { while ((j < m)) { if ((a > b)) { if (c) { d = 1.0; } } else { break; } ++j; } } }"
 ((define (main) void
    (for (int i 0) (< i n) (++ i)
      (while (< j m)
        (cond [(> a b) (when c (set! d 1.0))]
              [else (break)])
        (++ j))))))

;; 子句体以 do-while 结尾 + else（验证 `} else` 收尾）
(check-glsl "void main() { if ((a == 1)) { do { ++i; } while ((i < n)); } else { c = 0; } }"
            ((define (main) void
               (cond [(= a 1) (do-while (< i n) (++ i))]
                     [else (set! c 0)]))))

;; ---------- 嵌套三元表达式 ----------

(check-glsl "float f(float a, float b) { return ((a > 0.0) ? ((b > 0.0) ? 1.0 : 2.0) : 3.0); }"
            ((define (f (float a) (float b)) float
               (if (> a 0.0) (if (> b 0.0) 1.0 2.0) 3.0))))

;; 三元作 when 条件
(check-glsl "void main() { if ((a ? (b > 0.0) : (c < 0.0))) { d = ((e > 0.0) ? 1.0 : 2.0); } }"
            ((define (main) void
               (when (if a (> b 0.0) (< c 0.0))
                 (set! d (if (> e 0.0) 1.0 2.0))))))

;; ---------- break / continue / return / discard ----------

(check-glsl "void main() { for (int i = 0; (i < n); ++i) { if (a) { continue; } if (b) { break; } } }"
            ((define (main) void
               (for (int i 0) (< i n) (++ i)
                 (when a (continue))
                 (when b (break))))))

(check-glsl "void main() { if ((x > 1.0)) { discard; } }"
            ((define (main) void
               (when (> x 1.0) (discard)))))

;; 三段 when 嵌套 + continue，再一层 break
(check-glsl "void main() { for (int i = 0; (i < n); ++i) { if (a) { if (b) { if (c) { continue; } } } if (d) { break; } } }"
            ((define (main) void
               (for (int i 0) (< i n) (++ i)
                 (when a (when b (when c (continue))))
                 (when d (break))))))

;; ---------- 修复点 ①：裸原子结尾自动 return ----------

(check-glsl "float f(float x) { return x; }"
            ((define (f (float x)) float x)))

(check-glsl "float f() { return 1.0; }"
            ((define (f) float 1.0)))

(check-glsl "float f(float x) { if ((x < 0.0)) { return 0.0; } return x; }"
            ((define (f (float x)) float
               (when (< x 0.0) (return 0.0))
               x)))

;; ---------- 修复点 ②：`}` 后接语句不被误并 ----------

(check-glsl "float f(float x) { for (int i = 0; (i < 4); ++i) { break; } return x; }"
            ((define (f (float x)) float
               (for (int i 0) (< i 4) (++ i) (break))
               (return x))))

;; 对照：接口块实例名仍应与 `}` 同行
(check-glsl "uniform Camera { mat4 view; mat4 proj; } cam;"
            ((uniform (block Camera (mat4 view) (mat4 proj)) cam)))

;; ---------- (cond [else ...]) 不再多包裸块 ----------

;; 单语句：直接就是那条语句
(check-glsl "void main() { c = 1; }"
            ((define (main) void
               (cond [else (set! c 1)]))))

;; 多语句：一 form 只能产出一个 part，仍用块包
(check-glsl "void main() { { a = 1; b = 2; } }"
            ((define (main) void
               (cond [else (set! a 1) (set! b 2)]))))

;; 对照：else 作 if 的 else 分支不受影响（仍包成块）
(check-glsl "void main() { if ((a == 1)) { c = 1; } else { c = 2; } }"
            ((define (main) void
               (cond [(= a 1) (set! c 1)] [else (set! c 2)]))))


(displayln "control-flow 全部测试通过")
