#lang racket/base

;; ============================================================
;; shader/main.rkt —— core 库入口（collection: shader）
;;
;; 方言无关的一切，一次 require 全拿到：
;;
;;   值层   · value/rename-*.rkt   CPU 侧构造与运算（vec3 / mat4-* / shader-struct …）
;;            value/convert.rkt    精度转换（->f32vector …）
;;   类型   · types.rkt           类型名词汇表（canonical 名 + 别名）
;;            type.rkt             类型 / 声明模型（shader-type / shader-var）
;;            interface.rkt        接口反射 + datum 往返
;;   产物   · program.rkt         带源映射的 shader 程序
;;            pretty.rkt           文本美化
;;            error.rkt            报错定位 / 渲染（日志解析在方言层）
;;   地基   · ffi/vector          裸 cvector（f32vector 等）
;;
;; ★ 本集合不含任何方言知识：
;;   - 没有 (glsl ...) / (slang ...) 宏 → 用 #lang glsl / #lang slang
;;   - 没有「名字 → 类型」的目录、没有标识符别名表 → 那些在方言集合里
;; ============================================================

(require ffi/vector
         "types.rkt"
         "type.rkt"
         "interface.rkt"
         "program.rkt"
         "pretty.rkt"
         "error.rkt"
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
         (all-from-out "types.rkt")
         (all-from-out "type.rkt")
         (all-from-out "interface.rkt")
         (all-from-out "program.rkt")
         (all-from-out "pretty.rkt")
         (all-from-out "error.rkt")
         (all-from-out "value/rename-type.rkt")
         (all-from-out "value/rename-access.rkt")
         (all-from-out "value/rename-construct.rkt")
         (all-from-out "value/rename-layout.rkt")
         (all-from-out "value/rename-buffer.rkt")
         (all-from-out "value/rename-vec.rkt")
         (all-from-out "value/rename-matrix.rkt")
         (all-from-out "value/convert.rkt"))
