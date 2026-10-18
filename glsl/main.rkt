#lang racket/base

;; ============================================================
;; glsl/main.rkt —— #lang glsl 的模块语言（GLSL 方言）
;;
;; 在 core（collection: shader）之上叠加 GLSL 方言：
;;
;;   (require shader)               core：值层 + 类型/接口/产物/报错
;;   glsl/types.rkt                 类型目录：拼写 → shader-type
;;   glsl/names.rkt                 标识符别名表：gl-position → gl_Position …
;;   glsl/rewrite.rkt               GLSL 语言（(glsl ...) 宏 + fragment/splice）
;;   glsl/log.rkt                   驱动日志 → shader-error
;;
;; 本方言不依赖、也不导出任何 OpenGL 绑定（gl-*）或编译/链接胶水。
;; 需要那些请用 #lang glsl-opengl（它 require 本语言再叠加 OpenGL 层）。
;;
;; 值层的 Racket 风格实现（vadd / matrix-ref / …）不在这里导出；
;; 需要时直接 require 对应 value/<逻辑>.rkt。
;;
;; reader 层见 glsl/lang/reader.rkt（#lang s-exp syntax/module-reader glsl/main）。
;; ============================================================

(require shader
         "types.rkt"
         "names.rkt"
         "rewrite.rkt"
         "log.rkt")

(provide (all-from-out shader)
         (all-from-out "types.rkt")
         (all-from-out "names.rkt")
         (all-from-out "rewrite.rkt")
         (all-from-out "log.rkt"))
