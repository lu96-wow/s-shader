#lang racket/base

(require racket/list racket/string)

;; ============================================================
;; 块 1 · (glsl) 内 · glsl/names.rkt —— 表面标识符 → GLSL 标识符（便携层）
;;
;; 这是**唯一**做「Racket 风格名字 ↔ GLSL 名字」转换的地方。
;; 逻辑上按命名空间拆成四张独立的表：
;;
;;   1. 内建变量表   gl-position / gl_position → gl_Position
;;   2. 内建函数表   texture-size / texture_size → textureSize
;;   3. 关键字表     read-only → readonly、local-size-x → local_size_x
;;   4. 用户标识符   其余 wow-name-type → wow_name_type
;;
;; ★ 内建**类型名**别名不在本模块：在 core/vocab/type-names.rkt
;;   （vec-3 → vec3、sampler-2d → sampler2D …）。类型名由语言层和值层共享。
;;
;; 四张表互不干扰：
;;   - 变量名不会命中函数别名；
;;   - 函数名不会命中变量别名；
;;   - 关键字别名只用于 qualifier / layout key；
;;   - 用户标识符走通用 '-'→'_'。
;;
;; 规则（每个命名空间内，优先级从高到低）：
;;   1. 命中该命名空间的别名表 → 用表里的规范 GLSL 拼写；
;;   2. 否则 → 通用 '-'→'_'（用户标识符）；
;;   3. 结果必须是真正的 GLSL 标识符，否则报错。
;; ============================================================

(provide
 ;; ---- 通用标识符 / 内建变量 ----
 glsl-name glsl-name-symbol glsl-identifier?
 glsl-builtin-variable-names glsl-builtin-variable-aliases
 ;; ---- 内建函数 ----
 glsl-function-name glsl-function-name-symbol
 glsl-builtin-function-names glsl-builtin-function-aliases
 ;; ---- 关键字：qualifier / layout key ----
 glsl-qualifier-name glsl-qualifier-name-symbol glsl-qualifier?
 glsl-qualifier-names glsl-qualifier-aliases
 glsl-layout-key-name glsl-layout-key-symbol
 glsl-layout-key-names glsl-layout-key-aliases)

;; ============================================================
;; 公共小工具
;; ============================================================

(define (as-string who x)
  (cond
    [(symbol? x) (symbol->string x)]
    [(string? x) x]
    [else (error who "需要 symbol 或 string，实际 ~s" x)]))

