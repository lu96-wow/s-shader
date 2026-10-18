#lang racket/base

;; ============================================================
;; slang-test.rkt —— Slang 方言骨架（step 3d）
;;
;; 运行：racket test/slang-test.rkt
;; 目的：**只**验证 core 的边界够用 —— 声明侧能产出 shader-program，
;;       且三个为 Slang 预留的槽都被真正用上：
;;         shader-type.args / shader-var.annotations / shader-var.owner
;; 不做编译（decision 5：先只拼字符串）。
;; ============================================================

(require rackunit racket/string
         slang/rewrite
         slang/types
         slang/names
         shader/type
         shader/interface
         shader/program)

(define shader
  (slang
    (struct vs-out
      (float4 pos SV-Position)
      (float2 uv TEXCOORD0)
      (float3 nrm NORMAL nointerpolation))
    (cbuffer Camera (set 0) (binding 0)
      (float4x4 view)
      (float4x4 proj)
      ((texture-2d float4) albedo))
    (const-id 0 int TILE 8)))

(define src (shader-program-src shader))
(define ifc (shader-program-interface shader))

;; ---------- ① 文本：Slang 拼写 + 注解 + Vulkan 属性 ----------

(check-true (string-contains? src "struct vs_out {"))
(check-true (string-contains? src "float4 pos : SV_Position;"))
(check-true (string-contains? src "float2 uv : TEXCOORD0;"))
(check-true (string-contains? src "nointerpolation float3 nrm : NORMAL;"))
(check-true (string-contains? src "[[vk::binding(0, 0)]] cbuffer Camera {"))
(check-true (string-contains? src "float4x4 view;"))
(check-true (string-contains? src "Texture2D<float4> albedo;"))
(check-true (string-contains? src "[[vk::constant_id(0)]] const int TILE = 8;"))

;; 类型拼写是方言的：canonical 的 vec3/mat4 写成 float3/float4x4
(check-false (string-contains? src "vec3"))

;; ---------- ② 接口：块 + 成员（owner 槽）----------

