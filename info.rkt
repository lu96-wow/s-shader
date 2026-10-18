#lang info
;; ============================================================
;; racket-shader —— 着色语言 DSL（多集合包）
;;
;; 三个集合：
;;   shader   core：CPU 值层 + 类型/声明模型 + 接口反射 + 产物/美化/报错（方言无关）
;;   glsl     #lang glsl     + (glsl ...)  宏
;;   slang    #lang slang    + (slang ...) 宏
;;
;; 依赖方向：glsl / slang 只 require shader；两者互不 require。
;; ============================================================

(define collection 'multi)

(define deps '("base"))
(define build-deps '("rackunit-lib"))   ; test 用

;; test / experiments 不参与包编译（experiments 会 require 外部包 vulkan + slangc）
(define compile-omit-paths '("test" "experiments"))

(define pkg-desc "Shader DSLs for Racket: #lang glsl, #lang slang (+ core library 'shader')")
(define pkg-authors '("lu96"))
(define license '("MIT"))
