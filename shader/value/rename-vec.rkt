#lang racket/base

;; ============================================================
;; 值层 · value/rename-vec.rkt —— GLSL 风格命名（向量运算）
;;
;; 纯 alias：value/vec.rkt 的 Racket 名 → GLSL 名。零逻辑。
;; ============================================================

(require "vec.rkt")

(provide vmap
         vadd vsub vmul vdiv vneg vabs vmin vmax vfloor vceil vfract vmod
         vsqrt vpow vexp vlog vsin vcos vtan vradians vdegrees
         vdot vcross vlength vdistance vnormalize vmix vclamp
         vstep vsmoothstep vreflect vrefract vfaceforward
         vand vor vxor vnot vshl vshr)

(define vmap vec-map)

(define vadd vec-add)
(define vsub vec-sub)
(define vmul vec-mul)
(define vdiv vec-div)
(define vneg vec-neg)
(define vabs vec-abs)
(define vmin vec-min)
(define vmax vec-max)
(define vfloor vec-floor)
(define vceil vec-ceil)
(define vfract vec-fract)
(define vmod vec-mod)

(define vsqrt vec-sqrt)
(define vpow vec-pow)
(define vexp vec-exp)
(define vlog vec-log)
(define vsin vec-sin)
(define vcos vec-cos)
(define vtan vec-tan)
(define vradians vec-radians)
(define vdegrees vec-degrees)

(define vdot vec-dot)
(define vcross vec-cross)
(define vlength vec-length)
(define vdistance vec-distance)
(define vnormalize vec-normalize)
(define vmix vec-mix)
(define vclamp vec-clamp)
(define vstep vec-step)
(define vsmoothstep vec-smoothstep)
(define vreflect vec-reflect)
(define vrefract vec-refract)
(define vfaceforward vec-faceforward)

(define vand vec-and)
(define vor vec-or)
(define vxor vec-xor)
(define vnot vec-not)
(define vshl vec-shift-left)
(define vshr vec-shift-right)
