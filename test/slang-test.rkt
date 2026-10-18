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
         "../slang/rewrite.rkt"
         "../slang/types.rkt"
         "../slang/names.rkt"
         "../shader/type.rkt"
         "../shader/interface.rkt"
         "../shader/program.rkt")

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

(displayln "slang 全部测试通过")
