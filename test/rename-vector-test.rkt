#lang racket/base
;; 运行：racket test/rename-vector-test.rkt
(require rackunit
         ffi/vector
         shader/value/rename-type
         shader/value/rename-access
         shader/value/rename-construct
         shader/value/rename-layout
         shader/value/rename-buffer
         shader/value/convert)

;; ffi vector 的 equal? 不比较内容，统一用 ->list 比
(define (lv v) (f32vector->list v))
(define (ld v) (f64vector->list v))
(define (li v) (s32vector->list v))
(define (lu v) (u32vector->list v))
;; u8vector 的一段 → bytes（用于按字节解码验证）
(define (bv->bytes bv start len)
  (apply bytes (for/list ([i (in-range start (+ start len))]) (u8vector-ref bv i))))

;; ---------- 向量构造 + 显式输入检查 ----------
(check-equal? (lv (vec3 1.0 2.0 3.0)) '(1.0 2.0 3.0))
(check-exn exn:fail? (lambda () (vec2 1 2)))            ; 整数 → 报错（不隐式转）
(check-exn exn:fail? (lambda () (vec3 1.0 2.0)))        ; 元数不对报错

(check-equal? (li (ivec3 1 2 3)) '(1 2 3))
(check-exn exn:fail? (lambda () (ivec2 1.0 2.0)))       ; 非整数 → 报错
(check-equal? (lu (uvec2 1 2)) '(1 2))

;; bvec：#t/#f 和数字都收，0/#f→0，非 0/#t→1
(check-equal? (lu (bvec3 #t #f #t)) '(1 0 1))
(check-equal? (lu (bvec2 0 5)) '(0 1))

;; ---------- dvec：double 精度向量 ----------
(check-equal? (ld (dvec3 1.0 2.0 3.0)) '(1.0 2.0 3.0))
(check-exn exn:fail? (lambda () (dvec2 1 2)))            ; 整数 → 报错（不隐式转）

;; ---------- 拼装 ----------
(check-equal? (lv (concat-vecs (vec2 -0.5 -0.5) (vec2 0.5 -0.5) (vec2 0.0 0.5)))
              '(-0.5 -0.5 0.5 -0.5 0.0 0.5))
(check-equal? (lv (concat-vecs)) '())
;; 原地拼装：写进预分配 dst，返回元素数
(define dst (make-f32vector 10 0.0))
(check-equal? (concat-vecs! dst (list (vec2 1.0 2.0) (vec3 3.0 4.0 5.0))) 5)
(check-equal? (lv dst) '(1.0 2.0 3.0 4.0 5.0 0.0 0.0 0.0 0.0 0.0))

;; ---------- gl-vec：n 个同型向量 ----------
;; 静态构造 + 访问
(define vn (gl-vec (vec2 -0.5 -0.5) (vec2 0.5 -0.5) (vec2 0.0 0.5)))
(check-true (gl-vec? vn))
(check-equal? (gl-vec-count vn) 3)
(check-equal? (gl-vec-width vn) 2)
(check-equal? (lv (gl-vec->f32vector vn)) '(-0.5 -0.5 0.5 -0.5 0.0 0.5))
(check-equal? (lv (gl-vec-ref vn 1)) '(0.5 -0.5))        ; 函数式读：新切片
;; set! 式写（原地，零分配）
(gl-vec-set! vn 1 (vec2 9.0 9.0))
(check-equal? (lv (gl-vec->f32vector vn)) '(-0.5 -0.5 9.0 9.0 0.0 0.5))
;; 动态构造：预分配 n 个，填 template
(define dn (make-gl-vec 1000 (vec3 0.0 0.0 0.0)))
(check-equal? (gl-vec-count dn) 1000)
(check-equal? (gl-vec-width dn) 3)
(check-equal? (lv (gl-vec-ref dn 999)) '(0.0 0.0 0.0))
(gl-vec-set! dn 0 (vec3 1.0 2.0 3.0))
(check-equal? (lv (gl-vec-ref dn 0)) '(1.0 2.0 3.0))
;; 报错：空 / 宽度不一致 / set! 宽度不匹配
(check-exn exn:fail? (lambda () (gl-vec)))
(check-exn exn:fail? (lambda () (gl-vec (vec2 1.0 2.0) (vec3 1.0 2.0 3.0))))
(check-exn exn:fail? (lambda () (gl-vec-set! vn 0 (vec3 1.0 2.0 3.0))))

;; ---------- mat：对角 ----------
(check-equal? (lv (mat2 1.0)) '(1.0 0.0 0.0 1.0))
(check-equal? (lv (mat4 2.0))
              '(2.0 0.0 0.0 0.0
                0.0 2.0 0.0 0.0
                0.0 0.0 2.0 0.0
                0.0 0.0 0.0 2.0))

;; ---------- mat：拷贝 / f64→f32 ----------
(check-equal? (lv (mat4 (f32vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0)))
              '(1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))
(check-equal? (lv (mat4 (f64vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0)))
              '(1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

;; ---------- mat：列向量 ----------
(check-equal? (lv (mat2 (vec2 1.0 0.0) (vec2 0.0 1.0)))
              '(1.0 0.0 0.0 1.0))
(check-equal? (lv (mat4 (vec4 1.0 0.0 0.0 0.0) (vec4 0.0 1.0 0.0 0.0)
                        (vec4 0.0 0.0 1.0 0.0) (vec4 0.0 0.0 0.0 1.0)))
              '(1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

;; ---------- mat：16 标量（列主序） ----------
(check-equal? (lv (mat4 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))
              '(1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

;; ---------- mat：非法形式报错 ----------
(check-exn exn:fail? (lambda () (mat4)))                              ; 零元
(check-exn exn:fail? (lambda () (mat4 1.0 2.0 3.0 4.0)))             ; 4 标量（GLSL 也非法）
(check-exn exn:fail? (lambda () (mat4 1 0 0 0  0 1 0 0  0 0 1 0  0 0 0 1))) ; 整数标量
(check-exn exn:fail? (lambda () (mat4 (f32vector 1.0 2.0 3.0))))     ; 长度错

;; ---------- dmat：double 精度矩阵 ----------
(check-equal? (ld (dmat2 1.0)) '(1.0 0.0 0.0 1.0))
(check-equal? (ld (dmat4 (vec4 1.0 0.0 0.0 0.0) (vec4 0.0 1.0 0.0 0.0)
                         (vec4 0.0 0.0 1.0 0.0) (vec4 0.0 0.0 0.0 1.0)))
              '(1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))
;; mat↔dmat 互转（精度在 GLSL 名字里，不在 ffi 名字里）
(check-equal? (lv (mat4 (dmat4 2.0)))
              '(2.0 0.0 0.0 0.0  0.0 2.0 0.0 0.0  0.0 0.0 2.0 0.0  0.0 0.0 0.0 2.0))
(check-equal? (ld (dmat4 (mat4 2.0)))
              '(2.0 0.0 0.0 0.0  0.0 2.0 0.0 0.0  0.0 0.0 2.0 0.0  0.0 0.0 0.0 2.0))

;; ---------- 尺寸 / 步长 ----------
(check-equal? (shader-size 'vec3) 3)
(check-equal? (shader-byte-size 'vec3) 12)
(check-equal? (shader-stride 'vec3 'vec2) 5)
(check-equal? (shader-stride-bytes 'vec3 'vec2) 20)
(check-equal? (shader-stride-bytes 'vec3 'vec3 'float) 28)   ; 实例数组每行 7 float
(check-equal? (shader-stride-bytes 'vec3) 12)                 ; 前缀偏移 = 跳过 vec3
;; double 系：分量 8 字节
(check-equal? (shader-size 'dvec3) 3)
(check-equal? (shader-byte-size 'dvec3) 24)
(check-equal? (shader-byte-size 'dmat4) 128)
(check-equal? (shader-stride-bytes 'vec3 'dvec3) 36)
(check-exn exn:fail? (lambda () (shader-size 'sampler2D)))    ; 无 CPU 表示

;; ---------- shader-struct：交错记录 ----------
;; 具名字段（(类型 名字)，与 shader 一致）：生成构造器 / 访问器 / 铺平 / stride / offset / size
(shader-struct instance
  (vec3 offset)
  (vec3 color)
  (float phase))

(check-true (instance? (instance (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0) 0.5)))
(check-equal? (lv (instance-offset (instance (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0) 0.5)))
              '(1.0 2.0 3.0))
;; 铺平：向量 + 向量 + 标量 → 一条 f32vector（用 f32 里精确可表示的数）
(check-equal? (lv (instance->f32vector
                   (instance (vec3 1.0 2.0 3.0) (vec3 0.5 0.25 0.125) 0.75)))
              '(1.0 2.0 3.0 0.5 0.25 0.125 0.75))
;; 布局从 struct 声明推导
(check-equal? (instance-stride) 28)
(check-equal? (instance-field-offset 'offset) 0)
(check-equal? (instance-field-offset 'color) 12)
(check-equal? (instance-field-offset 'phase) 24)
(check-equal? (instance-field-size 'offset) 3)
(check-equal? (instance-field-size 'color) 3)
(check-equal? (instance-field-size 'phase) 1)
(check-exn exn:fail? (lambda () (instance-field-offset 'nope)))

;; 纯向量字段的 struct（无标量）也能铺平
(shader-struct vert (vec3 pos) (vec3 nrm))
(check-equal? (lv (vert->f32vector (vert (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0))))
              '(1.0 2.0 3.0 4.0 5.0 6.0))
(check-equal? (vert-stride) 24)
(check-equal? (vert-field-offset 'nrm) 12)

;; 空 struct → 报错
(check-exn exn:fail? (lambda () (eval '(shader-struct Empty))))

;; ---------- concat-dvecs：double 拼装 ----------
(check-equal? (ld (concat-dvecs (dvec2 1.0 2.0) (dvec3 3.0 4.0 5.0)))
              '(1.0 2.0 3.0 4.0 5.0))
(check-equal? (ld (concat-dvecs)) '())
(define ddst (make-f64vector 6 0.0))
(check-equal? (concat-dvecs! ddst (list (dvec3 1.0 2.0 3.0) (dvec2 4.0 5.0))) 5)
(check-equal? (ld ddst) '(1.0 2.0 3.0 4.0 5.0 0.0))

;; ---------- shader-struct：double 字段 → ->f64vector ----------
(shader-struct dparticle
  (dvec3 position)
  (dvec2 velocity)
  (double mass))
(check-equal? (ld (dparticle->f64vector
                   (dparticle (dvec3 1.0 2.0 3.0) (dvec2 0.5 0.25) 0.125)))
              '(1.0 2.0 3.0 0.5 0.25 0.125))
(check-equal? (dparticle-stride) 48)   ; 24 + 16 + 8
(check-equal? (dparticle-field-offset 'position) 0)
(check-equal? (dparticle-field-offset 'velocity) 24)
(check-equal? (dparticle-field-offset 'mass) 40)
(check-equal? (dparticle-field-size 'mass) 1)
(check-exn exn:fail? (lambda () (dparticle-field-offset 'nope)))

;; 混用 float/double 字段 → 宏展开时报错（不是运行时报错）
(check-exn exn:fail? (lambda () (eval '(shader-struct mixed-vertex (vec3 a) (dvec3 b)))))

;; ---------- shader-struct：整数 / 布尔字段（修复：以前会报错或写错字节）----------
;; 全 int → s32vector
(shader-struct irec (ivec3 a) (int b))
(check-true (s32vector? (irec->s32vector (irec (ivec3 1 2 3) 7))))
(check-equal? (li (irec->s32vector (irec (ivec3 1 2 3) 7))) '(1 2 3 7))
(check-equal? (irec-stride) 16)
(check-equal? (irec-field-offset 'b) 12)

;; 全 uint/uvec → u32vector
(shader-struct urec (uvec3 a) (uint b))
(check-equal? (lu (urec->u32vector (urec (uvec3 1 2 3) 9))) '(1 2 3 9))

;; bool 标量 → u32（0/1）
(shader-struct brec (bvec3 a) (bool b))
(check-equal? (lu (brec->u32vector (brec (bvec3 #t #f #t) #t))) '(1 0 1 1))

;; 混合类别（float + int）→ u8vector；int 字段必须是整数字节，不是 float 字节
(shader-struct mrec (vec3 pos) (int idx))
(define mrec-bytes (mrec->bytes (mrec (vec3 1.0 2.0 3.0) 7)))
(check-true (u8vector? mrec-bytes))
(check-equal? (u8vector-length mrec-bytes) 16)
(check-equal? (floating-point-bytes->real (bv->bytes mrec-bytes 0 4) (system-big-endian?)) 1.0)
(check-equal? (floating-point-bytes->real (bv->bytes mrec-bytes 8 4) (system-big-endian?)) 3.0)
(check-equal? (integer-bytes->integer (bv->bytes mrec-bytes 12 4) #t (system-big-endian?)) 7)
(check-equal? (mrec-field-offset 'idx) 12)
(check-equal? (mrec-field-size 'idx) 1)
(check-equal? (mrec-stride) 16)

;; double + int 也是混合 → u8vector，int 部分仍是整数字节
(shader-struct dmrec (dvec3 pos) (int idx))
(define dmrec-bytes (dmrec->bytes (dmrec (dvec3 1.0 2.0 3.0) 5)))
(check-true (u8vector? dmrec-bytes))
(check-equal? (integer-bytes->integer (bv->bytes dmrec-bytes 24 4) #t (system-big-endian?)) 5)

;; 整数字段的坏输入仍要报错
(check-exn exn:fail? (lambda () (mrec->bytes (mrec (vec3 1.0 2.0 3.0) 7.5))))  ; int 字段给非整数
(check-exn exn:fail? (lambda () (urec->u32vector (urec (uvec3 1 2 3) -1))))     ; uint 给负数

;; ---------- 整数 / double 向量数组（按名字区分 kind，无 kind 参数）----------
(define iv (ivec-array (ivec3 1 2 3) (ivec3 4 5 6)))
(check-true (vec-array? iv))
(check-equal? (vec-array-count iv) 2)
(check-equal? (vec-array-width iv) 3)
(check-true (s32vector? (vec-array-data iv)))
(check-equal? (li (vec-array-data iv)) '(1 2 3 4 5 6))
(check-equal? (li (vec-array-ref iv 1)) '(4 5 6))
(vec-array-set! iv 0 (ivec3 9 9 9))
(check-equal? (li (vec-array-data iv)) '(9 9 9 4 5 6))

(define dv (dvec-array (dvec2 1.0 2.0)))
(check-true (f64vector? (vec-array-data dv)))
(check-equal? (ld (vec-array-data dv)) '(1.0 2.0))

(define uv (make-uvec-array 3 (uvec2 0 0)))
(check-equal? (vec-array-count uv) 3)
(check-equal? (lu (vec-array-ref uv 2)) '(0 0))

;; kind 不对要报错
(check-exn exn:fail? (lambda () (ivec-array (vec3 1.0 2.0 3.0))))     ; 给了 float
(check-exn exn:fail? (lambda () (vec-array (ivec3 1 2 3))))            ; vec-array 只收 float
(check-exn exn:fail? (lambda () (vec-array-set! iv 0 (uvec3 1 2 3))))  ; 元素类别不匹配

;; 整数拼接
(check-equal? (li (concat-ivecs (ivec2 1 2) (ivec2 3 4))) '(1 2 3 4))
(check-equal? (lu (concat-uvecs (uvec2 1 2))) '(1 2))

;; ---------- shader-struct 新生成名 ----------
(shader-struct p3 (vec3 pos) (vec3 color))
(check-equal? (p3-stride-bytes) 24)
(check-equal? (p3-field-components 'pos) 3)
(check-equal? (f32vector-length (p3->f32vector (p3 (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0)))) 6)

;; ---------- 类型消歧新名 ----------
(check-equal? (shader-element-count 'vec3) 3)
(check-equal? (shader-storage-kind 'vec3) 'f32)
(check-equal? (shader-stride-elements 'vec3 'vec2) 5)

;; ---------- u8 / u16 标量数组（索引 / 像素） ----------
(define idx (u16-array 0 1 2 2 3 0))
(check-true (u16-array? idx))
(check-equal? (u16-array-length idx) 6)
(check-equal? (u16-array-ref idx 1) 1)
(u16-array-set! idx 0 9)
(check-equal? (u16-array-ref idx 0) 9)
(check-true (u16vector? (u16-array-data idx)))
(check-exn exn:fail? (lambda () (u16-array 70000)))
(check-exn exn:fail? (lambda () (u16-array -1)))

(define px (make-u8-array 4 255))
(check-true (u8-array? px))
(check-equal? (u8-array-length px) 4)
(check-equal? (u8-array-ref px 0) 255)
(u8-array-set! px 0 0)
(check-equal? (u8-array-ref px 0) 0)
(check-exn exn:fail? (lambda () (u8-array 256)))

;; value-kind 扩展后，vref / vcount 也覆盖 u8/u16
(check-equal? (vref idx 1) 1)
(check-equal? (vcount idx) 6)
(check-equal? (vref px 3) 255)

;; 转换：->u16vector / ->u8vector，并接受其它精度输入
(check-equal? (u16vector->list (->u16vector (ivec2 1 2))) '(1 2))
(check-equal? (u16vector->list (->u16vector (u16-array 3 4))) '(3 4))
(check-equal? (u8vector->list (->u8vector (u16-array 1 2))) '(1 2))
(check-exn exn:fail? (lambda () (->u8vector (u16-array 300))))
(check-exn exn:fail? (lambda () (->u16vector (s32vector -1))))
(check-equal? (s32vector->list (->s32vector (u16-array 7 8))) '(7 8))
(check-equal? (f32vector->list (->f32vector (u8-array 1 2))) '(1.0 2.0))
(check-equal? (u16vector->list (->u16vector (f64vector 1.0 2.0))) '(1 2))

(displayln "rename-vector 全部测试通过")
