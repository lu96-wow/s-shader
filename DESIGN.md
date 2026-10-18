# racket-glsl · 设计与逻辑分层

本包 = **Part 1（GLSL 语言）+ Part 2（CPU 值层）+ 报错层**。包边界即依赖边界：
**不依赖 `opengl`**，所以 `#lang shader/glsl` / `(require shader/glsl)` 永远不会拉进 OpenGL。

（OpenGL 侧在独立包 `racket-glsl-opengl` 中，不属于本仓库。）

---

## 1. 两条切分轴

### 轴 A：命名空间在不在 `(glsl)` 里

| | 谁 | 例子 | 归属 |
|---|---|---|---|
| `(glsl)` 内 | 宏认识的 GLSL 表面词汇 | `(uniform mat4 uMVP)`、`(vec4 a 1.0)`、`set!` | Part 1 |
| `(glsl)` 外 | 普通 Racket 代码里的 API | `(vec3 1.0 2.0 3.0)`、`vadd` | Part 2 |

**同名不同物**：`vec4` 在宏内是「类型 → 文本」，在宏外是 `f32vector` 构造。两边两套绑定，互不 require。

### 轴 B：实现名 ↔ GLSL 名（Part 2 的 rename）

值层每个逻辑 = **实现（Racket 名）+ `rename-*.rkt`（GLSL 名）** 一对。

---

## 2. Part 1 · `glsl/` —— `(glsl)` 命名空间内

数据流（**完全在编译期**）：

```
(glsl ...) 展开期：
  │ rewrite.rkt：syntax->datum
  │ rewrite.rkt：rw-top/rw-stmt/rw-expr/rw-decl/rw-fn（直接调用 glsl-* 原语）
  ▼ 字符串片段（无换行；预处理指令带 \n）
  │ program.rkt：make-shader-program → shader-pretty + 行级源映射 + 接口反射
  ▼ shader-program 值（编译期常量）
  │ 生成代码
  ▼ (datum->shader-program '<program-datum>)   —— 运行期只重建、无逻辑
```

| 逻辑 | 文件 | 约束 |
|---|---|---|
| （core）类型名词汇表 | `types.rkt` | canonical 类型名 + 类型别名；语言层与值层共享 |
| （core）标识符别名引擎 | `shader/ident.rkt` | camel→kebab、别名表构造、`-`→`_`；**表由方言传入** |
| （core）类型 / 声明模型 | `shader/type.rkt` | `shader-type` / `shader-var`；只读、不组合 |
| （core）接口反射 | `shader/interface.rkt` | 按名字/限定符/kind 查询 + datum 往返 |
| （core）美化 | `shader/pretty.rkt` | 纯函数；按 `; { } ( )` 换行缩进；行首 `#` 整行原样 |
| （core）产物 + 源映射 | `shader/program.rkt` | 源映射只到**行**；行区间由各 form 美化行数累计；datum 往返 |
| （core）报错定位 / 渲染 | `shader/error.rkt` | 行级定位 + 三视角渲染；日志解析在方言层 |
| （core）拼装小工具 | `shader/emit-util.rkt` | `->str` / `wrap-block` / `quals->prefix` … |
| （方言）类型目录 | `glsl/types.rkt` | 拼写 → `shader-type`（Slang 另有一份） |
| （方言）标识符表 | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | 变量 / 函数 / 关键字别名；四张表分开 |
| （方言）字符串原语 | `glsl/core.rkt` | 全返回字符串、不含换行；预处理指令例外 |
| （方言）表面语法 | `glsl/rewrite.rkt` | **完全编译期变换**；无运行期求值 |
| （方言）日志解析 | `glsl/log.rkt` | 位置格式是编译器相关的，每方言一个 |

**core / 方言的边界**（唯一允许的依赖方向）：

```
types.rkt  value/          ← 两方言共用（CPU 值层与类型名词汇）
shader/                    ← core：模型、反射、产物、美化、报错
glsl/  slang/              ← 方言：类型目录 + 标识符表 + 原语 + 表面语法 + 日志解析
```

