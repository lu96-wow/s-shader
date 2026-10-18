# racket-glsl —— 纯 GLSL DSL

`#lang shader/glsl`（collection `glsl`）：在 Racket 里**写 GLSL 文本、造/算 GLSL 值、反射 shader 接口、
渲染编译报错**。本包**不依赖、也不含 OpenGL**。

- 只优化「在 Racket 里使用 GLSL」这件事。
- GL 对象/状态/窗口，以及 shader 的编译/链接，属于另一个独立包 `racket-glsl-opengl`
  （`#lang glsl-opengl`），它单向依赖本包。

设计与逻辑分层见 [DESIGN.md](DESIGN.md)。

## 安装

```bash
raco pkg install --link .
```

依赖 `base`（测试另需 `rackunit-lib`）。两个入口：

- **`#lang shader/glsl`** —— 普通 Racket 模块，预置本包全部名字（语言层 + CPU 值层 + 报错层）。
- **`(require shader/glsl)`** —— 在 `#lang racket/base` 里使用，等价。

## 快速开始

```racket
#lang glsl

(define vert
  (glsl (version 330 core)
        (layout (location 0) in vec3 aPos)
        (layout (location 1) in vec3 aColor)
        (uniform mat4 uMVP)
        (out vec3 vColor)
        (define (main) void
          (set! vColor aColor)
          (set! gl_Position (* uMVP (vec4 aPos 1.0))))))

;; 看生成的 GLSL
(displayln (shader-program-src vert))

;; CPU 侧用同名类型算矩阵，不碰裸 ffi
(define M (mat4 1.0 0.0 0.0 0.0
               0.0 1.0 0.0 0.0
               0.0 0.0 1.0 0.0
               0.0 0.0 0.0 1.0))
(define p (mat4-mul-vec M (vec4 1.0 2.0 3.0 1.0)))
```

生成文本：

```
#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
uniform mat4 uMVP;
out vec3 vColor;
void main() {
  vColor = aColor;
  gl_Position = (uMVP * vec4(aPos, 1.0));
}
```

## 语法参考（`(glsl form ...)`）

`(glsl form ...)` 里每个顶层 form 是一条 GLSL 声明/定义；表面是 S 表达式，语义是 GLSL。

### 变量

```racket
;; 顶层声明：限定符... 类型 名字 [初值]
(in vec2 vUV)
(out vec4 FragColor)
(uniform float uTime)
(const float PI 3.14159)
(flat in vec3 vNormal)
(layout (location 0) in vec2 aPos)                 ; layout(location = 0) in vec2 aPos;
(layout (std140) (binding 0) uniform Camera cam)

;; 函数体内局部变量
(vec2 p (- (* vUV 2.0) 1.0))                       ; vec2 p = ((vUV * 2.0) - 1.0);
(float d (length p))
```

- 声明**只支持单变量**。
- 数组类型 `(array 内层 [大小])`：`(in (array vec3 4) aPos)` → `in vec3[4] aPos;`。
- 接口块 `(block 名字 (字段类型 字段名) ...)`：`(uniform (block Camera (mat4 view) (mat4 proj)) cam)`。

### 标识符：连字符与内建变量别名

在 `(glsl ...)` 内可以用 Racket 风格的连字符标识符；生成 GLSL 时自动转成 `_`：

```racket
(uniform mat4 u-model-view)          ; uniform mat4 u_model_view;
(in vec3 a-pos)                      ; in vec3 a_pos;
(out (block V-Data (vec3 normal-vec)) vs-out)
(struct My-Light (vec3 light-pos))   ; struct My_Light { vec3 light_pos; };
(define (my-func (float a-b)) float (* a-b 2.0))   ; float my_func(float a_b) { … }
(set! (.light-pos l) (vec3 1.0))     ; l.light_pos = vec3(1.0);
```

其余命名空间各有**独立的别名表**（互不串用）：

