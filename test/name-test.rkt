#lang racket/base

;; ============================================================
;; name-test.rkt —— 表面标识符 → GLSL 标识符（便携层）
;; 运行：racket test/name-test.rkt
;;
;; 覆盖：
;;   - 用户标识符：wow-name-type → wow_name_type（变量/函数/参数/struct/字段）
;;   - 内建变量别名：gl-position → gl_Position、gl-frag-coord → gl_FragCoord ...
;;   - 规范拼写仍然可用：gl_Position / foo_bar
;;   - interface：表面名与 GLSL 名双身份（shader-var-name / shader-var-source-name）
;;   - 编译期冲突：foo-bar 与 foo_bar 都归一成 foo_bar → 报错
;;   - 非法标识符：只能在 Racket 里写、不能进 GLSL 的字符 → 报错
;; ============================================================

(require rackunit
         shader/type
         shader/interface
         racket/string
         racket/list
         glsl/rewrite
         shader/program
         shader/pretty
         shader/types)

(define-syntax-rule (check-glsl raw (form ...))
  (check-equal? (shader-program-src (glsl form ...))
                (shader-pretty raw)))

;; ---------- ① glsl-name 直接转换 ----------
(check-equal? (glsl-name 'wow-name-type) "wow_name_type")
(check-equal? (glsl-name 'wow_name_type) "wow_name_type")
(check-equal? (glsl-name "wow-name-type") "wow_name_type")
(check-equal? (glsl-name 'u-MVP) "u_MVP")
(check-equal? (glsl-name-symbol 'wow-name-type) 'wow_name_type)

;; 内建变量：kebab 别名 → 规范 GLSL 拼写（大小写/下划线恢复）
(check-equal? (glsl-name 'gl-position) "gl_Position")
(check-equal? (glsl-name 'gl_position) "gl_Position")
(check-equal? (glsl-name 'gl-frag-coord) "gl_FragCoord")
(check-equal? (glsl-name 'gl_frag_coord) "gl_FragCoord")
(check-equal? (glsl-name 'gl-frag-depth) "gl_FragDepth")
(check-equal? (glsl-name 'gl-point-size) "gl_PointSize")
(check-equal? (glsl-name 'gl-vertex-id) "gl_VertexID")
(check-equal? (glsl-name 'gl-instance-id) "gl_InstanceID")
(check-equal? (glsl-name 'gl-global-invocation-id) "gl_GlobalInvocationID")
(check-equal? (glsl-name 'gl-num-work-groups) "gl_NumWorkGroups")
(check-equal? (glsl-name 'gl-sample-mask-in) "gl_SampleMaskIn")
(check-equal? (glsl-name 'gl-in) "gl_in")
(check-equal? (glsl-name 'gl-out) "gl_out")
(check-equal? (glsl-name 'gl-per-vertex) "gl_PerVertex")
(check-equal? (glsl-name 'gl-max-vertex-attribs) "gl_MaxVertexAttribs")
;; 规范拼写本身也照常通过
(check-equal? (glsl-name 'gl_Position) "gl_Position")
(check-equal? (glsl-name 'gl_VertexID) "gl_VertexID")

;; 别名表可查询（供文档 / 工具）
(check-true (and (assq 'gl-position glsl-builtin-variable-aliases) #t))
(check-true (and (memq 'gl_Position glsl-builtin-variable-names) #t))

;; 非法标识符：不能进 GLSL 的字符
(check-false (glsl-identifier? 'wow?name))
(check-true (glsl-identifier? 'wow_name))
(check-exn exn:fail? (lambda () (glsl-name 'wow?name)))
(check-exn exn:fail? (lambda () (glsl-name '1-wow)))

;; ---------- ② 变量 / 函数 / 参数 ----------
(check-glsl "uniform mat4 u_model_view;\nin vec3 a_pos;\nout vec3 v_color;"
            ((uniform mat4 u-model-view)
             (in vec3 a-pos)
             (out vec3 v-color)))

(check-glsl "void main() {\n  gl_Position = vec4(a_pos, 1.0);\n  v_color = vec3(gl_FragCoord);\n}"
            ((define (main) void
               (set! gl-position (vec4 a-pos 1.0))
               (set! v-color (vec3 gl-frag-coord)))))

;; 规范拼写仍可用（向后兼容）
(check-glsl "void main() {\n  gl_Position = vec4(1.0);\n}"
            ((define (main) void
               (set! gl_Position (vec4 1.0)))))

;; 用户函数 / 参数名
(check-glsl "float my_func(float a_b) { return (a_b * 2.0); }"
            ((define (my-func (float a-b)) float (* a-b 2.0))))

;; ---------- ③ struct / 字段 / block ----------
(check-glsl "struct My_Light { vec3 light_pos; float power; };"
            ((struct My-Light (vec3 light-pos) (float power))))

(check-glsl "struct My_Light { vec3 light_pos; float power; };\nvoid main() {\n  My_Light l;\n  l.light_pos = vec3(1.0);\n}"
            ((struct My-Light (vec3 light-pos) (float power))
             (define (main) void
               (My-Light l)
               (set! (.light-pos l) (vec3 1.0)))))

(check-glsl "out V_Data { vec3 normal_vec; vec2 uv_coord; } vs_out;"
            ((out (block V-Data (vec3 normal-vec) (vec2 uv-coord)) vs-out)))

;; 内建块数组 + 成员：gl-in / .gl-position
(check-glsl "void main() {\n  gl_in[0].gl_Position = vec4(1.0);\n}"
            ((define (main) void
               (set! (.gl-position (aref gl-in 0)) (vec4 1.0)))))

;; 内建变量在左侧（lvalue）也走同一映射
(check-glsl "void main() {\n  gl_FragDepth = 0.5;\n}"
            ((define (main) void
               (set! gl-frag-depth 0.5))))

;; 全小写下划线别名同样可用
(check-glsl "void main() {\n  gl_Position = vec4(1.0);\n}"
            ((define (main) void
               (set! gl_position (vec4 1.0)))))

;; ---------- ④ 数组 / layout / 预处理 ----------
(check-glsl "in vec3[4] a_pos;"
            ((in (array vec3 4) a-pos)))

(check-glsl "layout(local_size_x = 8, local_size_y = 8) in;"
            ((layout (local-size-x 8) (local-size-y 8) in)))

(check-glsl "#define MY_FLAG 1\n#ifdef MY_FLAG\nuniform float u_x;\n#endif"
            ((define-macro MY-FLAG 1)
             (ifdef MY-FLAG)
             (uniform float u-x)
             (pp-endif)))

;; 函数式宏的名字/参数也归一
(check-glsl "#define ADD_TWO(a_b) (a_b + 2.0)"
            ((define-macro (ADD-TWO a-b) (+ a-b 2.0))))

;; ---------- ⑤ interface：表面名 / GLSL 名双身份 ----------
(define shader
  (glsl (version 450 core)
        (layout (location 0) in vec3 a-pos)
        (layout (local-size-x 8) in vec3 a-work)
        (uniform mat4 u-model-view)
        (uniform float uTime)
        (out vec3 v-color)
        (define (main) void)))

(define ifc (shader-program-interface shader))
(define (var name) (shader-interface-ref ifc name))

;; 表面名保留连字符，GLSL 名归一
(check-equal? (shader-var-name (var 'u-model-view)) 'u-model-view)
(check-equal? (shader-var-source-name (var 'u-model-view)) 'u_model_view)
(check-equal? (shader-var-name (var 'a-pos)) 'a-pos)
(check-equal? (shader-var-source-name (var 'a-pos)) 'a_pos)

;; 按表面名或 GLSL 名都能查到同一条声明
(check-eq? (var 'u-model-view) (var 'u_model_view))
(check-eq? (var "u-model-view") (var 'u-model-view))
(check-eq? (var 'a-pos) (var 'a_pos))
(check-equal? (shader-type-name (shader-var-type (var 'u-model-view))) 'mat4)
;; 写进源码的类型/变量拼写由方言决定：看生成的 GLSL
(check-true (string-contains? (shader-program-src shader) "mat4 u_model_view;"))

;; layout 键归一：local-size-x → local_size_x；两种写法都能查
(check-equal? (shader-var-layout (var 'a-work)) '((local_size_x 8)))
(check-equal? (shader-var-layout-ref (var 'a-work) 'local-size-x) 8)
(check-equal? (shader-var-layout-ref (var 'a-work) 'local_size_x) 8)

;; 类型名也保留表面名，同时可得到 GLSL 拼写
(check-equal? (shader-var-name (var 'uTime)) 'uTime)
(check-equal? (shader-var-source-name (var 'uTime)) 'uTime)

;; struct 类型名 / 字段同样有双身份
(define shader2
  (glsl (struct My-Light (vec3 light-pos) (float power))
        (uniform My-Light u-light)))
(define v2 (shader-interface-ref (shader-program-interface shader2) 'u-light))
(check-equal? (shader-var-name v2) 'u-light)
(check-equal? (shader-var-source-name v2) 'u_light)
(check-equal? (shader-type-name (shader-var-type v2)) 'My-Light)
(check-true (string-contains? (shader-program-src shader2) "My_Light u_light;"))
(check-equal? (map shader-var-source-name (shader-type-fields (shader-var-type v2)))
              '(light_pos power))

;; ---------- ⑥ 编译期冲突：归一后同名 ----------
(check-exn exn:fail?
  (lambda ()
    (eval '(glsl (version 330 core)
                 (uniform float foo-bar)
                 (uniform float foo_bar)))))

(check-exn exn:fail?
  (lambda ()
    (eval '(glsl (version 330 core)
                 (uniform float gl-position)
                 (uniform float gl_Position)))))

;; ---------- ⑦ 非法标识符：清晰报错 ----------
(check-exn exn:fail?
  (lambda ()
    (eval '(glsl (version 330 core) (uniform float wow?name)))))

;; struct 名不能占用内建类型/别名
(check-exn exn:fail?
  (lambda ()
    (eval '(glsl (struct vec-3 (float x)) (uniform vec-3 v)))))


;; ---------- ⑧ 内建函数别名（独立表） ----------
(check-equal? (glsl-function-name 'texture-size) "textureSize")
(check-equal? (glsl-function-name 'texture_size) "textureSize")
(check-equal? (glsl-function-name 'd-fdx) "dFdx")
(check-equal? (glsl-function-name 'find-lsb) "findLSB")
(check-equal? (glsl-function-name 'matrix-comp-mult) "matrixCompMult")
(check-equal? (glsl-function-name 'my-func) "my_func")
(check-equal? (glsl-function-name 'textureSize) "textureSize")
(check-true (and (assq 'texture-size glsl-builtin-function-aliases) #t))

(check-glsl
 "uniform sampler2D u_tex;\nin vec2 v_uv;\nfloat my_func(float a_b) { return (a_b + 1.0); }\nvoid main() {\n  vec4 c = textureSize(u_tex, 0);\n  float f = my_func(dFdx(v_uv));\n  float g = matrixCompMult(mat4(1.0), mat4(1.0));\n}"
 ((uniform sampler2D u-tex)
  (in vec2 v-uv)
  (define (my-func (float a-b)) float (+ a-b 1.0))
  (define (main) void
    (vec4 c (texture-size u-tex 0))
    (float f (my-func (d-fdx v-uv)))
    (float g (matrix-comp-mult (mat4 1.0) (mat4 1.0))))))

;; ---------- ⑨ 关键字别名（qualifier / layout key 独立表） ----------
(check-equal? (glsl-qualifier-name 'read-only) "readonly")
(check-equal? (glsl-qualifier-name 'write-only) "writeonly")
(check-equal? (glsl-qualifier-name 'no-perspective) "noperspective")
(check-equal? (glsl-qualifier-name 'in-out) "inout")
(check-equal? (glsl-qualifier-name 'uniform) "uniform")
(check-true (glsl-qualifier? 'read-only))
(check-true (glsl-qualifier? 'readonly))
(check-false (glsl-qualifier? 'read_only))

(check-equal? (glsl-layout-key-name 'local-size-x) "local_size_x")
(check-equal? (glsl-layout-key-name 'early-fragment-tests) "early_fragment_tests")
(check-equal? (glsl-layout-key-name 'triangle-strip) "triangle_strip")
(check-equal? (glsl-layout-key-name 'my-extension-key) "my_extension_key")

(check-glsl
 "layout(early_fragment_tests) in;\nreadonly uniform image2D u_img;\nvoid f(inout vec3 p) {\n}\nvoid main() {\n}"
 ((layout (early-fragment-tests) in)
  (read-only uniform image2D u-img)
  (define (f (in-out vec3 p)) void)
  (define (main) void)))

;; ---------- ⑩ 内建类型别名（共享类型词汇表） ----------
(check-equal? (type-canonical-name 'vec-3) "vec3")
(check-equal? (type-canonical-name 'vec_3) "vec3")
(check-equal? (type-canonical-name 'ivec-2) "ivec2")
(check-equal? (type-canonical-name 'mat-3x2) "mat3x2")
(check-equal? (type-canonical-name 'mat-2x2) "mat2x2")
(check-equal? (type-canonical-name 'dmat-4) "dmat4")
(check-equal? (type-canonical-name 'sampler-2d) "sampler2D")
(check-equal? (type-canonical-name 'sampler_2d_array) "sampler2DArray")
(check-equal? (type-canonical-name 'isampler-2d) "isampler2D")
(check-equal? (type-canonical-name 'image-2d) "image2D")
(check-equal? (type-canonical-name 'atomic-uint) "atomic_uint")
;; 数组 / 多重采样 / cube 数组采样器
(check-equal? (type-canonical-name 'sampler-1d-array) "sampler1DArray")
(check-equal? (type-canonical-name 'sampler-2d-ms-array) "sampler2DMSArray")
(check-equal? (type-canonical-name 'isampler-1d-array) "isampler1DArray")
(check-equal? (type-canonical-name 'usampler-2d-ms-array) "usampler2DMSArray")
(check-equal? (type-canonical-name 'sampler-1d-array-shadow) "sampler1DArrayShadow")
(check-equal? (type-canonical-name 'sampler-2d-rect) "sampler2DRect")
(check-equal? (type-canonical-name 'sampler-2d-rect-shadow) "sampler2DRectShadow")
(check-equal? (type-canonical-name 'isampler-2d-rect) "isampler2DRect")
;; image 的数组 / 多重采样 / cube 数组
(check-equal? (type-canonical-name 'image-1d-array) "image1DArray")
(check-equal? (type-canonical-name 'image-cube-array) "imageCubeArray")
(check-equal? (type-canonical-name 'iimage-2d-ms-array) "iimage2DMSArray")
(check-equal? (type-canonical-name 'uimage-2d-ms-array) "uimage2DMSArray")
(check-equal? (type-canonical-symbol 'vec-3) 'vec3)
(check-false (type-canonical-name 'My-Light))
(check-true (builtin-type? 'sampler-2d))
(check-true (type-alias? 'vec-3))
(check-false (type-alias? 'vec3))
(check-true (and (assq 'vec-3 type-alias-forms) #t))

(check-glsl
 "uniform vec3 u_color;\nuniform mat4 u_model;\nuniform sampler2D u_tex;\nuniform isampler2DArray u_arr;\nvoid main() {\n  vec3 p = vec3(1.0, 2.0, 3.0);\n}"
 ((uniform vec-3 u-color)
  (uniform mat-4 u-model)
  (uniform sampler-2d u-tex)
  (uniform isampler-2d-array u-arr)
  (define (main) void
    (vec-3 p (vec-3 1.0 2.0 3.0)))))

(define alias-ifc
  (shader-program-interface
   (glsl (uniform vec-3 u-color)
         (uniform mat-4 u-model)
         (uniform sampler-2d u-tex))))
(check-equal? (map (lambda (v) (shader-type-name (shader-var-type v)))
                   (shader-interface-vars alias-ifc))
              '(vec3 mat4 sampler2D))

(displayln "name 全部测试通过")
