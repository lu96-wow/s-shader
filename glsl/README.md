# Part 1 · glsl/ —— `(glsl)` 命名空间内：GLSL 语言（特殊、隔离）

这里**只有 GLSL 语言本身的实现**，不掺值层、不掺 OpenGL。
`(glsl ...)` 是**完全编译期变换**：展开期就把 shader 变成 `shader-program` 常量，运行期只重建；
没有运行期求值（无 `glsl-unquote`）。

**本目录只有 GLSL 方言自己的东西**；方言无关的部分在 core（`shader/`）。

| 逻辑 | 文件 | 归属 |
|---|---|---|
| 类型目录（拼写 → `shader-type`） | `types.rkt` | 方言 |
| 标识符别名表（变量 / 函数 / 关键字） | `names.rkt` | 方言 |
| GLSL 字符串原语（layout / #version / 预处理） | `core.rkt` | 方言 |
| 表面语法 → GLSL（`(glsl)` 宏，编译期变换） | `rewrite.rkt` | 方言 |
| 日志解析（Mesa 位置格式） | `log.rkt` | 方言 |
| 类型名词汇表（canonical 名 + 别名） | `../types.rkt` | core |
| 标识符别名**引擎**（camel→kebab / 表构造 / `-`→`_`） | `../shader/ident.rkt` | core |
| 类型 / 声明模型、接口反射 | `../shader/type.rkt`、`../shader/interface.rkt` | core |
| 美化 / 产物 + 源映射 / 报错定位渲染 / 拼装工具 | `../shader/pretty.rkt`、`program.rkt`、`error.rkt`、`emit-util.rkt` | core |

规则：

- 方言**不 require** core 之外的东西（不 require `value/rename-*.rkt`、不 require `opengl/rename.rkt`）。
- 方言**不 require 另一个方言**；core **不 require** 任何方言。
- 「表面名 → 源码里的标识符」在构造 `shader-var` 时算好，存进 `source-name`，core 不需要转换函数。

## 标识符便携层（`names.rkt`）

`(glsl ...)` 里写 Racket 风格名字，生成 GLSL 时在**这一个模块**里转换。
逻辑上按命名空间拆成独立表：

| 表 | 表面 | GLSL |
|---|---|---|
| 用户标识符 | `wow-name-type` / `u-model-view` | `wow_name_type` / `u_model_view` |
| 内建变量 | `gl-position` / `gl_position` | `gl_Position` |
| 内建变量 | `gl-frag-coord` / `gl_frag_coord` | `gl_FragCoord` |
| 内建变量 | `gl-in` | `gl_in` |
| 内建函数 | `texture-size` / `texture_size` | `textureSize` |
| 内建函数 | `d-fdx` / `d_fdx` | `dFdx` |
| qualifier | `read-only` / `write-only` / `in-out` | `readonly` / `writeonly` / `inout` |
| layout key | `early-fragment-tests` / `local-size-x` | `early_fragment_tests` / `local_size_x` |
| 类型（vocab） | `vec-3` / `sampler-2d` / `mat-3x2` | `vec3` / `sampler2D` / `mat3x2` |

提供：

- `glsl-name` / `glsl-name-symbol`：通用标识符 + 内建变量
- `glsl-function-name` / `glsl-function-name-symbol`：内建函数 + 用户函数
- `glsl-qualifier-name` / `glsl-qualifier?`：限定符
- `glsl-layout-key-name` / `glsl-layout-key-symbol`：layout 键
- 各表的 `*-names` / `*-aliases` 查询入口
- 类型别名在 `../types.rkt`：`type-canonical-name/symbol`、
  `type-alias-forms`、`builtin-type?`

**边界**：

- 各表互不串用：变量名不会命中函数别名，函数名不会命中变量别名，关键字只用于
  qualifier/layout key，类型名只用于类型位置。
- 规范拼写永远可用；别名只增加入口。
- 转换结果必须是真正的 GLSL 标识符；`wow?name` 这类名字在展开期报错。
- `rewrite.rkt` 用它生成文本；构造 `shader-var` 时用它填 `source-name`。
  声明反射**保留表面名**（`shader-var-name`），另给 GLSL 名（`shader-var-source-name`），
  避免 Racket 侧 setter/字段对齐与 GL 侧字符串互相污染。
- 类型别名先规范成 canonical 再进 `shader-type`，所以反射里的 `shader-type-name` 永远是
  `vec3` / `sampler2D`，不是 `vec-3` / `sampler-2d`。
- 片段合并的重复定义检测按**归一后的 GLSL 名**比较：`foo-bar` 与 `foo_bar` 冲突。
- 类型名清单/别名表现由 `types.rkt` 共享（见
  [`../../DESIGN.md`](../../DESIGN.md) §8）。
