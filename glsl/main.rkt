#lang racket/base

;; ============================================================
;; glsl/main.rkt —— #lang shader/glsl 的模块语言（GLSL 方言）
;;
;; 在 core（collection: shader）之上叠加 GLSL 方言：
;;
;;   (require shader)               CPU 值层 + 类型词汇表（方言无关）
;;   glsl/rewrite.rkt               GLSL 语言（(glsl ...) 宏 + 产物 + 接口反射）
;;                                  （rewrite 已重导 core.rkt / pretty / interface / program / names）
;;   glsl/error.rkt                 编译报错的解析 / 定位 / 渲染（纯函数）
;;
;; 本方言不依赖、也不导出任何 OpenGL 绑定（gl-*）或编译/链接胶水。
;; 需要那些请用 #lang shader/glsl-opengl（它 require 本语言再叠加 OpenGL 层）。
;;
;; 值层的 Racket 风格实现（vadd / matrix-ref / …）不在这里导出；
;; 需要时直接 require 对应 value/<逻辑>.rkt。
;;
;; reader 层见 glsl/lang/reader.rkt（#lang s-exp syntax/module-reader shader/glsl/main）。
;; ============================================================

(require shader
         "rewrite.rkt"
         "error.rkt")

(provide (all-from-out shader)
         (all-from-out "rewrite.rkt")
         (all-from-out "error.rkt"))