```racket
;; 内建变量：kebab / 全小写下划线
(set! gl-position  …)   ; gl_Position
(set! gl_position  …)   ; gl_Position
(set! gl-frag-depth …)  ; gl_FragDepth
(aref gl-in i)          ; gl_in[i]
(.gl-position …)        ; ….gl_Position

;; 内建函数：camelCase → kebab / snake
(texture-size u-tex 0)  ; textureSize(u_tex, 0)
(texture_size u-tex 0)  ; textureSize(u_tex, 0)
(d-fdx v-uv)            ; dFdx(v_uv)
(find-lsb x)            ; findLSB(x)

;; 关键字：qualifier / layout key
(read-only uniform image2D img)       ; readonly uniform image2D img;
(define (f (in-out vec3 p)) void)     ; void f(inout vec3 p) { … }
(layout (early-fragment-tests) in)    ; layout(early_fragment_tests) in;
(layout (local-size-x 8) (local-size-y 8) in)
                                      ; layout(local_size_x = 8, local_size_y = 8) in;

;; 内建类型（共享类型词汇表）
(uniform vec-3 u-color)               ; uniform vec3 u_color;
(uniform sampler-2d u-tex)            ; uniform sampler2D u_tex;
(vec-3 1.0 2.0 3.0)                   ; vec3(1.0, 2.0, 3.0)
```

- 规范拼写（`gl_Position`、`textureSize`、`readonly`、`vec3`、`u_model_view`）仍然可用，向后兼容。
- **四张表分开定义**：
  - 变量表：`glsl-builtin-variable-names` / `glsl-builtin-variable-aliases`
  - 函数表：`glsl-builtin-function-names` / `glsl-builtin-function-aliases`
  - 关键字表：`glsl-qualifier-*`（qualifier）与 `glsl-layout-key-*`（layout key）
  - 类型表：`types.rkt` 的 `type-alias-forms` / `type-canonical-name`
- 用户标识符走通用 `-`→`_`；函数名/变量名/关键字/类型名不会误命中彼此的表。
- 类型别名也在 CPU 侧生效：`(vec-3 …)`、`(shader-size 'vec-3)`、`(shader-struct v (vec-3 pos))`；
  反射里的类型名统一是 canonical（`vec3` / `sampler2D`）。
- 编译期反射保留**表面名**（`shader-var-name`），同时提供 **GLSL 名**（`shader-var-source-name`）；
  `shader-interface-ref` 两种拼写都接受。Racket 侧生成的 setter / 字段对齐用表面名，
  和 GL 驱动打交道的 `uniform-location` 用 GLSL 名。
- `foo-bar` 与 `foo_bar` 归一后同名，片段合并时会报冲突。
- `raw` 是逃生舱：里面是原始 token，**不**做连字符转换（宏体用字符串时也一样）。
- 手工和 GL 驱动打交道时（如 `uniform-location`）要传 **GLSL 名**：
  `(uniform-location prog (glsl-name 'u-model-view))` 或直接写 `"u_model_view"`。

### 运算符

| Racket 写法 | GLSL |
|---|---|
| `(+ a b)` `(- a b)` `(* a b)` `(/ a b)` `(% a b)` | `+ - * / %` |
| `(<< a b)` `(>> a b)` | `<< >>` |
| `(< a b)` `(<= a b)` `(> a b)` `(>= a b)` `(= a b)` `(!= a b)` | `< <= > >= == !=` |
| `(and a b)` `(or a b)` `(xor a b)` | `&& \|\| ^^` |
| `(bit-and a b)` `(bit-or a b)` `(bit-xor a b)` `(bit-not a)` | `& \| ^ ~` |
| `(not a)` / `(! a)` | `!` |
| `(- a)` `(+ a)` | 一元 `-` / `+` |
| `(if-ternary c t e)` | 三元 `c ? t : e`（**表达式位置**） |
| `(mul a b)` | 矩阵乘：GLSL 发 `(a * b)`（Slang 发 `mul(a, b)`） |
| `#t` / `#f` | `true` / `false` |

- 赋值：`(set! x v)`、复合 `(+= x v)`（左值在前）、`(++ i)` / `(-- i)`。
- 取值：`(x v)` / `(xyz v)`（swizzle，字母限 `xyzw`/`rgba`/`stpq`，长 1–4）、
  `(.view cam)`（字段）、`(aref a i)`（下标）。
- 数字直接写 Racket 数；**不接受有理数字面量**（写 `0.5`，不要 `1/2`）。
- `(raw "任意 token")` 原样插入。

### 控制流

