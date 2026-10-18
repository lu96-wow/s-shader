#lang racket/base

;; ============================================================
;; core · shader/interface.rkt —— 接口反射 + datum 往返（两个方言共用）
;;
;; 一段 shader 源码声明了哪些变量 / 块成员、各是什么类型、什么限定符 ——
;; 只做「读」，不做组合（不合并多个 shader、不生成 setter、不碰 GL/Vulkan）。
;;
;; 提供两类东西：
;;   ① 查询：按名字 / 限定符 / 类型 kind / layout 键取子集
;;   ② datum 往返：宏展开期算好 → quote 进代码 → 运行期重建（见 program.rkt）
;;
;; datum 形状（定稿；改它等于改所有已生成代码的兼容性）：
;;   type-datum = (kind name base dims len elem-datum (arg-datum ...) size (var-datum ...))
;;   var-datum  = (name source-name type-datum qualifiers layout annotations owner)
;;   interface-datum = (listof var-datum)
;; ============================================================

(require racket/list racket/match
         "types.rkt"
         "type.rkt")

(provide
 ;; ---- 接口 ----
 shader-interface? shader-interface shader-interface-vars
 shader-interface-ref
 shader-interface-vars-with-qualifier
 shader-interface-vars-with-kind
 shader-interface-vars-with-layout
 ;; ---- datum 往返（宏展开期 ↔ 运行期）----
 shader-type->datum datum->shader-type
 shader-var->datum datum->shader-var
 shader-interface->datum datum->shader-interface
 ;; ---- 类型名词汇表（canonical 名 + 别名，与 CPU 值层共享）----
 (all-from-out "types.rkt"))

;; 一段 shader 源码声明的全部接口变量（按源码出现顺序）
(struct shader-interface (vars) #:transparent)

;; ============================================================
;; 查询（只读；名字 lookup 是线性扫描：接口通常几十条，够用、也不额外存索引）
;; ============================================================

;; 名字 → 声明；找不到 #f。名字可以写符号 'uColor 或字符串 "uColor"。
;; 同时接受表面名（u-color）与源码名（u_color）。
(define (shader-interface-ref ifc name)
  (define sym (if (string? name) (string->symbol name) name))
  (for/first ([v (in-list (shader-interface-vars ifc))]
              #:when (or (eq? (shader-var-name v) sym)
                         (eq? (shader-var-source-name v) sym)))
    v))

;; 带某个限定符的全部声明
(define (shader-interface-vars-with-qualifier ifc q)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (shader-var-has-qualifier? v q))
    v))

;; 类型 kind 匹配的全部声明（kind 取 shader-type-kind 的取值：'scalar 'vector … 'block）
(define (shader-interface-vars-with-kind ifc kind)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (eq? (shader-type-kind (shader-var-type v)) kind))
    v))

;; 带某个 layout 键的全部声明
(define (shader-interface-vars-with-layout ifc key)
  (for/list ([v (in-list (shader-interface-vars ifc))]
             #:when (shader-var-layout-ref v key))
    v))

;; ============================================================
;; datum 往返：宏展开期算好 → quote 进代码 → 运行期重建
;; ============================================================

(define (shader-type->datum t)
  (list (shader-type-kind t) (shader-type-name t) (shader-type-base t) (shader-type-dims t)
        (shader-type-len t)
        (and (shader-type-elem t) (shader-type->datum (shader-type-elem t)))
        (map shader-type->datum (shader-type-args t))
        (shader-type-size t)
        (map shader-var->datum (shader-type-fields t))))

(define (datum->shader-type d)
  (match d
    [(list kind name base dims len elem args size fields)
     (shader-type kind name base dims len
                  (and elem (datum->shader-type elem))
                  (map datum->shader-type args) size
                  (map datum->shader-var fields))]))

(define (shader-var->datum v)
  (list (shader-var-name v) (shader-var-source-name v)
        (shader-type->datum (shader-var-type v))
        (shader-var-qualifiers v) (shader-var-layout v)
        (shader-var-annotations v) (shader-var-owner v)))

(define (datum->shader-var d)
  (match d
    [(list name source-name type qualifiers layout annotations owner)
     (shader-var name source-name (datum->shader-type type)
                 qualifiers layout annotations owner)]))

(define (shader-interface->datum i)
  (map shader-var->datum (shader-interface-vars i)))

(define (datum->shader-interface d)
  (shader-interface (map datum->shader-var d)))
