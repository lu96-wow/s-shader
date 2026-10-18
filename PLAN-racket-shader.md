# racket-shader 迁移计划

> 状态：step 1（设计评估）草稿。目的是先回答一个问题：**Slang 方言需要 GLSL 层里的哪些逻辑**，
> 据此决定哪些东西提升到 `shader/core`、哪些两个方言各留一份。

## 0. 已定决策

| # | 决策 |
|---|---|
| 1 | 包名 `racket-shader`；**不做兼容层**，一次迁移干净 |
| 2 | 语言名见 §1（`#lang shader` / `#lang glsl` / `#lang slang`） |
| 3 | core 把 glsl 与 slang 的公共逻辑都收进来；语义差异逐条评估后再决定要不要分叉（本文 §2.3） |
| 4 | 不为向后兼容牺牲能力：以目标语言本身的表达能力为准设计表面语法 |
| 5 | 现阶段**只拼字符串**，不接编译器、不做编译期校验 |
| 6 | 模块组合只用 Racket 层（`glsl-fragment` / `glsl-splice`）→ 改名 `fragment` / `splice`；`import` / `#include` 用 `raw` 裸字符串，Racket 不特殊处理 |
| 7 | `(if c t e)` 改成语句 if/else；三元改名 `(if-ternary c t e)`；`when` / `unless` / `cond` 保留 |
| 8 | Q1=(a) slang 方言 `*` 逐分量，跨方言矩阵乘用 `(mul a b)` |
| 9 | Q2=(a) `uniform` 换成显式 `(cbuffer …)` / `(param-block …)` / `(push-const …)` |
| 10 | Q4=是：`shader-type` / `shader-var` 的槽位一次到位（`args` / `annotations` / `owner`） |

## 1. 语言名：实测结论

Racket 的 `#lang <name>` 解析规则是 `<name>/lang/reader.rkt`（`<name>` 可以是多段路径）。
本机用 `PLTCOLLECTS` 隔离验证过：

| 写法 | 解析到 | 结论 |
|---|---|---|
| `#lang slang` | `slang/lang/reader.rkt` | ✅ 可行（需占用顶层 collection `slang`） |
| `#lang slang` | `shader/slang/lang/reader.rkt` | ✅ 可行 |
| `#lang glsl` | `shader/glsl/lang/reader.rkt` | ✅ 可行 |

推荐：**一个 collection `shader`，内含 `shader/glsl`、`shader/slang` 两个子集合**，三个语言入口：

- `#lang shader` —— 同时提供 `(glsl ...)` 和 `(slang ...)` 两个宏 + 共享值层（对应决策 3）
- `#lang glsl` —— 只给 `(glsl ...)`，防止误用错方言的表
- `#lang slang` —— 只给 `(slang ...)`

不推荐占用顶层 `slang`：真正的 Slang 项目将来若有 Racket 绑定会撞名，而 `shader/slang`
自解释。若坚持 `#lang slang`，只是多一个两行的 reader，随时可加。

## 2. Step 1 交付：slang 需要 GLSL 层的哪些逻辑

### 2.1 逐文件评估（行数按当前代码）

