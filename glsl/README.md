# Part 1 · glsl/ —— `(glsl)` 命名空间内：GLSL 语言（特殊、隔离）

这里**只有 GLSL 语言本身的实现**，不掺值层、不掺 OpenGL。
`(glsl ...)` 是**完全编译期变换**：展开期就把 shader 变成 `shader-program` 常量，运行期只重建；
没有运行期求值（无 `glsl-unquote`）。

| 逻辑 | 文件 | 状态 |
|---|---|---|
| GLSL 字符串原语 | `core.rkt` | ✅ |
| 标识符便携层（变量 / 函数 / 关键字别名） | `names.rkt` | ✅ |
| 共享类型词汇表（内建类型名 + 类型别名） | `../vocab/type-names.rkt` | ✅ |
| 美化 | `pretty.rkt` | ✅ |
| 类型模型 / 接口反射 | `interface.rkt` | ✅ |
| 产物 + 源映射 + datum 往返 | `program.rkt` | ✅ |
| 表面语法 → GLSL（`(glsl)` 宏，编译期变换） | `rewrite.rkt` | ✅ |

规则：

- 不 require `value/rename-*.rkt`；不 require `opengl/rename.rkt`。

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
- 类型别名在 `../vocab/type-names.rkt`：`type-canonical-name/symbol`、
  `type-alias-forms`、`builtin-type?`

**边界**：

- 各表互不串用：变量名不会命中函数别名，函数名不会命中变量别名，关键字只用于
  qualifier/layout key，类型名只用于类型位置。
- 规范拼写永远可用；别名只增加入口。
- 转换结果必须是真正的 GLSL 标识符；`wow?name` 这类名字在展开期报错。
- `rewrite.rkt` 用它生成文本；`interface.rkt` 用它派生 `shader-var-source-name`。
  声明反射**保留表面名**（`shader-var-name`），另给 GLSL 名（`shader-var-source-name`），
  避免 Racket 侧 setter/字段对齐与 GL 侧字符串互相污染。
- 类型别名先规范成 canonical 再进 `shader-type`，所以反射里的 `shader-type-name` 永远是
  `vec3` / `sampler2D`，不是 `vec-3` / `sampler-2d`。
- 片段合并的重复定义检测按**归一后的 GLSL 名**比较：`foo-bar` 与 `foo_bar` 冲突。
- 类型名清单/别名表现由 `types.rkt` 共享（见
  [`../../DESIGN.md`](../../DESIGN.md) §8）。