(define cam (shader-interface-ref ifc 'Camera))
(check-true (shader-var? cam))
(check-equal? (shader-type-kind (shader-var-type cam)) 'block)
(check-equal? (shader-var-layout-ref cam 'set) 0)
(check-equal? (shader-var-layout-ref cam 'binding) 0)

(define members (shader-type-fields (shader-var-type cam)))
(check-equal? (map shader-var-name members) '(view proj albedo))
(check-equal? (map shader-var-owner members) '(Camera Camera Camera))

;; 成员的类型是 canonical 名（与 GLSL 方言、CPU 值层同一套）
(check-equal? (map shader-type-name (map shader-var-type members))
              '(mat4 mat4 sampler2D))
(check-equal? (shader-type-size (shader-var-type (car members))) 64)

;; 参数化类型：args 槽记元素类型
(define albedo (caddr members))
(check-equal? (map shader-type-name (shader-type-args (shader-var-type albedo))) '(vec4))

;; ---------- ③ 接口：注解槽 ----------

(check-equal? (map shader-var-annotations members) '(() () ()))

;; const-id：修饰符/属性进 qualifiers / layout
(define tile (shader-interface-ref ifc 'TILE))
(check-equal? (shader-var-qualifiers tile) '(const))
(check-equal? (shader-var-layout-ref tile 'constant_id) 0)
(check-equal? (shader-type-name (shader-var-type tile)) 'int)

;; ---------- ④ 结构体字段的注解：从 struct 定义里读（不进接口）----------

;; struct 只定义类型，不进接口变量表
(check-false (shader-interface-ref ifc 'vs-out))
(check-false (shader-interface-ref ifc 'vs_out))

;; ---------- ⑤ 类型目录：双向映射 ----------

(check-equal? (slang-type-spelling 'vec3) 'float3)
(check-equal? (slang-type-spelling 'mat4) 'float4x4)
(check-equal? (slang-type-spelling 'mat3x2) 'float2x3)   ; GLSL 列x行 → Slang 行x列
(check-equal? (shader-type-name (slang-type-of 'float3)) 'vec3)
(check-equal? (shader-type-base (slang-type-of 'float3)) 'float)
(check-equal? (shader-type-dims (slang-type-of 'float3)) '(3))
(check-false (slang-type-of 'My-Light))

;; ---------- ⑥ 标识符 / 注解表 ----------

(check-equal? (slang-semantic-name 'SV-Position) "SV_Position")
(check-equal? (slang-semantic-name 'sv_position) "SV_Position")
(check-equal? (slang-semantic-name 'TEXCOORD0) "TEXCOORD0")
(check-equal? (slang-modifier-name 'no-interpolation) "nointerpolation")
(check-equal? (slang-annotation-role 'SV-Position) 'suffix)
(check-equal? (slang-annotation-role 'nointerpolation) 'prefix)
(check-equal? (slang-name 'u-model-view) "u_model_view")


;; ============================================================
;; step 4：函数体 / 表达式 / 语句 / 入口属性
;; ============================================================

(define vs
  (slang
    (struct VS-IN (float3 pos POSITION) (float2 uv TEXCOORD0))
    (struct VS-OUT (float4 pos SV-Position) (float2 uv TEXCOORD0))
    (cbuffer Camera (set 0) (binding 0) (float4x4 view) (float4x4 proj))
    (define (vs-main (VS-IN i)) (attr (shader vertex)) VS-OUT
      (VS-OUT o)
      (set! (.pos o) (mul proj (mul view (float4 (.pos i) 1.0))))
      (set! (.uv o) (.uv i))
      o)))

(define vssrc (shader-program-src vs))

(check-true (string-contains? vssrc "struct VS_IN {"))
(check-true (string-contains? vssrc "float3 pos : POSITION;"))
(check-true (string-contains? vssrc "[[shader(\"vertex\")]] VS_OUT vs_main(VS_IN i) {"))
(check-true (string-contains? vssrc "VS_OUT o;"))
;; 矩阵乘 → mul()；Slang 的 * 逐分量
(check-true (string-contains? vssrc "o.pos = mul(proj, mul(view, float4(i.pos, 1.0)));"))
(check-true (string-contains? vssrc "o.uv = i.uv;"))
(check-true (string-contains? vssrc "return o;"))
;; 结构体名/字段名走 Slang 的 '-'→'_'（这里大写保持，因为写的是 VS-IN）
(check-true (string-contains? vssrc "struct VS_OUT {"))

;; 语句：if / for / cond / while / switch / break / continue / discard
(define cs
  (slang
    (define (cs-main (uint3 id SV-DispatchThreadID) (inout float3 acc))
            (attr (shader compute) (numthreads 8 8 1)) void
      (if (> (.x id) 0) (set! acc (float3 1.0 0.0 0.0)) (set! acc (float3 0.0)))
      (when (> (.y id) 2) (return))
      (unless #f (discard))
      (for (uint i 0) (< i 8) (++ i)
        (if (= i 3) (break))
        (if (= i 4) (continue)))
      (cond [(= (.x id) 1) (continue)]
            [else (set! acc (float3 2.0))])
      (while (> (.z id) 0) (-- (.z id))))))

(define cssrc (shader-program-src cs))
(check-true (string-contains? cssrc "[[shader(\"compute\")]] [[numthreads(8, 8, 1)]] void cs_main(uint3 id : SV_DispatchThreadID, inout float3 acc) {"))
(check-true (string-contains? cssrc "if ((id.x > 0)) {"))
(check-true (string-contains? cssrc "for (uint i = 0; (i < 8); ++i) {"))
(check-true (string-contains? cssrc "if ((i == 3)) {"))
(check-true (string-contains? cssrc "if ((id.x == 1)) {"))
(check-true (string-contains? cssrc "discard;"))

;; 表达式语义差异
(define expr-src
  (shader-program-src
   (slang
     (define (f) float4
       (float4 a (sample tex samp uv))
       (float4 b (sample-level tex samp uv 2.0))
       (float c (* a b))
       (float d (mul a b))
       (bool e (xor (< c 1.0) (> d 2.0)))
       b))))

(check-true (string-contains? expr-src "tex.Sample(samp, uv)"))
(check-true (string-contains? expr-src "tex.SampleLevel(samp, uv, 2.0)"))
(check-true (string-contains? expr-src "(a * b)"))
(check-true (string-contains? expr-src "mul(a, b)"))
(check-true (string-contains? expr-src "((c < 1.0) != (d > 2.0))"))

;; type-form 的构造器 / 数组 / 限定符
(define decl-src
  (shader-program-src
   (slang
     (define (g) void
       (groupshared (array float 64) data)
       (const float PI 3.14159)
       (static int counter 0)))))

(check-true (string-contains? decl-src "groupshared float data[64];"))
(check-true (string-contains? decl-src "const float PI = 3.14159;"))
(check-true (string-contains? decl-src "static int counter = 0;"))

(displayln "slang 全部测试通过")