;; camelCase / 下划线名 → kebab-case
;;   gl_Position → gl-position
;;   gl_VertexID → gl-vertex-id
;;   dFdx        → d-fdx
;;   findLSB     → find-lsb
(define (camel->kebab str)
  (define n (string-length str))
  (define out (open-output-string))
  (for ([ch (in-string str)] [i (in-naturals)])
    (cond
      [(char=? ch #\_) (write-char #\- out)]
      [(and (char-upper-case? ch)
            (> i 0)
            (let ([prev (string-ref str (sub1 i))])
              (or (char-lower-case? prev)
                  (char-numeric? prev)
                  (and (char-upper-case? prev)
                       (< (add1 i) n)
                       (char-lower-case? (string-ref str (add1 i)))))))
       (write-char #\- out)
       (write-char (char-downcase ch) out)]
      [else (write-char (char-downcase ch) out)]))
  (get-output-string out))

;; 一个 canonical 名的候选别名（kebab + 全小写下划线；去掉与 canonical 相同的）
(define (camel-alias-symbols name)
  (define s (symbol->string name))
  (define kebab (camel->kebab s))
  (define snake (string-replace kebab "-" "_"))
  (define forms (if (string=? kebab snake) (list kebab) (list kebab snake)))
  (for/list ([f (in-list forms)] #:unless (string=? f s))
    (string->symbol f)))

;; 从「canonical 名清单」生成 alias-symbol → canonical-string 的 hash
(define (make-camel-alias-table who names)
  (for*/fold ([h (hash)]) ([n (in-list names)]
                           [a (in-list (camel-alias-symbols n))])
    (when (hash-has-key? h a)
      (error who "别名冲突：~a → ~a" a n))
    (hash-set h a (symbol->string n))))

(define (hash->sorted-pairs h)
  (sort (for/list ([(k v) (in-hash h)]) (cons k (string->symbol v)))
        (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))))

;; 通用用户标识符：只做 '-'→'_'，再校验
(define (user-identifier-name who x)
  (define s (as-string who x))
  (define mapped (string-replace s "-" "_"))
  (unless (glsl-identifier? mapped)
    (error who "非法 GLSL 标识符：~a → ~a（只允许字母/数字/下划线；连字符会转成 _）"
           s mapped))
  mapped)

;; GLSL 标识符：ASCII 字母/下划线开头，后续字母/数字/下划线
(define (glsl-identifier? x)
  (and (regexp-match? #rx"^[A-Za-z_][A-Za-z0-9_]*$" (as-string 'glsl-identifier? x)) #t))

;; 查别名表；不命中返回 #f
(define (alias-ref table who x)
  (hash-ref table (string->symbol (as-string who x)) #f))

;; ============================================================
;; 表 1 · 内建变量（变量/常量/内建块名；不含函数、类型）
;; ============================================================

(define builtin-variable-names
  '(;; 顶点 / 片元
    gl_Position gl_PointSize gl_ClipDistance gl_CullDistance
    gl_VertexID gl_InstanceID
    gl_FragCoord gl_FrontFacing gl_PointCoord gl_FragDepth
    gl_SampleID gl_SamplePosition gl_SampleMask gl_SampleMaskIn
    gl_NumSamples gl_HelperInvocation
    gl_Layer gl_ViewportIndex gl_ViewIndex gl_PrimitiveID
    ;; 传统（兼容管线）
    gl_FragColor gl_FragData
    ;; 几何
    gl_PrimitiveIDIn gl_InvocationID
    ;; 细分
    gl_TessCoord gl_TessLevelOuter gl_TessLevelInner gl_PatchVerticesIn
    ;; 计算
    gl_NumWorkGroups gl_WorkGroupSize gl_WorkGroupID
    gl_LocalInvocationID gl_GlobalInvocationID gl_LocalInvocationIndex
    ;; shader draw parameters
    gl_BaseVertex gl_BaseInstance gl_DrawID
    ;; subgroup（GLSL 4.6 / ARB_shader_ballot 等）
    gl_SubgroupSize gl_SubgroupInvocationID gl_SubgroupID gl_NumSubgroups
    gl_SubgroupEqMask gl_SubgroupGeMask gl_SubgroupGtMask
    gl_SubgroupLeMask gl_SubgroupLtMask
    ;; 内建块 / 结构
    gl_in gl_out gl_PerVertex gl_DepthRange
    ;; 实现上限常量
    gl_MaxVertexAttribs gl_MaxVertexUniformComponents gl_MaxVertexUniformVectors
    gl_MaxVertexOutputComponents gl_MaxVertexTextureImageUnits
    gl_MaxCombinedTextureImageUnits gl_MaxTextureImageUnits
    gl_MaxFragmentInputComponents gl_MaxFragmentUniformComponents
    gl_MaxFragmentUniformVectors gl_MaxDrawBuffers
    gl_MaxClipDistances gl_MaxCullDistances gl_MaxViewports
    gl_MaxGeometryInputComponents gl_MaxGeometryOutputComponents
    gl_MaxGeometryTextureImageUnits gl_MaxGeometryUniformComponents
    gl_MaxGeometryOutputVertices gl_MaxGeometryTotalOutputComponents
    gl_MaxGeometryVaryingComponents
    gl_MaxTessControlInputComponents gl_MaxTessControlOutputComponents
    gl_MaxTessControlTextureImageUnits gl_MaxTessControlUniformComponents
    gl_MaxTessControlTotalOutputComponents
    gl_MaxTessEvaluationInputComponents gl_MaxTessEvaluationOutputComponents
    gl_MaxTessEvaluationTextureImageUnits gl_MaxTessEvaluationUniformComponents
    gl_MaxTessPatchComponents gl_MaxPatchVertices gl_MaxTessGenLevel
    gl_MaxComputeUniformComponents gl_MaxComputeTextureImageUnits
    gl_MaxComputeImageUniforms gl_MaxComputeAtomicCounters
    gl_MaxComputeAtomicCounterBuffers gl_MaxComputeWorkGroupCount
    gl_MaxComputeWorkGroupSize gl_MaxComputeWorkGroupInvocations
    gl_MaxCombinedShaderOutputResources gl_MaxCombinedImageUniforms
    gl_MaxCombinedImageUnitsAndFragmentOutputs gl_MaxImageUnits
    gl_MaxImageSamples gl_MaxAtomicCounterBindings
    gl_MaxAtomicCounterBufferSize gl_MaxShaderStorageBlocks
    gl_MaxShaderStorageBufferBindings gl_MaxTransformFeedbackBuffers
    gl_MaxTransformFeedbackInterleavedComponents
    gl_MinProgramTexelOffset gl_MaxProgramTexelOffset gl_MaxSamples
    gl_MaxVaryingComponents gl_MaxVaryingVectors))

(define builtin-variable-alias-table
  (make-camel-alias-table 'glsl-name builtin-variable-names))

(define glsl-builtin-variable-names builtin-variable-names)
(define glsl-builtin-variable-aliases
  (hash->sorted-pairs builtin-variable-alias-table))

;; ============================================================
;; 表 2 · 内建函数（只列 camelCase 的；全小写函数走通用规则）
;; ============================================================

(define builtin-function-names
  '(;; texture
    textureSize textureProj textureLod textureOffset texelFetch
    texelFetchOffset textureProjOffset textureLodOffset textureProjLod
    textureProjLodOffset textureGrad textureGradOffset textureProjGrad
    textureProjGradOffset textureGather textureGatherOffset textureGatherOffsets
    textureQueryLod textureQueryLevels textureSamples
    ;; derivative
    dFdx dFdy dFdxFine dFdyFine dFdxCoarse dFdyCoarse
    fwidthFine fwidthCoarse
    ;; packing
    packSnorm2x16 unpackSnorm2x16 packUnorm2x16 unpackUnorm2x16
    packSnorm4x8 unpackSnorm4x8 packUnorm4x8 unpackUnorm4x8
    packHalf2x16 unpackHalf2x16 packDouble2x32 unpackDouble2x32
    ;; matrix / vector / relational
    matrixCompMult outerProduct
    lessThan lessThanEqual greaterThan greaterThanEqual notEqual
    ;; bit / float
    floatBitsToInt floatBitsToUint intBitsToFloat uintBitsToFloat
    bitfieldExtract bitfieldInsert bitfieldReverse bitCount findLSB findMSB
    uaddCarry usubBorrow umulExtended imulExtended
    ;; atomic counter / atomic memory
    atomicAdd atomicMin atomicMax atomicAnd atomicOr atomicXor
    atomicExchange atomicCompSwap
    atomicCounterIncrement atomicCounterDecrement atomicCounter
    atomicCounterAdd atomicCounterSubtract atomicCounterMin
    atomicCounterMax atomicCounterAnd atomicCounterOr atomicCounterXor
    atomicCounterExchange atomicCounterCompSwap
    ;; image
    imageLoad imageStore imageSize imageSamples
    imageAtomicAdd imageAtomicMin imageAtomicMax imageAtomicAnd
    imageAtomicOr imageAtomicXor imageAtomicExchange imageAtomicCompSwap
    ;; barriers
    memoryBarrier memoryBarrierAtomicCounter memoryBarrierBuffer
    memoryBarrierShared memoryBarrierImage memoryBarrierByRegion groupMemoryBarrier
    ;; interpolation
    interpolateAtCentroid interpolateAtSample interpolateAtOffset
    ;; subgroup
    subgroupAdd subgroupMul subgroupMin subgroupMax
    subgroupAnd subgroupOr subgroupXor
    subgroupInclusiveAdd subgroupExclusiveAdd
    subgroupInclusiveMul subgroupExclusiveMul
    subgroupBallot subgroupBallotBitCount
    subgroupBallotInclusiveBitCount subgroupBallotExclusiveBitCount
    subgroupBallotFindLSB subgroupBallotFindMSB
    subgroupBroadcast subgroupBroadcastFirst
    subgroupShuffle subgroupShuffleXor subgroupShuffleUp subgroupShuffleDown
    subgroupElect subgroupBarrier
    subgroupMemoryBarrier subgroupMemoryBarrierBuffer
    subgroupMemoryBarrierShared subgroupMemoryBarrierImage
    subgroupMemoryBarrierAtomicCounter
    ;; 其他
    roundEven))

(define builtin-function-alias-table
  (make-camel-alias-table 'glsl-function-name builtin-function-names))

(define glsl-builtin-function-names builtin-function-names)
(define glsl-builtin-function-aliases
  (hash->sorted-pairs builtin-function-alias-table))

;; ============================================================
;; 表 3a · 关键字：限定符（qualifier）
;; ============================================================

(define qualifier-names
  '(in out uniform const buffer flat smooth noperspective centroid sample patch
    invariant precise shared readonly writeonly restrict coherent volatile
    subroutine inout))

;; 不规则的 Racket 风格别名；规范的单词限定符不需要条目
(define qualifier-aliases
  '((no-perspective . "noperspective")
    (read-only . "readonly")
    (write-only . "writeonly")
    (in-out . "inout")))

(define qualifier-alias-table
  (for/hash ([p (in-list qualifier-aliases)]) (values (car p) (cdr p))))

(define qualifier-canonical-table
  (for/hash ([n (in-list qualifier-names)]) (values n #t)))

(define glsl-qualifier-names qualifier-names)
(define glsl-qualifier-aliases qualifier-aliases)

;; ============================================================
;; 表 3b · 关键字：layout key
;; ============================================================

;; 常见 canonical layout key；未列出的仍可写（通用 '-'→'_' 兜底）。
(define layout-key-names
  '(location component index binding offset align
    local_size_x local_size_y local_size_z
    early_fragment_tests
    invocations max_vertices max_primitives
    triangles triangle_strip lines line_strip points isolines quads
    equal_spacing fractional_even_spacing fractional_odd_spacing
    cw ccw point_mode pixel_center_integer origin_upper_left
    depth_any depth_greater depth_less depth_unchanged
    std140 std430 shared packed row_major column_major
    xfb_buffer xfb_offset xfb_stride))

(define layout-key-alias-table
  (make-camel-alias-table 'glsl-layout-key-name layout-key-names))

(define glsl-layout-key-names layout-key-names)
(define glsl-layout-key-aliases
  (hash->sorted-pairs layout-key-alias-table))

;; ============================================================
;; 入口函数：每个命名空间一个
;; ============================================================

;; 通用标识符 + 内建变量
(define (glsl-name x)
  (or (alias-ref builtin-variable-alias-table 'glsl-name x)
      (user-identifier-name 'glsl-name x)))

(define (glsl-name-symbol x)
  (string->symbol (glsl-name x)))

;; 内建函数 + 用户函数
(define (glsl-function-name x)
  (or (alias-ref builtin-function-alias-table 'glsl-function-name x)
      (user-identifier-name 'glsl-function-name x)))

(define (glsl-function-name-symbol x)
  (string->symbol (glsl-function-name x)))

;; 限定符：显式别名优先；未知连字符按通用规则兜底
(define (glsl-qualifier-name x)
  (or (alias-ref qualifier-alias-table 'glsl-qualifier-name x)
      (user-identifier-name 'glsl-qualifier-name x)))

(define (glsl-qualifier-name-symbol x)
  (string->symbol (glsl-qualifier-name x)))

;; 这个符号是限定符（规范名或别名）
(define (glsl-qualifier? x)
  (and (or (symbol? x) (string? x))
       (let ([sym (string->symbol (as-string 'glsl-qualifier? x))])
         (and (or (hash-ref qualifier-canonical-table sym #f)
                  (hash-ref qualifier-alias-table sym #f))
              #t))))

;; layout key：显式/自动别名优先；未知 key 按通用规则兜底
(define (glsl-layout-key-name x)
  (or (alias-ref layout-key-alias-table 'glsl-layout-key-name x)
      (user-identifier-name 'glsl-layout-key-name x)))

(define (glsl-layout-key-symbol x)
  (string->symbol (glsl-layout-key-name x)))