| 现状 | 行 | 归属 | 动作 / 风险 |
|---|---|---|---|
| `core/value/*`（14 个文件） | ~1000 | **core 原样** | 纯 `ffi/vector`，与着色语言无关。仅 `rename-type.rkt`（26 处）、`rename-layout.rkt`、`rename-matrix.rkt` 里的 `glsl-size` / `glsl-byte-size` / `glsl-kind` / `glsl-stride-bytes` 要改名 `shader-*`；`vec4` / `mat4-mul` / `swizzle` 这类值名两方言共用，不动 |
| `core/glsl/pretty.rkt` | 128 | **core 原样 + 小改** | 按 `; { } ( )` 断行，`[[vk::binding(0,0)]]` 天然能过；需新增：`[[...]]` 与 `import` / `#include` 整行原样（沿用现有"行首 `#` 整行复制"思路） |
| `core/glsl/program.rkt` | 105 | **core，改名** | 纯数据（文本 + 行级源映射 + 接口 datum），零 GLSL 知识。`glsl-program` → `shader-program`，`glsl-form` → `shader-form` |
| `core/tool/error.rkt` | 132 | **core 拆两半** | `locate` / `render-*` / `render-numbered-lines` 通用；`parse-gl-error-log` 的正则 `([0-9]+):([0-9]+)[(]…` 是 **Mesa 格式**，Slang 是 `file:line:col: error:`，各放方言层 |
| `core/glsl/interface.rkt` | 290 | **core 拆两半** | `shader-type` / `shader-var` 结构 + 查询 + datum 往返 → core；`builtin-type` 的前缀解析（`parse-vector` / `sampler-base` / `image-base`）是 GLSL 类型目录 → 方言层。**kind 必须由方言目录显式给**，不能靠名字前缀猜（见 §2.3-②） |
| `core/glsl/names.rkt` | 338 | **core 抽引擎 + 方言留表** | `camel->kebab`、`make-camel-alias-table`、`alias-ref`、`user-identifier-name`、`identifier?` 全是方言无关的机制（约 150 行）→ `shader/ident.rkt`；四张表内容各自方言 |
| `core/glsl/core.rkt` | 266 | **方言层（两份）** | 产物形态不同，必须有 `glsl-layout` / `slang-attr` 之分。但 `->str`、`quals->prefix`、`join-spaces`、`wrap-block`、`trim-semicolon`、`ident-char?` 可抽 `shader/emit-util.rkt` |
| `core/glsl/rewrite.rkt` | 661 | **方言层（两份）** | 表达式 / 控制流骨架两边几乎逐字相同，但 `rw-type` / `rw-field` / `rw-param` / `rw-top` 必须各写。见 §2.2 |
| `core/vocab/type-names.rkt` | 187 | **方言层（glsl）** | slang 另写 `slang/types.rkt`，见 §2.3-② |

结论：**约 1900 / 3433 行进 core（含 1200 行值层），约 1000 行是一方言一份，slang 全新约 600–800 行。**

### 2.2 `rewrite.rkt` 里哪些能「同一份代码换张表」

可以：`rw-expr` 的运算符/赋值/自增/swizzle/字段/下标/调用/构造器分支、`rw-body`、
`when`/`unless`/`cond`/`for`/`while`/`do-while`/`switch`/`break`/`continue`/`return`/`discard`、
`declaration?`、`collect-quals`、`collect-layout-items`、`check-duplicates` 的骨架。

不行（必须各自实现）：`rw-type`（参数化类型）、`rw-field` / `rw-param`（注解槽）、
`rw-top`（Slang 多了 `cbuffer` / `param-block` / `push-const` / `struct` 带注解 / `attr`）、
`entries->program+iface`（收集 struct/块名 → 类型集合）。

策略：先复制，后收敛。**不要**为了消重把控制流抽成"公共骨架"再被 Slang 拖着改；
重复 ~300 行是可接受的成本（决策 3 的落地方式）。

### 2.3 语义差异清单（决定 core 边界的真正依据）

**档 1 · 只影响发射文本，core 完全不用知道**

`vec3→float3`、`mat4→float4x4`、`gl_Position→` 结构体字段 + `SV_Position`、
`layout(binding=0)→[[vk::binding(0,0)]]`、`local_size_x→[numthreads]`、`#version→` 无。

**档 2 · 影响表面语法的形状，core 必须留槽**

① **`uniform` 消失**：`ConstantBuffer<T>` / `ParameterBlock<T>` / `push_constant` 是「块 + 成员」两级，
   现在是平铺 var。→ `shader-var` 需要表达"成员属于哪个块"。
② **类型参数化**：`Texture2D<float4>` / `StructuredBuffer<Light>` / `cbuffer<T>` 无法靠名字前缀猜 kind。
   → `shader-type` 需要 `args`（类型参数列表），kind 由方言目录显式构造。
③ **字段/参数注解**：`(float4 pos SV_Position)`。→ `shader-var` 需要 `annotations` 槽（GLSL 恒为 `'()`）。
④ **函数属性**：`[shader("vertex")]`、`[numthreads(8,8,1)]`。→ 表面语法扩展，不影响数据结构。

**⇒ 对 core 的三条硬要求（必须在提升时就做，不能等 slang 写完再回头改）**

- `shader-type` 加 `args` 槽；
- `shader-var` 加 `annotations`、`owner` 两个槽；
- datum 往返格式一并扩（**datum 形状一变，所有已生成的 shader 代码都要重编**，所以一次到位）。

**档 3 · 语义真不同，同一写法产出不同结果（需拍板）**

