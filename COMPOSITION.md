# glsl 片段组合与编译期变换（设计）

> 状态：**四个关键决策已定，且已实现**（§1）；实现进度见 §9。
> 相关：[DESIGN.md](DESIGN.md)（现行分层）、[README.md](README.md)。

---

## 1. 已定决策

| # | 决策 | 结果 |
|---|---|---|
| 1 | chunk 绑定机制 | 选 **(ii)**：`glsl-fragment` 绑成**宏**，展开为 `(quote chunk)`；`glsl` 用 `local-expand` 认出 quote 取值（**无 `eval`**） |
| 2 | 源映射 | 默认 **定义处**（片段自身的 `path/line`） |
| 3 | 命名隔离 | 交给编译期：合并后检测重复定义，**冲突即编译期报错**（不自动改名） |
| 4 | 运行期求值 | **移除 `glsl-unquote`**；`glsl` 变成**完全编译期变换**，shader 在编译期完全确定（“定位”）。**以后拓展也只走编译期** |

这四条彼此自洽：chunk 是编译期数据、组合在编译期、冲突在编译期报错、结果在编译期算出。

---

## 2. 决策 4：完全编译期变换（它改变了核心）

> 状态：**已实现**（§9 第 1 步已落地，`glsl-unquote` 已移除、S7/S8 已在编译期）。

### 2.1 现行 vs 目标

**现行**（详见 [DESIGN.md](DESIGN.md) §2）：重写（S1–S6）在编译期，但**求值（S7）与组装（S8）在运行期**——
`glsl` 生成 `(make-glsl-program (list part …) …)`，`part` 是运行期才求值的 `glsl-*` 调用；`glsl-unquote`
是唯一的运行期逃逸口。

**目标**：**S1–S8 全部在编译期**，`glsl` 产出一个**编译期常量** `glsl-program`，生成的代码只是把它摆出来。

```
surface (glsl …)
  │ S1 收集 / S2 归一
  │ S3 词表 / S4 接口反射 / S5 源信息 / S6 重写   ← 全是编译期纯函数
  │ S7 求值 glsl-* 原语 → 字符串                  ← 上移到编译期
  │ S8 美化 / 组装 → glsl-program 值              ← 上移到编译期
  ▼
(quote <program-datum>)  →  运行期只 datum->glsl-program
```

### 2.2 带来的简化

- **`glsl-unquote` 移除**：不再需要「摘出使用侧语法 + splice-marker + `tree->syntax`」这一整套运行期拼接机制。
- `glsl` 宏退化为一个**纯 phase-1 函数**：surface datum 进 → `glsl-program` 数据出。
- `glsl-*` 原语是纯字符串函数，直接 `(require (for-syntax …))` 后在展开期调用（不再生成运行期代码）。
- 运行期只剩「从字面量重建 `glsl-program`」（`datum->glsl-program`），无逻辑。

### 2.3 收益

- **源映射指向定义处**（决策 2）：编译期就算好每个 form 的 `path/line`。
- **interface 编译期已知**：为「编译期宏驱动 GL 样板」（如 P4）提供可能——宏可读接口表生成代码。
- **shader 编译期定位**：可离线导出 `.glsl`、喂给将来的 program-binary / SPIR-V 静态编译路径
  （见 `racket-glsl-opengl` 包的设计文档 §6）。
- **简化宏实现**（§2.2）。

### 2.4 代价 / 破坏性

- **移除 `glsl-unquote` 是破坏性变更**：库测试（`rewrite-test`/`control-flow-test`/`lang-test`/`edge-test`）需重写；
  `study-opengl` 未使用，不受影响。
- **动态 shader** 不再能用 `glsl-unquote` 在 `(glsl …)` 内插值。改为：在 Racket 里拼出**整段 GLSL 字符串**，
  交给 `racket-glsl-opengl` 的 `shader-compile`（它已支持裸字符串）。这是明确的边界。
- shader 的文本在**模块加载时**即确定（编译期产物），不再是「加载时按运行期数据现算」。

---

## 3. 目标与非目标（能力边界）

| 能力 | 判定 |
|---|---|
| 静态片段复用（struct / 函数 / 声明块） | ✅ |
| **递归组合**（片段内 glsl-splice 片段） | ✅（展开期 flatten；循环→宏展开不终止报错） |
| 共享用户 `struct` 词表 | ✅ |
| 完整 interface（合并后一次反射） | ✅ |
| 源映射回溯到片段定义 | ✅ |
| 编译期参数化片段（宏生成 chunk） | ✅ |
| 跨片段重复定义冲突 | ✅ 编译期报错（决策 3） |
| 运行期参数化 / 运行期文本插值 | ❌（无 `glsl-unquote`；动态 shader 走 `shader-compile` 字符串） |
| 自动命名隔离（改名/卫生） | ❌（只做冲突检测） |

一句话：**chunk 是编译期静态片段；整条链全在编译期；运行期只重建结果。**

---

## 4. 数据载体（最小信息 + 派生表）

```racket
;; 一条 entry = 一个 surface 形式 + 它的源（“list 挂表”）；纯数据，可直接 quote
;;   entry = (list datum source)
;;   source = #f | (list path line text)   ; 片段定义处
(define (make-entry datum source) (list datum source))
(define (entry-datum e) (car e))
(define (entry-source e) (cadr e))

;; 片段 = 有序 entry 串（chunk = (list entry ...)）；可直接被 (quote …) 携带
```

> **实现说明**：entry 用**纯数据**（list）而非 struct——因为第 3 步的 chunk 要被 `glsl-fragment`
> 宏 `(quote …)` 成字面量传给 `glsl`，而 struct 实例不是可 quote 的 datum。故入口统一为
> `(list datum source)`，用 `entry-datum` / `entry-source` 取值。

