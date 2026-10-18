# 共享词汇 · vocab/ —— GLSL 内建类型名 + 类型别名

这里放**语言层与值层都要用**的纯词汇表，不包含类型解析逻辑、不依赖 `glsl/` 或
`value/`。

| 文件 | 内容 |
|---|---|
| `type-names.rkt` | canonical 内建类型名清单（scalar / vector / matrix / sampler / image）＋ 类型别名表 |

## 为什么单独一层

- `interface.rkt` 需要判断「这是不是内建类型」并构造完整类型模型。
- `value/type.rkt` 需要判断「这个类型有没有 CPU 表示」并查存储属性。
- 两边都必须把 `vec-3` / `sampler-2d` 这类别名先规范成 `vec3` / `sampler2D`。
- 如果别名表放在 `glsl/`，值层就会反向依赖语言层；放在这里则两边都只依赖纯词汇。

## 别名规则

canonical 名永远可用；别名只增加入口：

| 表面 | canonical |
|---|---|
| `vec-3` / `vec_3` | `vec3` |
| `ivec-2` / `ivec_2` | `ivec2` |
| `mat-3x2` / `mat_3x2` | `mat3x2` |
| `dmat-4` / `dmat_4` | `dmat4` |
| `sampler-2d` / `sampler_2d` | `sampler2D` |
| `sampler-2d-array` / `sampler_2d_array` | `sampler2DArray` |
| `isampler-2d` / `isampler_2d` | `isampler2D` |
| `image-2d` / `image_2d` | `image2D` |
| `atomic-uint` | `atomic_uint` |

## API

```racket
(glsl-type-canonical-name 'vec-3)     ; "vec3"
(glsl-type-canonical-symbol 'vec-3)   ; 'vec3
(glsl-type-alias? 'vec-3)             ; #t
(glsl-type-alias? 'vec3)              ; #f
(glsl-builtin-type? 'sampler-2d)      ; #t
glsl-type-alias-forms                 ; ((alias . canonical) ...)
builtin-glsl-type-names               ; canonical symbols
```

## 依赖方向

```
types.rkt  ← glsl/interface.rkt
                           ← value/type.rkt
                           ← glsl/rewrite.rkt（for-syntax）
```

不依赖 `glsl/`、`value/`、`opengl`。
