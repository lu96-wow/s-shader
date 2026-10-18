#lang racket/base

;; ============================================================
;; Slang 方言 · slang/core.rkt —— Slang 字符串原语
;;
;; 与 GLSL 原语（glsl/core.rkt）的分工：拼装小工具（->str / wrap-block /
;; quals->prefix / join-spaces）来自 core 的 shader/emit-util.rkt；
;; 本模块只加 Slang 特有的形状：
;;
;;   [[vk::binding(0, 0)]]        属性（attribute）
;;   float4 pos : SV_Position;    语义注解（后缀）
;;   nointerpolation float3 n;    修饰符注解（前缀）
;;   cbuffer Camera { … };        常量缓冲块
;;   [[vk::constant_id(0)]] const int TILE = 8;
;;   Texture2D<float4> / StructuredBuffer<T>   参数化类型
;;
;; ★ 全部返回字符串、不含换行（换行/缩进交给 shader/pretty.rkt）。
;; ============================================================

(require racket/format racket/string
         shader/emit-util)

(provide slang-attr
         slang-decl slang-field-decl slang-struct-decl
         slang-cbuffer slang-const-id
         slang-resource slang-param-block)

;; ---------- 属性 ----------

;; 属性实参：符号/字符串加引号（shader("vertex")、image_format("rgba8")），数字原样
(define (attr-arg->str x)
  (cond [(string? x) (format "\"~a\"" x)]
        [(symbol? x) (format "\"~a\"" x)]
        [else (->str x)]))

;; (list "vk::binding" 0 0) → "[[vk::binding(0, 0)]] "；空列表 → ""
;; 无参数的属性写成 "[[unroll]]"
(define (slang-attr attrs)
  (if (null? attrs)
      ""
      (string-append
       (string-join
        (for/list ([a (in-list attrs)])
          (define name (->str (car a)))
          (define args (cdr a))
          (if (null? args)
              (format "[[~a]]" name)
              (format "[[~a(~a)]]" name
                      (string-join (map attr-arg->str args) ", "))))
        " ")
       " ")))

;; ---------- 声明 ----------

;; (slang-decl attrs quals type name [init])
;;   attrs = 属性列表；quals = 字符串列表（static / const / groupshared …）
(define (slang-decl attrs quals type name [init #f])
  (format "~a~a~a ~a~a;"
          (slang-attr attrs)
          (quals->prefix quals)
          (->str type) (->str name)
          (if init (format " = ~a" (->str init)) "")))

;; 字段：修饰符前缀 + 类型 + 名字 + 语义后缀
;;   (slang-field-decl '("nointerpolation") "float3" "n" "NORMAL")
;;   → "nointerpolation float3 n : NORMAL;"
(define (slang-field-decl modifiers type name [semantic #f])
  (format "~a~a ~a~a;"
          (quals->prefix modifiers)
          (->str type) (->str name)
          (if semantic (format " : ~a" (->str semantic)) "")))

;; struct：fields 已是 field-decl 字符串
(define (slang-struct-decl name . fields)
  (format "struct ~a { ~a };" (->str name) (join-spaces fields)))

;; ---------- Vulkan 资源 ----------

;; [[vk::binding(binding, set)]] cbuffer Name { … };
(define (slang-cbuffer attrs name . fields)
  (format "~acbuffer ~a { ~a };"
          (slang-attr attrs) (->str name) (join-spaces fields)))

;; [[vk::binding(binding, set)]] 类型 名字;        （任意资源：Buffer / Texture / Sampler）
(define (slang-resource attrs type name)
  (format "~a~a ~a;" (slang-attr attrs) (->str type) (->str name)))

;; struct Name { … }; [[vk::binding(binding, set)]] ParameterBlock<Name> inst;
(define (slang-param-block attrs name inst . fields)
  (format "struct ~a { ~a }; ~aParameterBlock<~a> ~a;"
          (->str name) (join-spaces fields)
          (slang-attr attrs) (->str name) (->str inst)))

;; [[vk::constant_id(id)]] const type NAME = value;
(define (slang-const-id id type name value)
  (format "[[vk::constant_id(~a)]] const ~a ~a = ~a;"
          (->str id) (->str type) (->str name) (->str value)))