方言**不得** require 另一个方言；core **不得** require 任何方言。
「表面名 → 源码里的标识符」由方言在构造 `shader-var` 时算好存进 `source-name` 字段，
core 因此不需要任何转换函数。

几个关键点：
- **全部在编译期**：重写、美化、行映射、接口反射都在展开期完成；产物是编译期常量，
  运行期仅 `datum->shader-program` 重建。
- **没有运行期求值**：`glsl-unquote` 已移除；动态 shader 走 opengl 包的 `shader-compile`（裸字符串）。
- 不 require `value/`、不 require `opengl/`。

### 2.1 标识符 / 类型名便携层

表面（Racket）与 GLSL 的**标识符拼写**不同，但语义是同一个名字。转换按命名空间**分表**：

| 表 | 文件 | 表面写法 → GLSL 文本 |
|---|---|---|
| 用户标识符 | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | `wow-name-type` → `wow_name_type` |
| 内建变量 | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | `gl-position` / `gl_position` → `gl_Position`；`gl-in` → `gl_in` |
| 内建函数 | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | `texture-size` / `texture_size` → `textureSize`；`d-fdx` → `dFdx` |
| 关键字（qualifier） | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | `read-only` → `readonly`；`no-perspective` → `noperspective`；`in-out` → `inout` |
| 关键字（layout key） | `glsl/names.rkt`（机制在 `shader/ident.rkt`） | `early-fragment-tests` → `early_fragment_tests`；`local-size-x` → `local_size_x` |
| 内建类型 | `types.rkt` | `vec-3` / `vec_3` → `vec3`；`sampler-2d` → `sampler2D`；`mat-3x2` → `mat3x2` |

- **表互不串用**：变量名不会命中函数别名，函数名不会命中变量别名；关键字只用于
  qualifier/layout key；类型名只用于类型位置。
- **规范拼写永远可用**：`gl_Position`、`textureSize`、`readonly`、`vec3` 原样通过。
- **用户标识符兜底**：未命中任何表的符号走通用 `-`→`_`（struct/block 名、字段、普通变量…）。
- **校验**：转换结果必须是 `[A-Za-z_][A-Za-z0-9_]*`，否则展开期报错。
- **类型别名先规范再反射**：`builtin-type-of` 接收别名，但 `shader-type-name` 永远是 canonical
  （`vec3` / `sampler2D`），这样接口反射、CPU 类型表、uniform setter 用同一套键。
- **单一来源**：`rewrite.rkt` 生成文本用它；`interface.rkt` 的 `shader-var-source-name` 也用它。
  这样不会出现「声明写成 `u_model_view`、反射却报 `u-model-view`」的漂移。

#### 两个身份：表面名 vs GLSL 名

`shader-var` **保留表面名**（`shader-var-name`），并派生 GLSL 名（`shader-var-source-name`）：

- 表面名用于 Racket 侧：生成 setter 名（`set-u-model-view!`）、与 CPU `shader-struct` 字段对齐、
  错误信息、编译期表。
- GLSL 名用于和 GL 驱动/文本打交道：`uniform-location`、shader 源码、内建变量。
- `shader-interface-ref` 同时接受两种拼写；`shader-var-layout-ref` 的 layout 键也同时接受两种。
- CPU `shader-struct` 的字段类型在编译期规范成 canonical，所以 `<Name>-fields` 里存 `vec3`，
  而不是用户写的 `vec-3`。

细节见 [`glsl/README.md`](glsl/README.md) 与
[`types.md`](types.md)。

---

## 3. Part 2 · `value/` —— `(glsl)` 命名空间外

每逻辑一对「实现 + rename」；共享底座 `cvector.rkt`。

