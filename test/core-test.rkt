#lang racket/base
;; ============================================================
;; GLSL 核心（Layer 0）测试：用 require 引入，不用 #lang
;; 运行：racket test/core-test.rkt
;; ============================================================
(require rackunit
         ffi/vector
         "../glsl/core.rkt"
         "../shader/pretty.rkt")

;; ---------- 原语断言 ----------
(check-equal? (glsl-version 330 "core") "#version 330 core\n")
(check-equal? (glsl-version 300 "es")   "#version 300 es\n")

;; 预处理指令（每个都独占一行、结尾 \n）
(check-equal? (glsl-macro-define "FOO" #f "1") "#define FOO 1\n")
(check-equal? (glsl-macro-define "FOO" #f "") "#define FOO\n")
(check-equal? (glsl-macro-define "MAX" '("a" "b") "((a) > (b) ? (a) : (b))") "#define MAX(a, b) ((a) > (b) ? (a) : (b))\n")
(check-equal? (glsl-macro-undef "FOO") "#undef FOO\n")
(check-equal? (glsl-macro-ifdef "FOO") "#ifdef FOO\n")
(check-equal? (glsl-macro-ifndef "FOO") "#ifndef FOO\n")
(check-equal? (glsl-macro-if 1) "#if 1\n")
(check-equal? (glsl-macro-elif "(FOO > 3)") "#elif (FOO > 3)\n")
(check-equal? (glsl-macro-else) "#else\n")
(check-equal? (glsl-macro-endif) "#endif\n")
(check-equal? (glsl-macro-error "unsupported") "#error unsupported\n")
(check-equal? (glsl-macro-pragma "STDGL invariant(all)") "#pragma STDGL invariant(all)\n")
(check-equal? (glsl-macro-extension "GL_OES_standard_derivatives" "enable")
              "#extension GL_OES_standard_derivatives : enable\n")

(check-equal? (glsl-in "vec2" "aPos") "in vec2 aPos;")
(check-equal? (glsl-out "vec4" "FragColor") "out vec4 FragColor;")
(check-equal? (glsl-uniform "float" "uTime") "uniform float uTime;")
(check-equal? (glsl-const "float" "k" "0.5") "const float k = 0.5;")
(check-equal? (glsl-decl '() "vec2" "p" "(vUV * 2.0)") "vec2 p = (vUV * 2.0);")
(check-equal? (glsl-decl '() "float" "d") "float d;")
(check-equal? (glsl-decl '("in" "flat") "int" "i") "in flat int i;")
(check-equal? (glsl-layout '(("location" 0)) '("in") "vec2" "aPos")
              "layout(location = 0) in vec2 aPos;")
(check-equal? (glsl-layout '("std140") '("uniform") "Block" "b")
              "layout(std140) uniform Block b;")

(check-equal? (glsl-call "mix" "a" "b" "t") "mix(a, b, t)")
(check-equal? (glsl-ctor "vec3" "0.1" "0.2" "0.3") "vec3(0.1, 0.2, 0.3)")
(check-equal? (glsl-bin "+" "a" "b" "c") "(a + b + c)")
(check-equal? (glsl-bin "&&" "a" "b") "(a && b)")
(check-equal? (glsl-unary "-" "x") "(-x)")
(check-equal? (glsl-ternary "c" "a" "b") "(c ? a : b)")
(check-equal? (glsl-assign "a" "b") "a = b")
(check-equal? (glsl-cassign "*" "c" "x") "c *= x")
(check-equal? (glsl-swizzle "xy" "v") "v.xy")
(check-equal? (glsl-field "pos" "s") "s.pos")
(check-equal? (glsl-aref "a" "i") "a[i]")
(check-equal? (glsl-inc "x") "++x")
(check-equal? (glsl-inc "x" #t) "x++")

(check-equal? (glsl-stmt (glsl-assign "a" "b")) "a = b;")
(check-equal? (glsl-block (glsl-stmt (glsl-assign "a" "b"))
                          (glsl-return "a"))
              "{ a = b; return a; }")
(check-equal? (glsl-if "x" (glsl-stmt (glsl-assign "a" "b")))
              "if (x) { a = b; }")
(check-equal? (glsl-if "x" (glsl-stmt (glsl-assign "a" "b")) (glsl-stmt (glsl-assign "a" "c")))
              "if (x) { a = b; } else { a = c; }")
(check-equal? (glsl-for (glsl-decl '() "int" "i" "0") "(< i n)" (glsl-inc "i")
                        (glsl-stmt (glsl-assign "x" "i")))
              "for (int i = 0; (< i n); ++i) { x = i; }")
(check-equal? (glsl-while "(< i n)" (glsl-stmt (glsl-inc "i")))
              "while ((< i n)) { ++i; }")
(check-equal? (glsl-do-while "(< i n)" (glsl-stmt (glsl-inc "i")))
              "do { ++i; } while ((< i n));")
(check-equal? (glsl-switch "mode"
                            (list (list "1" "{ c = a; }") (list "2" "{ c = b; }"))
                            "{ c = z; }")
              "switch (mode) { case 1: { c = a; } case 2: { c = b; } default: { c = z; } }")
;; 有理数拒绝
(check-exn exn:fail? (lambda () (glsl-bin "+" 1/2 1)))
(check-equal? (glsl-break) "break;")
(check-equal? (glsl-continue) "continue;")
(check-equal? (glsl-return) "return;")
(check-equal? (glsl-return "v") "return v;")
(check-equal? (glsl-discard) "discard;")

(check-equal? (glsl-param '() "vec3" "p") "vec3 p")
(check-equal? (glsl-param '("out") "float" "r") "out float r")
(check-equal? (glsl-fn "main" "void" '() (glsl-stmt (glsl-assign "a" "b")))
              "void main() { a = b; }")
(check-equal? (glsl-fn "sq" "float" (list (glsl-param '() "float" "x"))
                       (glsl-return (glsl-bin "*" "x" "x")))
              "float sq(float x) { return (x * x); }")
(check-equal? (glsl-struct-decl "Light" (glsl-field-decl "vec3" "pos") (glsl-field-decl "float" "i"))
              "struct Light { vec3 pos; float i; };")

;; ---------- 美化（shader-pretty）断言 ----------
(check-equal? (shader-pretty "if (x) { a = b; } else { a = c; }")
              "if (x) {\n  a = b;\n} else {\n  a = c;\n}")
(check-equal? (shader-pretty "for (int i = 0; i < n; ++i) { x = i; }")
              "for (int i = 0; i < n; ++i) {\n  x = i;\n}")
(check-equal? (shader-pretty "do { x = i; } while (i < n);")
              "do {\n  x = i;\n} while (i < n);")
(check-equal? (shader-pretty "uniform Camera { mat4 view; } cam;")
              "uniform Camera {\n  mat4 view;\n} cam;")

;; ---------- 02 课片元着色器（核心层组装 + 美化） ----------
(define p-expr   (glsl-bin "-" (glsl-bin "*" "vUV" 2.0) 1.0))
(define d-expr   (glsl-call "length" "p"))
(define ring-expr (glsl-call "fract" (glsl-bin "-" (glsl-bin "*" "d" 6.0) "uTime")))
(define c0-expr  (glsl-call "mix"
                            (glsl-ctor "vec3" "0.10" "0.15" "0.40")
                            (glsl-ctor "vec3" "0.10" "0.70" "1.00") "ring"))
(define c-mul-rhs (glsl-bin "-" "1.0" (glsl-bin "*" "0.55" "d")))
(define c-add-rhs (glsl-bin "*" (glsl-ctor "vec3" "0.15")
                            (glsl-bin "+" "0.5"
                                      (glsl-bin "*" "0.5"
                                                (glsl-call "sin" (glsl-bin "*" "uTime" 2.0))))))
(define corner-cond (glsl-bin "&&"
                              (glsl-bin ">" (glsl-swizzle "x" "p") "0.15")
                              (glsl-bin ">" (glsl-swizzle "y" "p") "0.15")))
(define corner-c (glsl-ctor "vec3"
                            (glsl-bin "+" (glsl-bin "*" (glsl-swizzle "x" "p") "0.5") "0.5")
                            (glsl-bin "+" (glsl-bin "*" (glsl-swizzle "y" "p") "0.5") "0.5")
                            (glsl-bin "+" "0.5"
                                      (glsl-bin "*" "0.4"
                                                (glsl-call "sin" (glsl-bin "+" "uTime"
                                                                         (glsl-bin "*" (glsl-swizzle "x" "p") "3.0")))))))
(define frag-color (glsl-ctor "vec4" (glsl-call "clamp" "c" "0.0" "1.0") "1.0"))

(define frag
  (glsl-shader
   (glsl-version 330 "core")
   (glsl-in "vec2" "vUV")
   (glsl-uniform "float" "uTime")
   (glsl-out "vec4" "FragColor")
   (glsl-fn "main" "void" '()
     (glsl-decl '() "vec2" "p" p-expr)
     (glsl-decl '() "float" "d" d-expr)
     (glsl-decl '() "float" "ring" ring-expr)
     (glsl-decl '() "vec3" "c" c0-expr)
     (glsl-stmt (glsl-cassign "*" "c" c-mul-rhs))
     (glsl-stmt (glsl-cassign "+" "c" c-add-rhs))
     (glsl-if corner-cond (glsl-stmt (glsl-assign "c" corner-c)))
     (glsl-stmt (glsl-assign "FragColor" frag-color)))))

(displayln "===== 02 课片元着色器（核心层组装，未美化）=====")
(displayln frag)
(newline)
(displayln "===== 美化后 =====")
(displayln (shader-pretty frag))
