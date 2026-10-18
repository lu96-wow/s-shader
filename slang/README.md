# Slang 方言 · slang/ —— `(slang)` 命名空间（step 3d 骨架）

只做「Slang 特有」的事；方言无关的部分全在 core（`shader/`）。

| 逻辑 | 文件 | 归属 |
|---|---|---|
| 类型目录（`float3` / `float4x4` ↔ canonical `vec3` / `mat4`） | `types.rkt` | 方言 |
| 语义 / 修饰符 / 属性表（`SV-Position`→`SV_Position`、`vk-binding`→`vk::binding`） | `names.rkt` | 方言 |
| 字符串原语（`[[vk::…]]` / `cbuffer` / 语义注解 / 特化常量） | `core.rkt` | 方言 |
| 表面语法 → Slang（`(slang)` 宏，编译期变换） | `rewrite.rkt` | 方言 |
| 类型名词汇表、标识符引擎、模型/反射、美化、产物、报错 | `shader/types`、`shader/*` | core |

## 当前能力

```racket
#lang slang

(slang
  ;; 结构体字段带注解：语义（后缀）、修饰符（前缀）
  (struct VS-IN  (float3 pos POSITION) (float2 uv TEXCOORD0))
  (struct VS-OUT (float4 pos SV-Position) (float2 uv TEXCOORD0))

  ;; 常量缓冲块：set / binding + 字段（含参数化类型）
  (cbuffer Camera (set 0) (binding 0)
    (float4x4 view)
    (float4x4 proj)
    ((texture-2d float4) albedo))

  ;; 特化常量
  (const-id 0 int TILE 8)

  ;; 函数：参数/返回值 + 入口属性 + 语句/表达式
  (define (vs-main (VS-IN i)) (attr (shader vertex)) VS-OUT
    (VS-OUT o)
    (set! (.pos o) (mul proj (mul view (float4 (.pos i) 1.0))))
    (set! (.uv o) (.uv i))
    o))
```

产出：

```slang
struct VS_IN {
  float3 pos : POSITION;
  float2 uv : TEXCOORD0;
};
struct VS_OUT {
  float4 pos : SV_Position;
  float2 uv : TEXCOORD0;
};
[[vk::binding(0, 0)]] cbuffer Camera {
  float4x4 view;
  float4x4 proj;
  Texture2D<float4> albedo;
};
[[vk::constant_id(0)]] const int TILE = 8;
[[shader("vertex")]] VS_OUT vs_main(VS_IN i) {
  VS_OUT o;
  o.pos = mul(proj, mul(view, float4(i.pos, 1.0)));
  o.uv = i.uv;
  return o;
}
```

### 表面语法（方言差异部分）

| 写法 | 产出 | 说明 |
|---|---|---|
| `(* a b)` | `(a * b)` | Slang 的 `*` 是**逐分量** |
| `(mul a b)` | `mul(a, b)` | 跨方言的矩阵乘 |
| `(sample tex samp uv)` | `tex.Sample(samp, uv)` | GLSL 的 `texture()` 在 Slang 是方法 |
| `(sample-level tex samp uv lod)` | `tex.SampleLevel(samp, uv, lod)` | |
| `(xor a b)` | `(a != b)` | Slang 没有 `^^` |
| `(attr (shader vertex) (numthreads 8 8 1))` | `[[shader("vertex")]] [[numthreads(8, 8, 1)]]` | 写在参数表与返回类型之间 |
| `(uint3 id SV-DispatchThreadID)` | `uint3 id : SV_DispatchThreadID` | 参数上的语义后缀 |
| `(inout float3 acc)` | `inout float3 acc` | 参数限定符 |
| `(array float 64) data` | `float data[64]` | 数组维度写在**名字后面**（与 GLSL 不同） |
| `(atomic-add c 1)` | `InterlockedAdd(c, 1)` | 内建函数别名表；`(barrier)` → `GroupMemoryBarrierWithGroupSync()`、`(wave-sum x)` → `WaveActiveSum(x)` |
| `(push-const Push (float s))` | `[[vk::push_constant]] cbuffer Push { float s; };` | push constant 块（std430） |
| `(resource src (sbuffer float) (set 0) (binding 0))` | `[[vk::binding(0, 0)]] StructuredBuffer<float> src;` | 任意资源：`sbuffer` / `rw-sbuffer` / `texture-2d` / `rw-texture-2d` / `sampler-state` |
| `(param-block Materials mat (set 1) (binding 0) field…)` | `struct Materials { … }; [[vk::binding(0, 1)]] ParameterBlock<Materials> mat;` | 一个描述符集打包多个资源；成员 binding 由 Slang 顺序分配 |

语句与 GLSL 方言一致：`begin` / `when` / `unless` / `if`（语句）/ `if-ternary`（三元）/
`cond` / `for` / `while` / `do-while` / `switch` / `break` / `continue` / `return` / `discard` / `raw`。

接口反射里三个 Slang 专用槽都被用上：

| 槽 | 用在哪 | 例 |
|---|---|---|
| `shader-type.args` | 参数化类型 | `Texture2D<float4>` → `'sampler2D` + args `(vec4)` |
| `shader-var.annotations` | 字段注解 | `(float4 pos SV-Position)` → `'(SV_Position)` |
| `shader-var.owner` | 块成员 | `view` 的 owner = `'Camera` |

