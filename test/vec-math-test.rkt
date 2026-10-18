#lang racket/base
;; 运行：racket test/vec-math-test.rkt
(require rackunit
         ffi/vector
         shader/value/rename-type
         shader/value/rename-access
         shader/value/rename-construct
         shader/value/rename-layout
         shader/value/rename-buffer
         shader/value/convert
         shader/value/rename-vec
         shader/value/rename-matrix
         shader/value/convert)

(define (lf v) (map (lambda (x) (inexact->exact (round (* x 1e6)))) (f32vector->list v)))
(define (ld v) (f64vector->list v))
(define (li v) (s32vector->list v))
(define (lu v) (u32vector->list v))
(define (close? a b [eps 1e-5]) (< (abs (- a b)) eps))
(define (check-close a b [eps 1e-5])
  (check-true (close? a b eps) (format "expected ~a ≈ ~a" a b)))

;; ---------- 分量 / 形状 ----------
(check-equal? (vcount (vec3 1.0 2.0 3.0)) 3)
(check-equal? (vx (vec4 1.0 2.0 3.0 4.0)) 1.0)
(check-equal? (vw (vec4 1.0 2.0 3.0 4.0)) 4.0)
(check-equal? (vref (vec3 1.0 2.0 3.0) 2) 3.0)
(define vv (vec3 1.0 2.0 3.0))
(vset! vv 1 9.0)
(check-equal? (lf vv) '(1000000 9000000 3000000))
(check-equal? (lf (vmap (lambda (x) (* x 2.0)) (vec2 1.0 2.0))) '(2000000 4000000))

;; ---------- 逐分量算术（float 族）----------
(check-equal? (lf (vadd (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0))) '(5000000 7000000 9000000))
(check-equal? (lf (vsub (vec3 4.0 5.0 6.0) (vec3 1.0 2.0 3.0))) '(3000000 3000000 3000000))
(check-equal? (lf (vmul (vec2 2.0 3.0) (vec2 4.0 5.0))) '(8000000 15000000))
(check-equal? (lf (vmul (vec2 2.0 3.0) 10.0)) '(20000000 30000000))
(check-equal? (lf (vdiv (vec2 8.0 9.0) 2.0)) '(4000000 4500000))
(check-equal? (lf (vneg (vec2 1.0 -2.0))) '(-1000000 2000000))
(check-equal? (lf (vmin (vec2 1.0 5.0) 3.0)) '(1000000 3000000))
(check-equal? (lf (vmax (vec2 1.0 5.0) 3.0)) '(3000000 5000000))
(check-equal? (lf (vfract (vec2 1.25 -0.25))) '(250000 750000))

;; ---------- 逐分量算术（int 族）----------
(check-equal? (li (vadd (ivec2 1 2) (ivec2 3 4))) '(4 6))
(check-equal? (li (vdiv (ivec2 7 9) (ivec2 2 2))) '(3 4))          ; 整数除法截断
(check-equal? (li (vmod (ivec2 7 9) (ivec2 3 4))) '(1 1))
(check-equal? (lu (vnot (uvec3 0 1 5))) '(4294967295 4294967294 4294967290))
(check-equal? (lu (vand (uvec2 6 5) (uvec2 3 3))) '(2 1))
(check-equal? (lu (vxor (uvec2 6 5) (uvec2 3 3))) '(5 6))
(check-equal? (lu (vshl (uvec2 1 2) 3)) '(8 16))

;; ---------- 几何 ----------
(check-close (vdot (vec3 1.0 2.0 3.0) (vec3 4.0 5.0 6.0)) 32.0)
(check-equal? (lf (vcross (vec3 1.0 0.0 0.0) (vec3 0.0 1.0 0.0))) '(0 0 1000000))
(check-close (vlength (vec3 3.0 4.0 0.0)) 5.0)
(check-close (vdistance (vec3 1.0 1.0 1.0) (vec3 1.0 1.0 6.0)) 5.0)
(check-equal? (lf (vnormalize (vec3 0.0 3.0 0.0))) '(0 1000000 0))
(check-equal? (lf (vmix (vec2 0.0 0.0) (vec2 10.0 20.0) 0.5)) '(5000000 10000000))
(check-equal? (lf (vclamp (vec3 1.0 -2.0 5.0) 0.0 3.0)) '(1000000 0 3000000))
(check-equal? (lf (vstep 2.0 (vec2 1.0 3.0))) '(0 1000000))
(check-equal? (lf (vreflect (vec3 1.0 -1.0 0.0) (vec3 0.0 1.0 0.0))) '(1000000 1000000 0))

;; ---------- 矩阵：基本（只用 mat4 字面量）----------
(define I4 (mat4-identity))
(check-equal? (lf I4) '(1000000 0 0 0  0 1000000 0 0  0 0 1000000 0  0 0 0 1000000))
(check-equal? (mat4-ref I4 2 2) 1.0)
(check-equal? (mat4-ref I4 2 0) 0.0)
;; 列主序：mat4 字面量按“列”排——A 的第 0 列 = (1,2,3,4)，第 1 列 = (5,6,7,8)…
(define A (mat4 1.0 2.0 3.0 4.0  5.0 6.0 7.0 8.0  9.0 10.0 11.0 12.0  13.0 14.0 15.0 16.0))
(check-equal? (mat4-ref A 0 1) 2.0)          ; 第 0 列第 1 行
(check-equal? (mat4-ref A 1 0) 5.0)          ; 第 1 列第 0 行
;; M·v：乘 (1,0,0,0) 取 A 的第 0 列
(check-equal? (lf (mat4-mul-vec A (vec4 1.0 0.0 0.0 0.0))) '(1000000 2000000 3000000 4000000))
;; v·M：乘 (1,0,0,0) 取 A 的第 0 行
(check-equal? (lf (mat4-vec-mul (vec4 1.0 0.0 0.0 0.0) A)) '(1000000 5000000 9000000 13000000))
;; 转置：元素对调
(check-equal? (mat4-ref (mat4-transpose A) 0 1) (mat4-ref A 1 0))
;; 逆：X · X⁻¹ = I（良态可逆矩阵）
(define X (mat4 2.0 0.2 0.0 0.0
                0.0 3.0 0.3 0.0
                0.0 0.0 4.0 0.0
                1.0 2.0 3.0 1.0))
(check-equal? (lf (mat4-mul X (mat4-inverse X))) (lf I4))
;; add / sub / mul-scalar
(check-equal? (lf (mat4-add I4 I4)) (lf (mat4-mul-scalar I4 2.0)))
(check-equal? (lf (mat4-sub I4 I4)) (lf (mat4-mul-scalar I4 0.0)))
;; dmat
(check-equal? (dmat4-ref (dmat4-identity) 1 1) 1.0)
(check-equal? (ld (dmat4-mul-vec (dmat4-identity) (dvec4 1.0 2.0 3.0 4.0))) '(1.0 2.0 3.0 4.0))

;; ---------- 转换 ----------
(check-equal? (f32vector->list (->f32vector (f64vector 1.0 2.0 3.0))) '(1.0 2.0 3.0))
(check-equal? (s32vector->list (->s32vector (f32vector 1.9 -2.9 0.5))) '(1 -2 0))
(check-equal? (u32vector->list (->u32vector (ivec2 3 4))) '(3 4))
(check-equal? (f32vector->list (->f32vector (gl-vec (vec2 1.0 2.0)))) '(1.0 2.0))
(check-exn exn:fail? (lambda () (->u32vector (s32vector -1))))

;; vec-buffer 按内部 data 的实际 kind 分派（回归：以前 ->f32vector 对 f64 数组返回 f64vector，
;; ->f64vector/->s32vector/->u32vector 对非 f32 数组会在 f32vector->list 处报错）
(check-equal? (f32vector->list (->f32vector (dvec-array (dvec2 1.0 2.0)))) '(1.0 2.0))
(check-equal? (f32vector->list (->f32vector (ivec-array (ivec2 1 2)))) '(1.0 2.0))
(check-equal? (f64vector->list (->f64vector (ivec-array (ivec2 1 2)))) '(1.0 2.0))
(check-equal? (f64vector->list (->f64vector (uvec-array (uvec2 5 6)))) '(5.0 6.0))
(check-equal? (s32vector->list (->s32vector (dvec-array (dvec2 1.9 -2.9)))) '(1 -2))
(check-equal? (u32vector->list (->u32vector (ivec-array (ivec2 3 4)))) '(3 4))
(check-exn exn:fail? (lambda () (->u32vector (dvec-array (dvec2 -1.0 2.0)))))

;; ---------- 错误路径 ----------
(check-exn exn:fail? (lambda () (vadd (vec2 1.0 2.0) (vec3 1.0 2.0 3.0))))     ; 长度不同
(check-exn exn:fail? (lambda () (vadd (vec2 1.0 2.0) (dvec2 1.0 2.0))))        ; 精度不同
(check-exn exn:fail? (lambda () (vadd (vec3 1.0 2.0 3.0) (ivec3 1 2 3))))      ; 类别不同
(check-exn exn:fail? (lambda () (vcross (vec2 1.0 2.0) (vec2 3.0 4.0))))       ; 非 3 分量
(check-exn exn:fail? (lambda () (vnormalize (vec3 0.0 0.0 0.0))))              ; 零向量
(check-exn exn:fail? (lambda () (vsqrt (ivec2 1 2))))                          ; 非 float
(check-exn exn:fail? (lambda () (mat4-inverse (mat4 0.0))))                    ; 奇异
(check-exn exn:fail? (lambda () (mat4-mul I4 (dmat4 1.0))))                    ; 精度不匹配

(displayln "vec-math 全部测试通过")
