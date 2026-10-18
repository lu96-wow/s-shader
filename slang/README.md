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
- [ ] `push-constant` / `param-block` / 读写缓冲（`RWStructuredBuffer` / `RWTexture2D`）
- [ ] 组合宏 `fragment` / `splice`（需决定是否上提到 core，见下）
- [ ] 接 `slangc` 做编译验证（当前只拼字符串）

## 已知假设（未验证，step 4 接 slangc 时确认）

1. `[[vk::binding(B, S)]] cbuffer Name { … };` 这种「属性 + cbuffer」的 Vulkan 写法
   能被 slangc 接受（等价写法还有 `struct Name{…}; [[vk::binding(B,S)]] ConstantBuffer<Name> inst;`）。
2. `const-id` 发射成 `[[vk::constant_id(N)]] const int TILE = 8;` 时，特化常量在 Slang 里的
   推荐写法是否需要 `Uniform`/`static const` 修饰。

## 与 GLSL 方言的模块边界

- 三个集合：`shader`（core）、`glsl`、`slang`。
- 两个方言**互不 require**；都只 require `shader`。
- 语言入口就是 `#lang glsl` / `#lang slang`（各自一个集合，无需前缀）。
- `fragment` / `splice` / `shader` 目前在 GLSL 方言里。若将来要「一个模块里两个方言都能用」，
  应把 `fragment`/`splice` 上提到 core（chunk 本就是纯表面数据），`glsl`/`slang`/`shader`
  各留在方言里。