`shader-var.source-name` 由本方言构造时算好（`u-model-view` → `u_model_view`），core 不做转换。

## 命名约定

- canonical 类型名沿用 core 的词汇（`vec3` / `mat4` / `sampler2D`）：CPU 值层、接口反射、
  两个方言共享同一套 canonical 名，只有**写进源码的拼写**不同。
- 矩阵命名约定相反：GLSL `mat3x2` = 3 列 × 2 行，Slang/HLSL `float2x3` = 2 行 × 3 列。
  `canonical mat3x2 ⇄ slang float2x3`。
- 语义/修饰符查表对大小写与 `-`/`_` 不敏感：`SV-Position` / `sv_position` / `SV_Position` 等价。

## 待办

- [x] 表达式 / 语句 / 函数体（`*` 逐分量、`mul()`、`if` / `if-ternary`）
- [x] 入口属性（`[shader(…)]` / `[numthreads(…)]`）、系统值参数（`SV_DispatchThreadID` …）
- [x] 数组维度按 HLSL 规则写在名字后面
- [x] `parse-error-log`（`file:line:col:` / `file(line):`）
- [x] 原子 / 屏障 / 波内建函数别名表（`atomic-add`→`InterlockedAdd`、`barrier`→`GroupMemoryBarrierWithGroupSync`、`wave-sum`→`WaveActiveSum` …）
- [x] `push-const` / `param-block` / `resource`（`sbuffer` / `rw-sbuffer` / `texture-2d` / `rw-texture-2d` / `sampler-state`）
- [x] 接 `slangc` 做编译验证 + `spirv-val`；Vulkan compute 端到端跑通
- [ ] UBO/推送常量的 std140/std430 布局助手（`shader-struct` 目前是自然布局，只适合顶点属性）
- [ ] 组合宏 `glsl-fragment` / `glsl-splice` 的 Slang 版（或上提到 core，见下）

## 编译验证（已接 slangc）

```bash
# 生成 → 编译 → 校验
slangc shader.slang -target spirv -entry vs_main -stage vertex \
       -matrix-layout-column-major -o shader.spv
spirv-val shader.spv
```

已用 **slangc 2026.20 + spirv-val** 验证过的构造：`cbuffer` / `[[vk::push_constant]] cbuffer` /
`ParameterBlock<T>` / `StructuredBuffer` / `RWStructuredBuffer` / `Texture2D` / `RWTexture2D` /
`SamplerState` / 语义注解 / 入口属性。

要点：

- **入口名**：slangc 把 SPIR-V 的入口名固定成 `"main"`（不是函数名）。建 pipeline 时
  `VkPipelineShaderStageCreateInfo.pName` 要用 `"main"`。
- **矩阵布局**：Slang 默认**行主序**，而 CPU 值层与 GLSL 是列主序。编译时必须加
  `-matrix-layout-column-major`，否则 `mat4` 会被按转置解释。
- **块布局**：`cbuffer` → std140；`push constant` → std430。本包的值层 `shader-struct`
  是**自然布局**（顶点属性用），不等于 std140/std430（例如 `vec3` 在后面两者里要按 16 字节对齐）。
  往 UBO/推送常量里塞 `vec3` 要小心，目前建议只用 `mat4` / `float4` / 标量，或用标量数组。
- **ParameterBlock**：成员按声明顺序从给定 binding 起顺序分配（编译测试里核对过
  `(set 1) (binding 0)` + 2 个成员 → SPIR-V 里 `DescriptorSet 1 / Binding 0,1`）。

端到端：`experiments/slang-vulkan-compute.rkt` 把 `(slang …)` → slangc → SPIR-V →
**racket-vulkan** compute dispatch 跑通，并逐元素校验 `dst[i] = src[i] * scale`
（开 `VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation` 时零校验错误）。

自动化测试：`test/slang-compile-test.rkt`（找不到 slangc 就跳过）。

## 已验证 / 仍未验证

- ✅ `[[vk::binding(B, S)]] cbuffer Name { … };`（属性 + cbuffer 的 Vulkan 写法）被 slangc 接受，
  编译出的 SPIR-V 里 `DescriptorSet S / Binding B` 正确。
- ✅ `[[vk::push_constant]] cbuffer Push { … };`、`ParameterBlock<T>`、`[[vk::constant_id(N)]]`
  同样被接受（见 `test/slang-compile-test.rkt`）。
- ⚠️ 特化常量目前发射成 `[[vk::constant_id(N)]] const T 名 = 值;`，没有加 `Uniform`/`static`；
  编译通过，但若要按"运行期可覆盖"的方式流水线特化，还需在 Vulkan 侧配合
  `VkSpecializationInfo` 验证一次。

## 与 GLSL 方言的模块边界

- 三个集合：`shader`（core）、`glsl`、`slang`。
- 两个方言**互不 require**；都只 require `shader`。
- 语言入口就是 `#lang glsl` / `#lang slang`（各自一个集合，无需前缀）。
- `fragment` / `splice` / `shader` 目前在 GLSL 方言里。若将来要「一个模块里两个方言都能用」，
  应把 `fragment`/`splice` 上提到 core（chunk 本就是纯表面数据），`glsl`/`slang`/`shader`
  各留在方言里。
