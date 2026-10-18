# value/ —— Part 2：CPU 值层（`(glsl)` 命名空间外）

「逻辑：GLSL 值的 CPU 侧镜像」。每个逻辑 = **实现（Racket 名）+ `rename-*.rkt`（GLSL 名）** 一对，
共享底座 `cvector.rkt`。不 require 语言层（`glsl/`）、不 require opengl。

| 逻辑 | 实现 | rename（GLSL 名） |
|---|---|---|
| 类型与存储 | `type.rkt` | `rename-type.rkt`：`shader-size` `shader-kind` `shader-byte-size` `shader-stride-bytes` |
| 取用（索引读写） | `access.rkt` | `rename-access.rkt`：`vcount` `vref` `vset!` `vx…vw`、`mat4-ref` `mat4-set!` |
| 构造 | `construct.rkt` | `rename-construct.rkt`：`vec2…bvec4`、`mat2…dmat4` |
| 交错布局 | `layout.rkt` | `rename-layout.rkt`：`shader-struct`（另暴露编译期字段表 `<Name>-fields`） |
| 缓冲 / 拼接 | `buffer.rkt` | `rename-buffer.rkt`：`vec-array`、`concat-vecs`、`u8-array`、`u16-array` |
| 向量运算 | `vec.rkt` | `rename-vec.rkt`：`vadd` `vdot` `vnormalize` … |
| 矩阵运算 | `matrix.rkt` | `rename-matrix.rkt`：`mat4-mul` `mat4-inverse` … |
| 精度转换 | `convert.rkt` | 无（Racket 风格优先） |
| 运行时 cvector 原语 | `cvector.rkt` | 无（非用户 API） |

## 存储类别 kind

| kind | ffi 类型 | GLSL 类型 |
|---|---|---|
| `f32` | `f32vector` | `float/vec*/mat*` |
| `f64` | `f64vector` | `double/dvec*/dmat*` |
| `s32` | `s32vector` | `int/ivec*` |
| `u32` | `u32vector` | `uint/uvec*`、`bool/bvec*`（内存 32 位 0/1） |
| `u16` | `u16vector` | 无（CPU 索引数组 `u16-array`） |
| `u8` | `u8vector`（即 `bytes`） | 无（CPU 像素数组 `u8-array`） |

`type-table` 只收录**有 CPU 表示**的 GLSL 类型；完整类型目录在 `shader/type.rkt` + `glsl/types.rkt`。
类型查询接受别名：`(shader-size 'vec-3)`、`(type-kind 'mat-4)`、`(shader-struct v (vec-3 pos))`
都在 `types.rkt` 里先规范成 canonical（`vec3` / `mat4`）。

## 依赖方向

```
cvector.rkt  ← 所有值层模块
buffer.rkt   ← access.rkt, convert.rkt
access.rkt   ← matrix.rkt
rename-*.rkt → 只 require 对应实现
```

## 命名

- 实现用 Racket 传统名（`vec-add`、`matrix-ref`、`vec-buffer`）——**不随 `#lang shader/glsl` 导出**。
- rename 用 GLSL 名（`vadd`、`mat4-ref`、`vec-array`）——随 `#lang shader/glsl` 导出。
- 取内部存储（零拷贝）用 `X-data`；真正类型转换用 `->type`。
- `shader-struct` 的字段名是 Racket 符号，可直接用连字符（`model-pos`）；
  字段类型也可用别名（`vec-3`），编译期会规范成 canonical 存进 `<Name>-fields`。
- 与 shader `in` 对齐时（opengl 包的 `glsl-vertex-layout!`）按归一后的 GLSL 名比较。

细节见 [`../../DESIGN.md`](../../DESIGN.md)。
