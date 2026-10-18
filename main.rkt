#lang racket/base

;; ============================================================
;; shader/main.rkt —— #lang shader 的模块语言（core：方言无关部分）
;;
;; body 仍是普通 Racket 模块；`#lang shader` 只是把下面这些预先 require 好：
;;
;;   Part 2 · value/rename-*.rkt   CPU 值层：GLSL/Slang 共用的构造与运算命名
;;            value/convert.rkt    精度转换（->f32vector …）
;;   地基   · ffi/vector           裸 cvector（f32vector 等）
;;
;; ★ 本层不含任何方言：
;;   - 没有 (glsl ...) / (slang ...) 宏 → 用 #lang shader/glsl 或 #lang shader/slang
;;   - 没有 program/interface/报错层 → step 3 把它们从 glsl/ 提升上来后再补
;;
;; 依赖方向：value/ 与 types.rkt 都不 require glsl/ 或 slang/。
;; ============================================================

(require ffi/vector
         "value/rename-type.rkt"
         "value/rename-access.rkt"
         "value/rename-construct.rkt"
         "value/rename-layout.rkt"
         "value/rename-buffer.rkt"
         "value/rename-vec.rkt"
         "value/rename-matrix.rkt"
         "value/convert.rkt")

(provide (all-from-out racket/base)
         (all-from-out ffi/vector)
         (all-from-out "value/rename-type.rkt")
         (all-from-out "value/rename-access.rkt")
         (all-from-out "value/rename-construct.rkt")
         (all-from-out "value/rename-layout.rkt")
         (all-from-out "value/rename-buffer.rkt")
         (all-from-out "value/rename-vec.rkt")
         (all-from-out "value/rename-matrix.rkt")
         (all-from-out "value/convert.rkt"))