| 逻辑 | 实现（Racket 名） | rename（GLSL 名） |
|---|---|---|
| 类型与存储 | `type.rkt` | `rename-type.rkt`：`shader-size/kind/byte-size/stride…` |
| 取用 | `access.rkt` | `rename-access.rkt`：`vcount/vref/vset!/vx…vw`、`mat4-ref/set!` |
| 构造 | `construct.rkt` | `rename-construct.rkt`：`vec2…bvec4 / mat2…dmat4`，以及 `vec-3 / mat-4` 别名 |
| 交错布局 | `layout.rkt` | `rename-layout.rkt`：`shader-struct` |
| 缓冲 / 拼接 | `buffer.rkt` | `rename-buffer.rkt`：`vec-array`、`concat-vecs`、`u8-array`、`u16-array` |
| 向量运算 | `vec.rkt` | `rename-vec.rkt`：`vadd/vdot/…` |
| 矩阵运算 | `matrix.rkt` | `rename-matrix.rkt`：`mat4-mul/…` |
| 精度转换 | `convert.rkt` | 无（CPU 侧 Racket 风格优先） |
| 底座 | `cvector.rkt` | 无（非用户 API） |

数值方向的流水线：

```
(vec4 …) ──rename-construct──▶ make-f32-vec ──construct──▶ 裸 f32vector
裸 cvector ──value-kind──▶ kind ──kind-length/ref/set!──▶ 分量读写
```

**依赖方向**：`cvector.rkt ← 所有值层模块`；`buffer.rkt ← access.rkt, convert.rkt`；
`access.rkt ← matrix.rkt`；`rename-*.rkt → 只依赖对应实现`。

值层 Racket 风格名（`vec-add` / `matrix-ref` …）**不随 `#lang shader/glsl` 导出**；需要时直接
`(require glsl/value/vec)` 等。

细节见 [`value/README.md`](value/README.md)。

---

## 4. 报错层 · `shader/error.rkt`（定位/渲染）+ `glsl/log.rkt`（解析）

编译报错的**解析 / 定位 / 渲染**留在纯包（不碰 opengl，便于离线复用）：

| 函数 | 作用 |
|---|---|
| `parse-shader-error-log` | 原始日志 → `shader-error` 列表 |
| `locate-shader-error` | GLSL 行 → 覆盖它的顶层 form（**行级**） |
| `render-error` | 三段式文本（GL 日志 / 美化 GLSL + 报错行 / 源文件对应行） |

触发与抛异常在 opengl 包的 `shader-compile`。

---

## 5. 命名归属（本包相关部分）

| 名字形态 | 归属 | 例子 |
|---|---|---|
| 裸名 / `?` / `!` / `->` | Racket / `racket/base`（**不遮蔽**） | `length`、`set!`、`exact->inexact` |
| `glsl-*` | 本 DSL 的语言层概念 | `shader-size`、`shader-struct`、`shader-program`、`shader-interface`、`glsl-name`、`glsl-function-name`、`glsl-qualifier-name`、`glsl-layout-key-name`、`type-canonical-name` |
| `vecN`/`dvecN`/`ivecN`/`uvecN`/`bvecN`、`matN`/`dmatN` | GLSL 类型构造器 | `vec3`、`mat4`、`dvec3` |
| `v*` | 向量取用 / 运算 | `vx`、`vref`、`vadd`、`vdot` |
| `matN-*` | 矩阵取用 / 运算 | `mat4-ref`、`mat4-mul` |
| `vec-array*` / `dvec-array*` / `ivec-array*` / `uvec-array*` | CPU 向量数组类型 | `vec-array`、`vec-array-ref` |
| `u8-array*` / `u16-array*` | CPU 标量数组（GLSL 无此类型） | `u16-array`、`u8-array` |
| `->X` | Racket 风格转换 | `->f32vector`、`->u16vector` |

规则要点：`glsl-*` 只给语言/布局/类型概念；不遮蔽 base（所以 `length`→`vlength`、
`abs`→`vabs`）；能推导的形状不进名字（向量宽度），不能推导的进名字（矩阵阶 `mat4-*`）；
取内部存储（零拷贝）用 `X-data`，真正转换用 `->type`。
（OpenGL 的 `gl-*` 规则见 opengl 包。）

---

## 6. 翻译层次总结

