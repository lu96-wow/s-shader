#lang racket/base

;; ============================================================
;; shader/main.rkt —— #lang shader 的模块语言（core：方言无关部分）
;;
;; body 仍是普通 Racket 模块；`#lang shader` 只是把下面这些预先 require 好：
;;
;;   值层   · value/rename-*.rkt   CPU 侧构造与运算（vec3 / mat4-* / shader-struct …）
;;            value/convert.rkt    精度转换（->f32vector …）
;;   类型   · types.rkt           类型名词汇表（canonical 名 + 别名）
;;            shader/type.rkt      类型/声明数据模型（shader-type / shader-var）
;;            shader/interface.rkt 接口反射 + datum 往返
;;   产物   · shader/program.rkt  带源映射的 shader 程序
;;            shader/pretty.rkt    美化
;;            shader/error.rkt     报错定位/渲染（解析在方言层）
;;   地基   · ffi/vector           裸 cvector（f32vector 等）
;;
;; ★ 本层不含任何方言：
;;   - 没有 (glsl ...) / (slang ...) 宏 → 用 #lang shader/glsl 或 #lang shader/slang
;;   - 没有「名字 → 类型」的目录、没有标识符别名表 → 那些在方言层
;; ============================================================

(require ffi/vector
         "types.rkt"
         "shader/type.rkt"
         "shader/interface.rkt"
         "shader/program.rkt"
         "shader/pretty.rkt"
         "shader/error.rkt"
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
         (all-from-out "shader/type.rkt")
         (all-from-out "shader/interface.rkt")
         (all-from-out "shader/program.rkt")
         (all-from-out "shader/pretty.rkt")
         (all-from-out "shader/error.rkt")
         (all-from-out "value/rename-type.rkt")
         (all-from-out "value/rename-access.rkt")
         (all-from-out "value/rename-construct.rkt")
         (all-from-out "value/rename-layout.rkt")
         (all-from-out "value/rename-buffer.rkt")
         (all-from-out "value/rename-vec.rkt")
         (all-from-out "value/rename-matrix.rkt")
         (all-from-out "value/convert.rkt"))
