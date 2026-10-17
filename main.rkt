#lang racket/base

;; ============================================================
;; glsl/main.rkt —— #lang glsl 的模块语言（纯 GLSL，无 OpenGL）
;;
;; body 仍然是普通 Racket 模块；「#lang glsl」只是把下面这些预先 require 好：
;;
;;   Part 1 · core/glsl/rewrite.rkt       GLSL 语言（(glsl ...) 宏 + 产物 + 接口反射）
;;            core/glsl/names.rkt         标识符便携层（变量/函数/关键字别名）
;;            core/vocab/type-names.rkt   共享类型词汇表（canonical 类型名 + 类型别名）
;;   Part 2 · core/value/rename-*.rkt     Racket-ffi 重实现的 GLSL 风格命名
;;            core/value/convert.rkt      精度转换（Racket 风格：->f32vector …）
;;   报错   · core/tool/error.rkt         编译报错的解析 / 定位 / 渲染（纯函数）
;;   地基   · ffi/vector                   裸 cvector（f32vector 等）
;;
;; 本包不依赖、也不导出任何 OpenGL 绑定（gl-*）或编译/链接胶水。
;; 需要那些请用 #lang glsl-opengl（它 require 本包再叠加 OpenGL 层）。
;;
;; 值层的 Racket 风格实现（vec-add / matrix-ref / …）不在这里导出；
;; 需要时直接 require 对应 core/value/<逻辑>.rkt。
;;
;; reader 层见 lang/reader.rkt（#lang s-exp syntax/module-reader glsl/main）。
;; ============================================================

(require ffi/vector
         ;; Part 1：(glsl) 内 —— 语言（rewrite 已重导 core/pretty/interface/program）
         "core/glsl/rewrite.rkt"
         ;; Part 2：(glsl) 外 —— Racket-ffi 重实现的 GLSL 风格命名
         "core/value/rename-type.rkt"
         "core/value/rename-access.rkt"
         "core/value/rename-construct.rkt"
         "core/value/rename-layout.rkt"
         "core/value/rename-buffer.rkt"
         "core/value/rename-vec.rkt"
         "core/value/rename-matrix.rkt"
         "core/value/convert.rkt"
         ;; 报错层（纯函数，不碰 opengl）
         "core/tool/error.rkt")

(provide (all-from-out racket/base)
         (all-from-out ffi/vector)
         (all-from-out "core/glsl/rewrite.rkt")
         (all-from-out "core/value/rename-type.rkt")
         (all-from-out "core/value/rename-access.rkt")
         (all-from-out "core/value/rename-construct.rkt")
         (all-from-out "core/value/rename-layout.rkt")
         (all-from-out "core/value/rename-buffer.rkt")
         (all-from-out "core/value/rename-vec.rkt")
         (all-from-out "core/value/rename-matrix.rkt")
         (all-from-out "core/value/convert.rkt")
         (all-from-out "core/tool/error.rkt"))
