#lang racket/base

;; ============================================================
;; slang/main.rkt —— #lang slang 的模块语言（Slang 方言）
;;
;; 在 core（collection: shader）之上叠加 Slang 方言：
;;
;;   (require shader)               core：值层 + 类型/接口/产物/报错
;;   slang/types.rkt                类型目录：float3 / float4x4 → canonical vec3 / mat4
;;   slang/names.rkt                语义 / 修饰符 / 属性表（SV-Position → SV_Position …）
;;   slang/core.rkt                 Slang 字符串原语（[[vk::…]] / cbuffer / 语义注解）
;;   slang/rewrite.rkt              Slang 语言（(slang ...) 宏）
;;   slang/log.rkt                  编译器日志 → shader-error
;;
;; 声明侧 + 函数体/表达式/语句/入口属性都已可用；见 slang/README.md。
;; ============================================================

(require shader
         "types.rkt"
         "names.rkt"
         "core.rkt"
         "rewrite.rkt"
         "log.rkt")

(provide (all-from-out shader)
         (all-from-out "types.rkt")
         (all-from-out "names.rkt")
         (all-from-out "core.rkt")
         (all-from-out "rewrite.rkt")
         (all-from-out "log.rkt"))