- **不携带** `type-names` / `struct-defs` / `iface-datum`：合并后从全体形式**重新推导**（S3/S4），
  这样 struct 定义天然共享，也不会出现携带表与新形式不一致。
- 只带最小信息（形式 + 源）；其余 derived。
- 用 datum 而非 syntax 作载体（GLSL 表面无绑定语义，避免 phase 交叉）。

---

## 5. 机制（决策 1：宏 + `local-expand` 认 quote）——已实现

```racket
(glsl-fragment lighting (struct Light …) (uniform Light uLight) …)
;; 展开为：
(define-syntax lighting (lambda (stx) #'(quote <chunk-datum>)))

;; glsl 展开时对 (glsl-splice lighting)：
(define e (local-expand #'lighting 'expression '()))
;; e = (#%quote <chunk-datum>)  → 取出 <chunk-datum>.entries，拼进当前列表，递归处理其 glsl-splice
```

- 无 `eval`；跨模块只需普通 `(require "fragments.rkt")`（宏是 phase-1 绑定，默认导入）。
- 不是 quote → 报清晰错误「片段宏必须展开成 quote 数据」。
- 全部 flatten 后跑**一次** S3–S8。

---

## 6. 源映射（决策 2：定义处）

- 每条 entry 带片段定义处的 `source`；拼进来后仍映射回定义处。
- 主 `(glsl …)` 的形式用其使用处 syntax 的 `path/line`。
- 于是 GLSL 编译报错（由 opengl 包的 `shader-compile` 定位）**默认指向片段定义行**。
- 使用点（`(glsl-splice …)` 位置）暂不记录；将来如需「定义处 + 使用链」再扩。

---

## 7. 命名（决策 3：编译期冲突报错）

- GLSL 是扁平命名空间，chunk 是 datum 符号，**无卫生**。
- 合并后检测：跨片段的**重复定义**（`struct` 类型名、函数名、以及同名 uniform 等）→ **编译期报错**。
  比较的是**归一后的 GLSL 标识符**（`foo-bar` 与 `foo_bar` 都生成 `foo_bar`，视为冲突；
  `gl-position` 与 `gl_Position` 同理），避免绕开检测生成非法 GLSL。
- **不自动改名**：GLSL 无词法作用域，半套重命名会改坏必须与 CPU 侧字符串对齐的 uniform 名等，风险高。
- 用户可自行加前缀（约定）；冲突由编译器兜底。

---

## 8. 目标使用方式

```racket
#lang glsl

;; 可复用片段（编译期）
(glsl-fragment lighting
  (struct Light (vec3 position) (vec3 color))
  (uniform Light uLight)
  (define (lambert (vec3 n) (vec3 l)) float
    (max (vdot n l) 0.0)))

(glsl-fragment fog (uniform float uFogDensity))

;; 组合
(define shader
  (glsl (version 330 core)
        (glsl-splice lighting)
        (glsl-splice fog)
        (uniform vec3 uEye)
        (in vec3 aPos)
        (define (main) void
          (set! gl_Position (vec4 aPos 1.0)))))

;; 编译期就算好：interface 完整、源映射可回溯、冲突在展开期报错
(glsl-interface-vars (glsl-program-interface shader))   ; uLight / uFogDensity / uEye
```

**编译期参数化片段**（宏生成 chunk）：

```racket
(define-syntax (make-attenuation stx)
  (syntax-parse stx
    [(_ n) #`(glsl-splice #,(build-attenuation-chunk (syntax->datum #'n)))]))

(glsl … (make-attenuation 3) …)
```

---

## 9. 实现步骤与风险

**步骤**
1. ✅ **把 `glsl` 改为纯编译期变换**（决策 4）：
   - `glsl-*` 原语在展开期直接调用，S7/S8 上移到编译期；
   - 产出 `(datum->glsl-program '<program-datum>)`（新增 `glsl-program->datum`/`datum->glsl-program`）；
   - **移除 `glsl-unquote`**（含 `walk`/splice-marker/`tree->syntax`）与相关测试。
2. ✅ **内部数据统一为 `entries`**（`datum + source`），编译期流程抽成 `entries->program`。
3. ✅ **`glsl-splice`**：`forms->entries` 识别顶层 `(glsl-splice …)`，`local-expand` 取 `(quote chunk)`，拼接 entries。
4. ✅ **`glsl-fragment`**：编译期用 `forms->entries` 得到 chunk，绑成宏（展开为 `(quote chunk)`）。
5. ✅ **合并后跑一次 S3–S8**；`check-duplicates` 检测 struct/函数/变量重名（决策 3）。
6. ✅ 测试 `composition-test.rkt`：词表共享、interface 合并、定义处源映射、递归、冲突/错误报错。

   （待补：“编译期参数化片段”的示例测试；实现上已支持——宏展开出 `(glsl-splice …)` 即可。）

**风险 / 待定**
- 移除 `glsl-unquote` 后，重写库测试；确认没有别的内部依赖。
- `glsl-fragment` 内**不能**有运行期表达式（决策 4），文档要写明。
- 重复定义检测的范围（struct/函数/uniform/…）与判据需定。
- `local-expand` 标识符宏展开的细节；必要时退化为 `(glsl-splice (lighting))` 调用形式。

---

## 10. 明确不做

- `(glsl (glsl …))` 嵌套（隔离语义）。
- 运行期求值 / `glsl-unquote`（决策 4 已移除）。
- 自动命名隔离（改名/卫生）；只做冲突检测。