```racket
(when (> a 0.5) (set! x a))            ; if (...) { ... }
(unless done (break))
(cond [(= a 1) (set! c a)] [(= a 2) (set! c b)] [else (set! c z)])
(for (int i 0) (< i 8) (++ i) (set! x (+ x i)))
(while (< i n) (++ i))
(do-while (< i n) (++ i) (set! s (+ s i)))
(switch mode [case 1 (set! c a)] [case 2 (set! c b)] [default (set! c z)])
(break) (continue) (return) (return v) (discard)
```

> `(if c then [else])` 是**语句**（Racket 两分支 if）；多语句用 `(begin ...)`。
> **表达式**位置的三元是 `(if-ternary c t e)`；`when` / `unless` / `cond` 是语句糖。
> `for` 的 init 必须是单个声明 `(int i 0)`。

### 函数

```racket
(define (main) void (set! gl_Position (vec4 0.0 0.0 0.0 1.0)))
(define (sq (float x)) float (* x x))          ; 函数体最后一个表达式自动作 return
(define (f (inout vec3 p)) void (return (+ (x p) 1.0)))
```

参数可带 `in` / `out` / `inout`；返回类型写在参数表后面。

### 结构

```racket
(struct Light (vec3 pos) (float i))            ; struct Light { vec3 pos; float i; };
```

### 预处理指令

```racket
(define-macro FOO 1)                           ; #define FOO 1
(define-macro (ADD a b) (+ a b))               ; #define ADD(a, b) (a + b)
(ifdef FOO) (pp-else) (pp-endif)
(pp-if 1) (pp-elif 0) (pp-else) (pp-endif)
(undef BAR) (error "unsupported")
(pragma "STDGL invariant(all)")
(extension GL_OES_standard_derivatives enable)
```

指令在顶层和函数体内都可以用。条件指令带 `pp-` 前缀（`pp-if`/`pp-elif`/`pp-else`/`pp-endif`），
以免和语句位置的 `(if ...)` 撞名。

### 动态 shader：完全编译期，无运行期插值

`(glsl ...)` 是**完全编译期**变换：展开期就把 shader 定下来，运行期只是重建产物。因此
**没有** `glsl-unquote` 之类的运行期插值口。需要按运行期数据造 shader 时，请在 Racket 里
拼出**整段 GLSL 字符串**，交给 `racket-glsl-opengl` 的 `shader-compile`（它接受裸字符串）。

> 想在**编译期**复用静态 GLSL 片段（并保留 interface/源映射）时，见下节。

### 片段复用：`fragment` / `splice`

把样板 GLSL 定义一次、多处复用；**拼接在重写之前的 surface 级**，所以词表与 interface 都保持一致。

```racket
;; 定义可复用片段（编译期；可嵌套 splice）
(fragment lighting
  (struct Light (vec3 position) (vec3 color))
  (uniform Light uLight)
  (define (lambert (vec3 n) (vec3 l)) float (max (dot n l) 0.0)))

;; 组合
(define shader
  (glsl (version 330 core)
        (splice lighting)        ; ← 拼接（只能在 (glsl ...) / fragment 顶层）
        (uniform vec3 uEye)
        (in vec3 aPos)
        (define (main) void (set! gl_Position (vec4 aPos 1.0)))))
```

- 片段可**递归**（片段内 `(splice …)` 另一个片段）；
- **词表共享**：片段定义的 `struct` 在合并后可见；
- **interface 合并**：`shader-program-interface` 含所有片段声明的 uniform/in/out；
- **报错指向片段定义处**；
- 重名（`struct` / 函数 / 顶层变量）在**编译期报错**。

> 这是**编译期**拼接，不是运行期；运行期变化仍走 `shader-compile` 字符串。
> 完整设计（能力边界、数据载体、机制）见 [COMPOSITION.md](COMPOSITION.md)。

### 编译期表：`shader`

`(shader name form ...)` 与 `(glsl ...)` 一样在编译期产出 shader，**并额外把编译期接口表绑为 `<name>-interface`**（一个宏，展开为 `(quote <iface-datum>)`）。

```racket
(shader vert
  (version 330 core)
  (layout (location 0) in vec3 aPos)
  (uniform mat4 uMVP))
;; 运行期：vert 是 shader-program；编译期：vert-interface 是接口表（供宏消费）
```