| 项 | GLSL | Slang/HLSL | 建议 |
|---|---|---|---|
| `*` | 矩阵乘 | 逐分量 | **见 §6-Q1**（唯一真正棘手的一条） |
| `%` | 仅整数 | 浮点也行（fmod） | 方言各发各的，表里标注 |
| `(xor a b)` | `^^` | 无 `^^`，bool 异或用 `!=` | 方言函数表 |
| `texture(t, uv)` | 全局函数 | `t.Sample(s, uv)`，需显式 sampler | 表面语法必须不同：slang 用 `(sample t s uv)` |
| `atomicAdd` / `barrier` | 全局函数 | `InterlockedAdd` / `GroupMemoryBarrierWithGroupSync` | 方言函数表 |
| 精度限定符 `highp` | 有 | 无 | slang 限定符表不含 |
| 隐式 return | 有（本 DSL 的规则） | Slang 也支持 | **可共用** |
| 一个文件多入口 | 一个 stage | `[shader(…)]` 多入口 | 先不做（interface 按单入口） |

## 3. Step 2：目标结构

```
racket-shader/
  info.rkt                    ; 多 collection 包：shader / shader/glsl / shader/slang
  shader/                     ; ── core ─────────────────────────────
    lang/reader.rkt main.rkt  ; #lang shader（两个宏都给）
    ident.rkt                 ; 别名引擎（表由方言传入）
    type.rkt var.rkt interface.rkt
    program.rkt pretty.rkt emit-util.rkt error.rkt
    value/…                   ; 原 core/value 平铺搬入
  shader/glsl/
    lang/reader.rkt main.rkt  ; #lang glsl
    core.rkt names.rkt rewrite.rkt types.rkt log.rkt
  shader/slang/
    lang/reader.rkt main.rkt  ; #lang slang
    core.rkt names.rkt rewrite.rkt types.rkt attrs.rkt log.rkt
  test/glsl/…  test/slang/…   ; 原 core-test 按方言拆
```

依赖方向硬约束：`shader/glsl` 与 `shader/slang` **互不 require**，都只 require `shader`。

## 4. Step 3：重命名映射（core 层）

| 现名 | 新名 |
|---|---|
| `glsl-program` / `glsl-src` / `glsl-form` | `shader-program` / `shader-src` / `shader-form` |
| `glsl-interface` / `glsl-type` / `glsl-var` | `shader-*` |
| `glsl-pretty` | `shader-pretty` |
| `parse-gl-error-log` / `locate-gl-error` / `render-*` | 解析器进方言层；`locate-error` / `render-*` 进 core |
| `glsl-size` / `glsl-byte-size` / `glsl-kind` / `glsl-stride-bytes` | `shader-*` |
| `glsl-fragment` / `glsl-splice` / `glsl-shader` / `glsl-struct` | `fragment` / `splice` / `shader` / `vertex-struct`（**顶层无前缀**，避免 `shader-` 与包名重复） |
| 方言层：`glsl-name` / `glsl-qualifier-*` / `glsl-type-canonical-name` | 留在方言层，slang 侧叫 `slang-*` |
| 值层 `vec4` / `mat4-mul` / `vadd` / `glsl-struct` 的 CPU 侧 | 不动（两方言共用） |

## 5. 迁移清单

- `study-opengl`：20 个文件 `#lang glsl-opengl`；约 45 处 `glsl-*` API 引用；
  `#lang glsl-opengl` 将变成 `#lang glsl-opengl`（OpenGL 层包同步改名 `racket-shader-opengl`）。
- 现有 shader 里的 `(if …)` 三元（29 处 `(if ` 中需逐条区分是 Racket 层还是 shader 层）
  → 改成三元的新名。
- `racket-glsl-opengl` 的 `core/meta/*`（`glsl-vertex-layout!`、`glsl-uniform-setter!`）依赖
  `glsl-interface` 的 datum 形状 → 随 §2.3 的槽位扩展同步改。

## 6. 已定问题（原待定）

- **Q1 `*` 的矩阵语义 → (a)**：slang 方言 `*` 保持逐分量；跨方言矩阵乘用新的 `(mul a b)`。
  GLSL 方言同时提供 `(mul a b)`（发射 `(a * b)`），于是**同一份 shader 源码在两个方言里都能用 `mul` 表达矩阵乘**。
  `*` 保留各语言原生语义（slang 逐分量 / GLSL 矩阵乘），不做类型推断。
- **Q2 `uniform` 表面形态 → (a)**：显式块，与 Slang 源码 1:1：

  ```racket
  (cbuffer Camera (set 0) (binding 0) (mat4 view) (mat4 proj))
  (param-block Materials (set 1) (binding 0) (sbuffer Material 32 materials))
  (push-const Push (mat4 mvp) (float time))
  ```

  `owner` 槽记录成员属于哪个块，接口表不撒谎（不做"自动打包"的魔法）。
