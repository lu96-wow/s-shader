#lang shader/glsl

;; ============================================================
;; lang-test.rkt —— #lang shader/glsl 顶层入口端到端测试（纯 GLSL，无 OpenGL）
;;
;; 运行：racket test/lang-test.rkt
;; 验证 #lang shader/glsl 把纯 GLSL 部分装好：
;;   Part 1 语言：(glsl ...) 宏 / 接口反射 / 源映射
;;   Part 2 值层：GLSL 风格构造与运算（vec3 / vadd / mat4-* / shader-struct / gl-vec）
;;   报错层：parse-error-log 等纯函数可用
;; （OpenGL 部分的 #lang glsl-opengl 测试见另一个包的 test/lang-opengl-test.rkt）
;; 注意：本文件是「(glsl) 外」的普通 Racket 代码；同一符号 vec3 在 (glsl ...) 内是
;;       GLSL 类型、在这里是 f32vector 构造函数——两套命名空间互不干扰。
;; ============================================================

(require rackunit racket/string)

;; ---------- (glsl ...) 宏 → shader-program ----------

(define vert
  (glsl (version 330 core)
        (layout (location 0) in vec3 aPos)
        (layout (location 1) in vec3 aColor)
        (uniform mat4 uMVP)
        (out vec3 vColor)
        (define (main) void
          (set! vColor aColor)
          (set! gl_Position (* uMVP (vec4 aPos 1.0))))))

(check-true (shader-program? vert))

(define src (shader-program-src vert))
(check-true (string-contains? src "#version 330 core"))
(check-true (string-contains? src "layout(location = 0) in vec3 aPos;"))
(check-true (string-contains? src "gl_Position = (uMVP * vec4(aPos, 1.0));"))

;; ---------- 接口反射 ----------

(define ifc (shader-program-interface vert))
(define mvp (shader-interface-ref ifc 'uMVP))
(check-true (and mvp #t))
(check-true (shader-var-has-qualifier? mvp 'uniform))
(check-equal? (shader-type-name (shader-var-type mvp)) 'mat4)
(check-equal? (shader-var-layout-ref (shader-interface-ref ifc 'aPos) 'location) 0)
(check-equal? (map shader-var-name (shader-interface-vars-with-qualifier ifc 'in))
              '(aPos aColor))
(check-equal? (map shader-var-name (shader-interface-vars-with-kind ifc 'sampler)) '())

;; ---------- 源映射（行级：GLSL 行 → 顶层 form） ----------

(define uMVP-line
  (for/first ([l (in-list (string-split src "\n"))] [i (in-naturals 1)]
              #:when (string=? l "uniform mat4 uMVP;"))
    i))
(check-true (and uMVP-line #t))
(check-true (and (shader-program-lookup vert uMVP-line) #t))


;; ---------- CPU 侧值 API（GLSL 风格名） ----------

(check-true (f32vector? (vec3 1.0 2.0 3.0)))
(check-true (f32vector? (vec-3 1.0 2.0 3.0)))
(check-equal? (f32vector->list (vec-3 1.0 2.0 3.0)) '(1.0 2.0 3.0))
(check-equal? (f32vector->list (mat-2 2.0)) '(2.0 0.0 0.0 2.0))
(check-equal? (shader-size 'vec-3) 3)
(check-equal? (shader-size 'mat_4) 16)
(check-equal? (shader-kind 'dvec-3) 'f64)
(check-equal? (f32vector->list (vadd (vec2 1.0 2.0) (vec2 3.0 4.0))) '(4.0 6.0))
(check-equal? (vcount (vec4 1.0 2.0 3.0 4.0)) 4)
(check-equal? (shader-size 'vec3) 3)
(check-equal? (shader-byte-size 'vec3) 12)
(check-equal? (shader-stride-bytes 'vec3 'vec2) 20)

(define M (mat4 2.0))                                 ; 对角矩阵
(check-equal? (vz (mat4-mul-vec M (vec4 0.0 0.0 1.0 1.0))) 2.0)

(shader-struct vertex (vec3 pos) (vec3 color))
(define v0 (vertex (vec3 1.0 2.0 3.0) (vec3 1.0 0.0 0.0)))
(check-equal? (f32vector->list (vertex->f32vector v0)) '(1.0 2.0 3.0 1.0 0.0 0.0))
(check-equal? (vertex-stride) 24)
(check-equal? (vertex-field-offset 'color) 12)
(check-equal? (vertex-field-size 'pos) 3)

;; 类型别名在 CPU 侧同样可用；<Name>-fields 存 canonical 名
(shader-struct alias-vertex (vec-3 pos) (vec-2 uv))
(check-equal? (alias-vertex-fields) '((pos vec3) (uv vec2)))
(check-equal? (alias-vertex-stride) 20)
(check-equal? (f32vector->list (alias-vertex->f32vector
                                (alias-vertex (vec-3 1.0 2.0 3.0) (vec-2 0.0 1.0))))
              '(1.0 2.0 3.0 0.0 1.0))

(define gv (gl-vec (vec2 -0.5 -0.5) (vec2 0.5 -0.5) (vec2 0.0 0.5)))
(check-equal? (gl-vec-count gv) 3)
(check-equal? (f32vector->list (gl-vec->f32vector gv)) '(-0.5 -0.5 0.5 -0.5 0.0 0.5))

;; ---------- 报错层符号可用（纯函数，不碰 opengl）----------

(check-true (procedure? parse-error-log))

(displayln "lang (glsl) 全部测试通过")
