#lang racket/base
;; ============================================================
;; shader-interface 测试：GLSL 类型模型 + 一个 shader 的接口反射
;; 运行：racket test/shader-interface-test.rkt
;; ============================================================
(require rackunit racket/list
         "../glsl/interface.rkt"
         "../glsl/rewrite.rkt")

;; ---------- ① 类型模型：内建类型 ----------
(define (bt s) (builtin-type-of s))

(check-true (shader-type? (bt 'vec4)))
(check-equal? (shader-type-kind (bt 'vec4)) 'vector)
(check-equal? (shader-type-name (bt 'vec4)) 'vec4)
(check-equal? (shader-type-base (bt 'vec4)) 'float)
(check-equal? (shader-type-dims (bt 'vec4)) '(4))
(check-equal? (shader-type-size (bt 'vec4)) 16)

(check-equal? (shader-type-kind (bt 'float)) 'scalar)
(check-equal? (shader-type-size (bt 'float)) 4)
(check-equal? (shader-type-size (bt 'double)) 8)
(check-equal? (shader-type-size (bt 'dvec3)) 24)
(check-equal? (shader-type-base (bt 'ivec2)) 'int)
(check-equal? (shader-type-base (bt 'bvec2)) 'bool)

(check-equal? (shader-type-kind (bt 'mat3)) 'matrix)
(check-equal? (shader-type-dims (bt 'mat3)) '(3 3))
(check-equal? (shader-type-size (bt 'mat3)) 36)
(check-equal? (shader-type-dims (bt 'mat3x2)) '(3 2))     ; (列 行)
(check-equal? (shader-type-size (bt 'dmat4)) 128)
(check-equal? (shader-type-base (bt 'dmat4)) 'double)

(check-equal? (shader-type-kind (bt 'sampler2D)) 'sampler)
(check-equal? (shader-type-size (bt 'sampler2D)) #f)      ; 不透明，无字节数
(check-equal? (shader-type-base (bt 'isampler2D)) 'int)
(check-equal? (shader-type-kind (bt 'image2D)) 'image)
(check-equal? (shader-type-kind (bt 'void)) 'void)

(check-false (bt 'NotAType))                            ; 非内建类型
(check-true (builtin-type? 'vec4))
(check-false (builtin-type? 'Light))

;; 类型别名 → canonical shader-type
(check-equal? (shader-type-name (bt 'vec-3)) 'vec3)
(check-equal? (shader-type-kind (bt 'vec_3)) 'vector)
(check-equal? (shader-type-name (bt 'sampler-2d)) 'sampler2D)
(check-equal? (shader-type-name (bt 'isampler-2d-array)) 'isampler2DArray)
(check-equal? (shader-type-name (bt 'mat-3x2)) 'mat3x2)
(check-equal? (shader-type-name (bt 'atomic-uint)) 'atomic_uint)

;; ---------- ② 手工构造数组 / 结构 / 块（尺寸一并算好）----------
(define arr (shader-array-type (bt 'vec3) 4))
(check-equal? (shader-type-kind arr) 'array)
(check-equal? (shader-type-len arr) 4)
(check-equal? (shader-type-size arr) 48)                  ; 4 × 12

(define st (shader-struct-type 'Light (list (shader-var 'pos (bt 'vec3) '() '() '() #f)
                                             (shader-var 'i (bt 'float) '() '() '() #f))))
(check-equal? (shader-type-kind st) 'struct)
(check-equal? (shader-type-size st) 16)                   ; 12 + 4
(check-equal? (map shader-var-name (shader-type-fields st)) '(pos i))

;; ---------- ③ 接口反射：从 shader 声明里读出 ----------
(define shader
  (glsl (version 330 core)
        (struct Light (vec3 pos) (float i))
        (layout (location 0) in vec2 aPos)
        (layout (location 1) in vec3 aNormal)
        (uniform mat4 uMVP)
        (uniform float uTime)
        (uniform Light uLight)
        (uniform (array sampler2D 4) uMaps)
        (layout (std140) (binding 0) uniform (block Camera (mat4 view) (mat4 proj)) cam)
        (out vec2 vUV)
        (define (main) void (set! vUV aPos))))

(define ifc (shader-program-interface shader))
(define (var name) (for/first ([v (in-list (shader-interface-vars ifc))]
                               #:when (eq? (shader-var-name v) name)) v))

;; uniform mat4 uMVP
(check-equal? (shader-type-name (shader-var-type (var 'uMVP))) 'mat4)
(check-equal? (shader-var-qualifiers (var 'uMVP)) '(uniform))
(check-equal? (shader-var-layout (var 'uMVP)) '())

;; layout(location=0) in vec2 aPos
(check-equal? (shader-var-qualifiers (var 'aPos)) '(in))
(check-equal? (shader-var-layout (var 'aPos)) '((location 0)))
(check-equal? (shader-type-name (shader-var-type (var 'aPos))) 'vec2)

;; uniform Light uLight → struct 类型，字段内联
(check-equal? (shader-type-kind (shader-var-type (var 'uLight))) 'struct)
(check-equal? (shader-type-name (shader-var-type (var 'uLight))) 'Light)
(check-equal? (map shader-var-name (shader-type-fields (shader-var-type (var 'uLight)))) '(pos i))
(check-equal? (shader-type-size (shader-var-type (var 'uLight))) 16)

;; uniform sampler2D[4] uMaps → 数组
(define um (shader-var-type (var 'uMaps)))
(check-equal? (shader-type-kind um) 'array)
(check-equal? (shader-type-len um) 4)
(check-equal? (shader-type-name (shader-type-elem um)) 'sampler2D)

;; UBO：block 类型 + layout
(define cam (var 'cam))
(check-equal? (shader-type-kind (shader-var-type cam)) 'block)
(check-equal? (shader-type-name (shader-var-type cam)) 'Camera)
(check-equal? (shader-var-layout cam) '((std140) (binding 0)))
(check-equal? (map shader-var-name (shader-type-fields (shader-var-type cam))) '(view proj))
(check-equal? (shader-type-size (shader-var-type cam)) 128)  ; mat4 × 2

;; out vec2 vUV
(check-equal? (shader-var-qualifiers (var 'vUV)) '(out))

;; struct 定义本身不是接口变量
(check-false (var 'Light))

;; ---------- ③b 查询：限定符 / kind / layout / 名字 ----------
;; 限定符判定
(check-true  (shader-var-has-qualifier? (var 'aPos) 'in))
(check-false (shader-var-has-qualifier? (var 'aPos) 'uniform))
(check-true  (shader-var-has-qualifier? cam 'uniform))

;; layout 取值
(check-equal? (shader-var-layout-ref (var 'aPos) 'location) 0)      ; 0 是真值
(check-equal? (shader-var-layout-ref (var 'uMVP) 'location) #f)     ; 没有该键
(check-equal? (shader-var-layout-ref cam 'binding) 0)
(check-equal? (shader-var-layout-ref cam 'std140) #t)               ; 有键无值
(check-equal? (shader-var-layout-ref (var 'uMVP) 'binding 'missing) 'missing)

;; 名字 → 声明（符号 / 字符串都可以）
(check-equal? (shader-interface-ref ifc 'uMVP) (var 'uMVP))
(check-equal? (shader-interface-ref ifc "uMVP") (var 'uMVP))
(check-false  (shader-interface-ref ifc 'nope))

;; 按限定符取子集（保持源码顺序）
(check-equal? (map shader-var-name (shader-interface-vars-with-qualifier ifc 'in))
              '(aPos aNormal))
(check-equal? (map shader-var-name (shader-interface-vars-with-qualifier ifc 'uniform))
              '(uMVP uTime uLight uMaps cam))
(check-equal? (map shader-var-name (shader-interface-vars-with-qualifier ifc 'out))
              '(vUV))

;; 按类型 kind 取子集
(check-equal? (map shader-var-name (shader-interface-vars-with-kind ifc 'block)) '(cam))
(check-equal? (map shader-var-name (shader-interface-vars-with-kind ifc 'array)) '(uMaps))
(check-equal? (map shader-var-name (shader-interface-vars-with-kind ifc 'struct)) '(uLight))
(check-equal? (shader-interface-vars-with-kind ifc 'sampler) '())   ; uMaps 是 array（元素才是 sampler）

;; 按 layout 键取子集
(check-equal? (map shader-var-name (shader-interface-vars-with-layout ifc 'location))
              '(aPos aNormal))
(check-equal? (map shader-var-name (shader-interface-vars-with-layout ifc 'binding))
              '(cam))

;; ---------- ④ datum 往返 ----------
(check-equal? (datum->shader-interface (shader-interface->datum ifc)) ifc)
(check-equal? (datum->shader-type (shader-type->datum st)) st)
(check-equal? (datum->shader-interface '()) (shader-interface '()))
