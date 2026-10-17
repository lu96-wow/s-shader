#lang racket/base

;; ============================================================
;; 值层 · value/rename-layout.rkt —— GLSL 风格命名（交错布局）
;;
;; 纯 alias + 宏外观：value/layout.rkt 的 Racket 名 → GLSL 名。零逻辑。
;;   glsl-struct：把 shader 里的 struct 镜像到 CPU 侧。
;; ============================================================

(require "layout.rkt"
         (for-syntax racket/base racket/syntax "type.rkt" "../vocab/type-names.rkt"))

(provide glsl-struct)

(define-syntax (glsl-struct stx)
  (syntax-case stx ()
    [(_ Name (type field) ...)
     (let* ([types     (syntax->list #'(type ...))]
            [fields    (syntax->list #'(field ...))]
            ;; 类型别名（vec-3 / mat_4 …）在编译期规范成 canonical，
            ;; 这样 <Name>-fields 与 shader 接口里的 canonical 类型名可直接比较。
            [type-syms (map glsl-type-canonical-symbol (map syntax->datum types))])
       (when (null? fields)
         (error 'glsl-struct "至少需要一个字段"))
       (define kinds (map type-kind type-syms))
       (when (and (memq 'f32 kinds) (memq 'f64 kinds))
         (error 'glsl-struct "字段不能混用 float/double 精度：~s" type-syms))
       (define all-same? (andmap (lambda (k) (eq? k (car kinds))) kinds))
       (define pack-fmt
         (if all-same?
             (case (car kinds)
               [(f32) "~a->f32vector"]
               [(f64) "~a->f64vector"]
               [(s32) "~a->s32vector"]
               [(u32) "~a->u32vector"])
             "~a->bytes"))
       ;; 混合类别时 pack 结果其实是 u8vector：补一个新名别名，旧名 Name->bytes 保留。
       (define pack-alias
         (if all-same?
             #'(begin)
             #`(define #,(format-id #'Name "~a->u8vector" #'Name)
                 #,(format-id #'Name pack-fmt #'Name))))
       (with-syntax
         ([types-list   (datum->syntax #'Name type-syms)]
          [fields-id    (format-id #'Name "~a-fields" #'Name)]
          [fields-stx   (datum->syntax #'Name (map (lambda (t f) (list (syntax->datum f) t)) type-syms fields))]
          [to-vec       (format-id #'Name pack-fmt #'Name)]
          [pack-alias-def pack-alias]
          [stride-fn    (format-id #'Name "~a-stride" #'Name)]
          [stride-bytes-fn (format-id #'Name "~a-stride-bytes" #'Name)]
          [field-offset (format-id #'Name "~a-field-offset" #'Name)]
          [field-size   (format-id #'Name "~a-field-size" #'Name)]
          [field-components (format-id #'Name "~a-field-components" #'Name)]
          [(field-acc ...)
           (map (lambda (f) (format-id #'Name "~a-~a" #'Name f)) fields)]
          [(field-clause ...)
           (for/list ([f fields] [i (in-naturals)])
             #`[(#,f) #,i])])
         #'(begin
             (struct Name (field ...) #:transparent)
             ;; 编译期字段表：((field type) ...)，供宏消费（表驱动代码生成）
             (define-syntax fields-id
               (lambda (use-stx) (syntax (quote fields-stx))))
             (define (to-vec rec)
               (pack-record 'types-list (field-acc rec) ...))
             pack-alias-def
             ;; stride 新名带单位（字节）；旧名保留
             (define (stride-bytes-fn)
               (record-stride-bytes 'types-list))
             (define (stride-fn) (stride-bytes-fn))
             (define (field-offset f)
               (list-ref (record-field-offsets 'types-list)
                         (case f
                           field-clause ...
                           [else (error 'field-offset "未知字段：~s" f)])))
             ;; field 大小新名说清是“分量数”；旧名保留
             (define (field-components f)
               (record-field-size 'types-list
                                  (case f
                                    field-clause ...
                                    [else (error 'field-size "未知字段：~s" f)])))
             (define (field-size f) (field-components f)))))]))
