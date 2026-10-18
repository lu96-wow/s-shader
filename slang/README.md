# Slang 方言 · slang/ —— `(slang)` 命名空间（step 3d 骨架）

只做「Slang 特有」的事；方言无关的部分全在 core（`shader/`）。

| 逻辑 | 文件 | 归属 |
|---|---|---|
| 类型目录（`float3` / `float4x4` ↔ canonical `vec3` / `mat4`） | `types.rkt` | 方言 |
| 语义 / 修饰符 / 属性表（`SV-Position`→`SV_Position`、`vk-binding`→`vk::binding`） | `names.rkt` | 方言 |
| 字符串原语（`[[vk::…]]` / `cbuffer` / 语义注解 / 特化常量） | `core.rkt` | 方言 |
| 表面语法 → Slang（`(slang)` 宏，编译期变换） | `rewrite.rkt` | 方言 |
| 类型名词汇表、标识符引擎、模型/反射、美化、产物、报错 | `../types.rkt`、`../shader/*` | core |

## 当前能力（声明侧）

```racket
#lang shader/slang

(slang
  ;; 结构体字段带注解：语义（后缀）、修饰符（前缀）
  (struct vs-out
    (float4 pos SV-Position)
    (float2 uv  TEXCOORD0)
    (float3 nrm NORMAL nointerpolation))

  ;; 常量缓冲块：set / binding + 字段（含参数化类型）
  (cbuffer Camera (set 0) (binding 0)
    (float4x4 view)
    (float4x4 proj)
    ((texture-2d float4) albedo))

  ;; 特化常量
  (const-id 0 int TILE 8))
```

产出：

```slang
struct vs_out {
  float4 pos : SV_Position;
  float2 uv : TEXCOORD0;
  nointerpolation float3 nrm : NORMAL;
};
[[vk::binding(0, 0)]] cbuffer Camera {
  float4x4 view;
  float4x4 proj;
  Texture2D<float4> albedo;
};
[[vk::constant_id(0)]] const int TILE = 8;
```

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

## 待办（step 4）

- [ ] 表达式 / 语句 / 函数体（`if` / `if-ternary` / `mul` 语义按 §Q1 决策：`*` 逐分量，`mul()` 矩阵乘）
- [ ] 入口属性：`(attr (shader vertex) (numthreads 8 8 1))`、`sv-position` 等系统值输入
- [ ] `push-constant` / `param-block` / `sbuffer` 的读写变体
- [ ] `parse-error-log`（`file:line:col: error` 格式）
- [ ] 组合宏 `fragment` / `splice`（需与 GLSL 方言的版本讨论是否上提到 core，见下）

## 已知假设（未验证，step 4 接 slangc 时确认）

1. `[[vk::binding(B, S)]] cbuffer Name { … };` 这种「属性 + cbuffer」的 Vulkan 写法
   能被 slangc 接受（等价写法还有 `struct Name{…}; [[vk::binding(B,S)]] ConstantBuffer<Name> inst;`）。
2. `const-id` 发射成 `[[vk::constant_id(N)]] const int TILE = 8;` 时，特化常量在 Slang 里的
   推荐写法是否需要 `Uniform`/`static const` 修饰。

## 与 GLSL 方言的模块边界

- 两个方言**互不 require**；都只 require core。
- `fragment` / `splice` / `shader` 目前在 GLSL 方言里，因此 `#lang shader` 只给 core，
  不给两个方言（否则同一模块里会重复导出同名宏）。若将来要「一个模块两个方言都能用」，
  应把 `fragment`/`splice` 上提到 core（chunk 本就是纯表面数据），`shader`/`glsl`/`slang`
  各留在方言里。