`shader-struct` 同样把 CPU 字段表绑为 `<Name>-fields`：

```racket
(shader-struct vertex (vec3 pos) (vec3 normal) (vec2 uv))
(vertex-fields)   ; => ((pos vec3) (normal vec3) (uv vec2))
```

这两张表使「宏在编译期读着表生成 GL 代码」成为可能（如 `racket-glsl-opengl` 的 `glsl-vertex-layout!`）。

## CPU 侧 API

CPU 侧 GLSL 值就是真正的 `ffi/vector`（零拷贝、可直接上传）：`vec3` 是 `f32vector`、`dvec3` 是 `f64vector`，以此类推。

### 构造

```racket
(vec3 1.0 2.0 3.0) (dvec3 1.0 2.0 3.0) (ivec2 1 2) (uvec2 1 2) (bvec3 #t #f #t)
(vec-3 1.0 2.0 3.0)       ; 同 vec3（Racket 风格别名）
(mat4 2.0)                ; 对角矩阵
(mat-4 2.0)               ; 同 mat4
(mat4 c0 c1 c2 c3)        ; 4 个列向量
(mat4 16 个标量)          ; 列主序
(concat-vecs (vec2 ..) (vec2 ..))
```

### 取用 / 运算

```racket
;; 分量
(vx v) (vy v) (vz v) (vw v) (vref v i) (vset! v i x) (vcount v)
;; 逐分量 / 几何 / 位运算
(vadd a b) (vsub a b) (vmul a b) (vdiv a b) (vneg v) (vabs v) (vmin v 0.0) (vmax v 1.0)
(vdot a b) (vcross a b) (vlength v) (vdistance a b) (vnormalize v)
(vmix a b t) (vclamp v lo hi) (vstep e x) (vsmoothstep e0 e1 x)
(vreflect i n) (vrefract i n eta)
(vand a b) (vor a b) (vxor a b) (vnot v) (vshl v n) (vshr v n)
;; 矩阵（mat2/3/4 与 dmat2/3/4）
(mat4-ref m col row) (mat4-set! m col row x) (mat4-identity)
(mat4-mul A B) (mat4-mul-vec M v) (mat4-vec-mul v M)
(mat4-add A B) (mat4-sub A B) (mat4-transpose M) (mat4-inverse M) (mat4-mul-scalar M s)
;; 转换
(->f32vector x) (->f64vector x) (->s32vector x) (->u32vector x) (->u16vector x) (->u8vector x)
```

规则：**同类进同类出**，跨精度/跨类报错（不做隐式提升）；向量宽度由长度自动得到；
矩阵阶写进名字（`mat4-*`）；运算返回新值，`*set!` 原地写。

### 顶点布局（`shader-struct`）

把 shader 里的 `struct` 镜像到 CPU 侧，自动给 stride / offset / size：

```racket
(shader-struct vertex (vec3 pos) (vec3 color))
(define v0 (vertex (vec3 1.0 2.0 3.0) (vec3 1.0 0.0 0.0)))
(vertex->f32vector v0)        ; 铺平成 f32vector（喂 VBO）
(vertex-stride)               ; 24
(vertex-field-offset 'color)  ; 12
(vertex-field-size 'pos)      ; 3（分量数）
```

尺寸辅助：

```racket
(shader-size 'vec3)                 ; 3
(shader-byte-size 'vec3)            ; 12
(shader-stride-bytes 'vec3 'vec2)   ; 20
(shader-kind 'dvec3)                ; f64
```

### 向量数组与标量数组

```racket
;; 同宽度向量的数组（GLSL vec3[N]）；按元素类型分名
(vec-array (vec2 -0.5 -0.5) (vec2 0.5 -0.5) (vec2 0.0 0.5))  ; f32
(make-vec-array 1000 (vec3 0.0 0.0 0.0))                     ; 预分配
(vec-array-count gv) (vec-array-width gv) (vec-array-ref gv i) (vec-array-set! gv i v)
(vec-array-data gv)                                          ; 零拷贝内部缓冲
;; dvec-array=f64、ivec-array=s32、uvec-array=u32

;; u8/u16 标量数组（GLSL 无此类型；索引 / 像素）
(u16-array 0 1 2) (make-u16-array n 0) (u16-array-ref a i) (u16-array-set! a i v)
(u8-array 255) (make-u8-array n 255) (u8-array-ref a i) (u8-array-set! a i v)
```