| 步 | 所在 | 输入 → 输出 |
|---|---|---|
| 1 | `rewrite.rkt` | surface `(glsl …)` → surface datum |
| 2 | `rewrite.rkt` + `names.rkt` | surface datum → core datum（标识符先归一，再走 `glsl-*` 调用） |
| 3 | `core.rkt` | core datum（求值）→ GLSL 字符串片段 |
| 4 | `pretty.rkt` | 片段 → 多行缩进文本 |
| 5 | `program.rkt` | 片段+源信息+接口 → `shader-program` |

类型信息：`interface.rkt`（完整 GLSL 类型目录 + 声明反射，展开期算好）
→ `program.rkt`（quote 进代码，运行期重建）→ `error.rkt`（用行级源映射定位）。

---

## 7. `vec4` 的多重身份（示例：同名不同物）

| 层 | 形式 | 含义 |
|---|---|---|
| ① surface | `(uniform vec4 v)` / `(vec4 a 1.0)` | datum 符号，宏按**类型名清单**匹配 |
| ② core 原语 | `(glsl-decl '("uniform") "vec4" "v")` / `(glsl-ctor "vec4" a 1.0)` | 参数是字符串 |
| ③ 文本 | `uniform vec4 v;` / `vec4(a, 1.0)` | 字符串 |
| ④ 类型模型 | `builtin-type-of 'vec4` | `shader-type`：vector / vec4 / base float / dims (4) / size 16 |
| ⑤ 存储属性 | `type-entry 'vec4` | `(vec4 4 f32)`，`type-byte-size` = 16 |
| ⑥ CPU 构造器 | `(vec4 1.0 2.0 3.0 1.0)` | `make-f32-vec` → 裸 `f32vector` |

机制：宏在 `syntax->datum` 之后看符号名是否是内建类型（canonical 或别名），
**不解析 `vec4` 的绑定** —— 所以 ① 和 ⑥ 互不干扰。`vec-3` 是同一机制的别名入口。

---

## 8. 唯一共享点：GLSL 类型词汇表

`(glsl)` 内要判断「这是不是类型」，值层要判断「有没有 CPU 表示」。
现在 canonical 类型名清单放在共享模块 `types.rkt`：

- `types.rkt`：**完整 canonical 类型名清单** + 类型别名表
  （`vec-3` → `vec3`、`sampler-2d` → `sampler2D` …）。
- `shader/type.rkt`：**完整**类型模型（scalar/vector/matrix/sampler/image/…）；
  输入别名先规范成 canonical。
- `value/type.rkt`：**CPU 可表示子集** + 存储属性（f32/f64/s32/u32/u16/u8）；
  输入别名先规范成 canonical。

这样类型别名只有一张表，语言层和值层不会各自维护一份。新增内建类型时：
更新 `types.rkt` 的 canonical 清单（别名自动生成），再按需更新
`interface.rkt` 的类型解析 / `value/type.rkt` 的 CPU 子集。

---

## 9. 测试

```bash
raco test core-test   # 无需显示器
```

覆盖：表面语法重写、标识符便携层（连字符 / 内建变量别名）、字符串原语、美化、接口反射、报错定位、向量构造/布局/运算、
向量与矩阵运算、u8/u16 标量数组、控制流嵌套、`#lang shader/glsl` 顶层入口。

---

## 10. 片段组合与编译期表（已实现）

让 GLSL 片段能**递归组合**、复用样板——在 **surface 级拼接**（重写之前）、共享词表与 interface。
已实现 `glsl-fragment`（定义片段）+ `glsl-splice`（拼接）+ `glsl-shader`（定义 shader 并暴露编译期接口表）；
数据载体为纯数据 entry（`(datum source)`）。

```racket
(glsl-fragment lighting (struct Light (vec3 position) (vec3 color)) (uniform Light uLight))
(glsl (version 330 core) (glsl-splice lighting) …)
```

编译期表可用于宏代码生成（见 opengl 包 `core/meta/`）。详见 [COMPOSITION.md](COMPOSITION.md)。