- **Q5 三元名 → `(if-ternary c t e)`**：`(if c t e)` 变成语句 if/else；
  `when` / `unless` / `cond` 保留（它们生成真正的 `if / else if` 链），`(if-ternary …)` 只在表达式位置。

## 7. 进度

- [x] **step 1** 评估（本文 §2）
- [x] **step 2** 结构：`core/` 拆成 `types.rkt` + `value/` + `glsl/`；根 `main.rkt` 改为 `#lang shader`
      （core，只给值层）；语言入口 `#lang shader` / `#lang glsl` 均已实测可用；
      11 个测试全绿（分支 `racket-shader`）。
      ★ 顺带验证：**跨包的子集合可以合并**——A 包提供 `shader/glsl`、B 包提供 `shader/glsl-opengl`
      时两者都能解析（`PLTCOLLECTS` 双根实测），所以 OpenGL 层不必改成扁平名。
- [x] **step 3a** core 数据模型重命名 + 槽位预留
      （`shader-program/form/src/interface/type/var/pretty`、`shader-type-<kind>?`、
      `type-canonical-*`、`shader-error`/`locate-error`/`parse-error-log`；值层 `glsl-*` → `shader-*`、
      `glsl-struct` → `shader-struct`）。槽位一次到位：`shader-type` 加 `args`，
      `shader-var` 加 `annotations` / `owner`。
- [x] **step 3b** core / 方言拆分
      ```
      shader/ident.rkt    别名引擎（表由方言传入）
      shader/type.rkt     类型 + 声明模型（type 与 var 合并：datum 互为递归，拆开会 require 环）
      shader/interface.rkt 接口反射 + datum 往返（并转出 types.rkt 的类型名词汇）
      shader/program.rkt  产物 + 行级源映射
      shader/pretty.rkt   美化（只依赖 emit-util）
      shader/emit-util.rkt 拼装小工具
      shader/error.rkt    定位 + 三视角渲染（render-log / render-source / render-sexpr）
      glsl/types.rkt      类型目录（拼写 → shader-type）
      glsl/log.rkt        日志解析（Mesa 位置格式）
      ```
      ★ Q4 落地方式：`source-name` 不再由 core 调 `glsl-name-symbol` 现算，而是**方言构造
      `shader-var` 时算好存字段**；core 里没有任何方言转换函数。
      ★ 报错层渲染名去掉 `gl-`：`render-gl-linecol/pretty/sexpr` → `render-log/source/sexpr`。
- [x] **step 3c** 语法改造
      `(if c t [e])` = 语句 if/else（`begin` 表多语句）；`(if-ternary c t e)` = 三元；
      `(mul a b)` = 跨方言矩阵乘（GLSL 发 `*`，Slang 发 `mul()`）；
      预处理条件指令改名 `pp-if` / `pp-elif` / `pp-else` / `pp-endif`（否则与语句 `if` 撞名）；
      组合宏改名 `fragment` / `splice` / `shader`（`glsl` 宏保留方言名）。
      新增 7 条控制流断言锁住新语义。
- [x] **step 3d** `slang/` 骨架（目录 `slang/` = 子集合 `shader/slang`）
      `types.rkt`（`float3`/`float4x4` ↔ canonical）· `names.rkt`（语义/修饰符/属性表）·
      `core.rkt`（`[[vk::…]]` / `cbuffer` / 注解 / 特化常量）· `rewrite.rkt`（声明侧 `(slang …)`）·
      `lang/reader.rkt` + `main.rkt`。12 个测试全绿，`#lang slang` 可跑。
      ★ 验收：**core 一行未改**（`git diff HEAD -- shader/ types.rkt value/` 为空），
        三个预留槽（`args` / `annotations` / `owner`）全部被真实用到。
      ★ 当时暂定 `#lang shader` 只给 core；随后按要求**取消 `#lang shader`**，
        改为 `#lang glsl` / `#lang slang` 两个独立集合（见下一条）。
- [ ] **step 4** `shader/slang` 实现：`core.rkt`（原语）/ `rewrite.rkt` / `attrs.rkt`
      （`[[vk::…]]`、`[numthreads]`、`[shader]`）/ 语义注解（`(float4 pos SV-Position)`）/ 日志解析。
- [ ] **包改名**：目录 `racket-glsl` → `racket-shader`，`raco pkg remove racket-glsl` +
      `raco pkg install --link racket-shader`（会连带 `racket-glsl-opengl` 与其依赖声明，
      以及 study-opengl 里 20 个 `#lang glsl-opengl` 头）。