## 接口反射

`(glsl ...)` 的产物是 `shader-program`，带类型化的接口信息和源映射。

```racket
(define ifc (shader-program-interface shader))
(shader-interface-vars ifc)                            ; 全部声明
(shader-interface-vars-with-qualifier ifc 'uniform)    ; 按限定符
(shader-interface-vars-with-kind ifc 'sampler)         ; 按类型 kind
(shader-interface-ref ifc 'uMVP)                       ; 按名字
(shader-var-name v) (shader-var-source-name v)               ; 表面名 / 实际 GLSL 名
(shader-var-type v) (shader-var-qualifiers v) (shader-var-layout v)
(shader-type-name t) (shader-type-kind t) (shader-type-size t) (shader-type-fields t)
```

`shader-interface` 是**只读**的：提供类型数据，不生成 setter、不合并多个 shader。

## 报错层（纯函数）

编译报错的解析 / 定位 / 渲染在本包（不碰 opengl，便于离线复用）：

```racket
;; core（方言无关）：定位 + 三个视角的渲染
(locate-error src err)           ; 源码行 → 覆盖它的顶层 form（行级）
(render-log log) (render-source src located) (render-sexpr located)
(render-error log src located)   ; 三段式文本

;; 方言层：日志格式解析
(parse-error-log log)            ; GLSL 方言（glsl/log.rkt）：原始日志 → shader-error 列表
```

真正的编译触发与抛异常在 `racket-glsl-opengl` 的 `shader-compile`。

## 分层与文件

```
（仓库根 = 包根，collection: shader）
  main.rkt                  #lang shader：core（值层 + 类型模型 + 产物 + 报错）
  lang/reader.rkt
  types.rkt                 类型名词汇表（canonical 名 + 别名；语言层与值层共享）
  shader/                   ── core：方言无关 ──────────────────────
    ident.rkt               标识符别名引擎（表由方言传入）
    type.rkt                类型 / 声明模型（shader-type / shader-var）
    interface.rkt           接口反射 + datum 往返
    program.rkt             产物 + 行级源映射
    pretty.rkt              文本美化
    emit-util.rkt           字符串拼装小工具
    error.rkt               报错定位 / 渲染
  glsl/                     ── GLSL 方言（#lang shader/glsl）────────
    main.rkt  lang/reader.rkt
    types.rkt               类型目录：拼写 → shader-type
    names.rkt               标识符别名表（变量/函数/关键字，四张表分开）
    core.rkt                字符串原语（layout / #version / 预处理 …）
    rewrite.rkt             (glsl ...) 宏：表面语法 → 原语
    log.rkt                 驱动日志 → shader-error
  value/                    ── CPU 值层（两方言共用）─────────────
    type.rkt / rename-type.rkt           类型与存储
    access.rkt / rename-access.rkt       取用
    construct.rkt / rename-construct.rkt 构造
    layout.rkt / rename-layout.rkt       交错布局 / shader-struct
    buffer.rkt / rename-buffer.rkt       缓冲 / 向量数组 / u8,u16 数组
    vec.rkt / rename-vec.rkt             向量运算
    matrix.rkt / rename-matrix.rkt       矩阵运算
    convert.rkt                          精度转换
    cvector.rkt                          内部底座（无 rename）
  test/                     测试（无需显示器）
```

细节见 [DESIGN.md](DESIGN.md)；值层内部见 [value/README.md](value/README.md)；
语言层见 [glsl/README.md](glsl/README.md)；共享类型词汇见 [types.md](types.md)。

## 测试

```bash
raco test test          # 无需显示器
```

覆盖：表面语法重写、标识符便携层（变量/函数/关键字/类型别名）、字符串原语、美化、接口反射、报错定位、向量构造/布局/运算、
向量与矩阵运算、u8/u16 标量数组、控制流嵌套、**片段组合（fragment/splice）**、
`#lang shader/glsl` 顶层入口。

## License

MIT
