#lang racket/base

;; ============================================================
;; glsl-compile-test.rkt —— 用真实 glslangValidator 把 GLSL 方言的输出编成 Vulkan SPIR-V
;;
;; 运行：racket test/glsl-compile-test.rkt
;;   GLSLANG=/path/to/glslangValidator  可指定；否则找 PATH 里的
;;   找不到工具时**跳过**（本包本身不依赖外部编译器）。
;;
;; 目的：证明（1）生成的 GLSL 450 + layout(set/binding) 文本是合法的 Vulkan GLSL；
;;       （2）描述符绑定/接口反射与 SPIR-V 一致。
;; ============================================================

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         racket/system
         glsl/rewrite
         glsl/log
         shader/error
         shader/program)

(define glslang
  (or (getenv "GLSLANG")
      (find-executable-path "glslangValidator")))

(define spirv-val (find-executable-path "spirv-val"))
(define spirv-dis (find-executable-path "spirv-dis"))

(when (not glslang)
  (displayln "glsl-compile-test: 未找到 glslangValidator，跳过（本包不依赖外部编译器）")
  (exit 0))

(displayln (format "glsl-compile-test: glslangValidator = ~a" glslang))

(define tmpdir (make-temporary-file "glsl-check-~a" 'directory))

(define (compile! base stage prog)
  (define src-path (build-path tmpdir (format "~a.glsl" base)))
  (define spv-path (build-path tmpdir (format "~a.spv" base)))
  (call-with-output-file src-path #:exists 'replace
    (lambda (o) (write-string (shader-program-src prog) o)))
  (define out
    (with-output-to-string
      (lambda ()
        (parameterize ([current-error-port (current-output-port)])
          (unless (system* glslang "-V" src-path "-S" stage "-o" spv-path)
            (error 'glsl-compile-test "glslangValidator 失败：~a" (shader-program-src prog)))))))
  (unless (file-exists? spv-path)
    (error 'glsl-compile-test "没有产出 SPIR-V：~a" out))
  (when spirv-val
    (parameterize ([current-error-port (current-output-port)])
      (unless (system* spirv-val spv-path)
        (error 'glsl-compile-test "spirv-val 失败：~a" (shader-program-src prog)))))
  spv-path)

(define (descriptor-bindings spv-path)
  (define dis (with-output-to-string (lambda () (system* spirv-dis spv-path))))
  (define sets (make-hash))
  (for ([ln (in-list (string-split dis "\n"))])
    (define m (regexp-match #rx"OpDecorate %([^ ]+) DescriptorSet ([0-9]+)" ln))
    (when m (hash-set! sets (list-ref m 1) (string->number (list-ref m 2)))))
  (sort
   (for/list ([ln (in-list (string-split dis "\n"))]
              #:when (regexp-match #rx"OpDecorate %([^ ]+) Binding [0-9]+" ln))
     (define m (regexp-match #rx"OpDecorate %([^ ]+) Binding ([0-9]+)" ln))
     (cons (hash-ref sets (list-ref m 1) 0) (string->number (list-ref m 2))))
   (lambda (a b) (or (< (car a) (car b))
                     (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))

;; ---------- 顶点：std140 UBO + 属性 + mul ----------

(define vs
  (glsl (version 450)
        (layout (set 0) (binding 0) (std140) uniform (block Camera (mat4 view) (mat4 proj)) cam)
        (layout (location 0) in vec3 aPos)
        (define (main) void
          (set! gl_Position (mul (.proj cam) (mul (.view cam) (vec4 aPos 1.0)))))))

(define vs.spv (compile! "vs" "vert" vs))
(check-equal? (descriptor-bindings vs.spv) '((0 . 0)))

;; ---------- 片元：out 变量 + 采样 ----------

(define fs
  (glsl (version 450)
        (layout (set 0) (binding 1) uniform sampler2D uTex)
        (layout (location 0) in vec2 vUV)
        (layout (location 0) out vec4 FragColor)
        (define (main) void
          (set! FragColor (texture uTex vUV)))))

(define fs.spv (compile! "fs" "frag" fs))
(check-equal? (descriptor-bindings fs.spv) '((0 . 1)))

;; ---------- 计算：std430 SSBO + local_size ----------

(define cs
  (glsl (version 450)
        (layout (set 0) (binding 0) (std430) readonly buffer (block Src ((array float) src)) s)
        (layout (set 0) (binding 1) (std430) writeonly buffer (block Dst ((array float) dst)) d)
        (layout (local-size-x 64) in)
        (define (main) void
          (uint i (.x gl_GlobalInvocationID))
          (set! (aref (.dst d) i) (* (aref (.src s) i) 2.0)))))

(define cs.spv (compile! "cs" "comp" cs))
(check-equal? (descriptor-bindings cs.spv) '((0 . 0) (0 . 1)))

;; ---------- 驱动日志解析（Mesa 格式）----------

(define errs (parse-error-log "0:12(5): error: `y' undeclared\n"))
(check-equal? (map shader-error-line errs) '(12))

(delete-directory/files tmpdir)
(displayln "glsl-compile-test: 全部通过")
