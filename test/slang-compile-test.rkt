#lang racket/base

;; ============================================================
;; slang-compile-test.rkt —— 用真实 slangc 编译我们生成的 Slang
;;
;; 运行：racket test/slang-compile-test.rkt
;;   SLANGC=/path/to/slangc  可指定编译器；否则找 PATH 里的 slangc
;;   找不到 slangc 时**跳过**（打印说明，不失败）——本包本身不依赖外部工具。
;;
;; 验证点：
;;   ① 生成的 Slang 文本能被 slangc 接受（这才是 [[vk::binding]] / cbuffer /
;;      ParameterBlock / 语义注解这些「约定」的真正验证）
;;   ② 产物是合法 SPIR-V（有 spirv-val 就再验一遍）
;;   ③ 反射信息与 SPIR-V 里的描述符绑定一致（DescriptorSet/Binding 检查）
;; ============================================================

(require rackunit
         racket/system
         racket/file
         racket/list
         racket/port
         racket/string
         slang/rewrite
         slang/log
         shader/error
         shader/program)

(define slangc
  (or (getenv "SLANGC")
      (find-executable-path "slangc")))

(define spirv-val (find-executable-path "spirv-val"))
(define spirv-dis (find-executable-path "spirv-dis"))

(define tmpdir (make-temporary-file "slang-check-~a" 'directory))

(define (dump! name src)
  (define p (build-path tmpdir name))
  (call-with-output-file p #:exists 'replace (lambda (o) (write-string src o)))
  p)

;; 编译一个 stage；返回 spv 路径；失败时把 slangc 输出一起报出来
(define (compile-stage! base stage entry prog)
  (define src-path (dump! (format "~a.slang" base) (shader-program-src prog)))
  (define spv-path (build-path tmpdir (format "~a.spv" base)))
  (define out
    (with-output-to-string
      (lambda ()
        (parameterize ([current-error-port (current-output-port)])
        (unless (system* slangc src-path
                         "-target" "spirv"
                         "-entry" entry
                         "-stage" stage
                         ;; CPU 值层与 GLSL 都是列主序；Slang 默认行主序
                         "-matrix-layout-column-major"
                         "-o" spv-path)
          (error 'slang-compile-test "slangc 失败：\n~a" (shader-program-src prog)))))))
  (unless (file-exists? spv-path)
    (error 'slang-compile-test "没有产出 SPIR-V：~a" out))
  ;; SPIR-V 合法性
  (when spirv-val
    (define val-out
      (with-output-to-string
        (lambda ()
          (unless (system* spirv-val spv-path)
            (error 'slang-compile-test "spirv-val 失败：\n~a" out)))))
    (void val-out))
  spv-path)

;; SPIR-V 里的 (DescriptorSet . Binding) 列表（按 set、binding 排序）
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

(when (not slangc)
  (displayln "slang-compile-test: 未找到 slangc，跳过（本包不依赖外部编译器）")
  (exit 0))

(displayln (format "slang-compile-test: slangc = ~a" slangc))

;; ---------- ① 顶点：cbuffer + 结构体语义 + mul ----------

(define vs
  (slang
    (struct VS-IN (float3 pos POSITION) (float2 uv TEXCOORD0))
    (struct VS-OUT (float4 pos SV-Position) (float2 uv TEXCOORD0))
    (cbuffer Camera (set 0) (binding 0) (float4x4 view) (float4x4 proj))
    (define (vs-main (VS-IN i)) (attr (shader vertex)) VS-OUT
      (VS-OUT o)
      (set! (.pos o) (mul proj (mul view (float4 (.pos i) 1.0))))
      (set! (.uv o) (.uv i))
      o)))

(define vs.spv (compile-stage! "vs" "vertex" "vs_main" vs))
(check-true (file-exists? vs.spv))
(check-equal? (descriptor-bindings vs.spv) '((0 . 0)))

;; ---------- ② 片元：writes SV_Target + 采样 ----------

(define fs
  (slang
    (struct FS-IN (float2 uv TEXCOORD0))
    (param-block Materials mat (set 0) (binding 0)
      ((texture-2d float4) albedo)
      (sampler-state samp))
    (define (fs-main (FS-IN i)) (attr (shader fragment)) float4
      (sample (.albedo mat) (.samp mat) (.uv i)))))

(define fs.spv (compile-stage! "fs" "fragment" "fs_main" fs))
;; ParameterBlock 的成员由 Slang 顺序分配 binding
(check-equal? (descriptor-bindings fs.spv) '((0 . 0) (0 . 1)))

;; ---------- ③ 计算：push-const + 存储缓冲 + RW 缓冲 ----------

(define cs
  (slang
    (push-const Push (float scale) (uint count))
    (resource src (sbuffer float) (set 0) (binding 0))
    (resource dst (rw-sbuffer float) (set 0) (binding 1))
    (define (cs-main (uint3 id SV-DispatchThreadID))
            (attr (shader compute) (numthreads 64 1 1)) void
      (uint i (.x id))
      (if (>= i count) (return))
      (set! (aref dst i) (* (aref src i) scale)))))

(define cs.spv (compile-stage! "cs" "compute" "cs_main" cs))
(check-equal? (descriptor-bindings cs.spv) '((0 . 0) (0 . 1)))

;; ---------- ④ 编译器错误能落到我们的日志解析上 ----------

(define bad-src "void main() { float x = y; }")
(define bad-path (dump! "bad.slang" bad-src))
(define log
  (with-output-to-string
    (lambda ()
      (parameterize ([current-error-port (current-output-port)])
        (void (system* slangc bad-path "-target" "spirv"
                        "-entry" "main" "-stage" "fragment"
                        "-o" (build-path tmpdir "bad.spv")))))))
(check-true (string? log))
;; Slang 的日志位置是 file:line:col；我们的解析器应能取出行号
(define errs (parse-error-log log))
(check-true (ormap (lambda (e) (and (shader-error-line e) #t)) errs))

(delete-directory/files tmpdir)
(displayln "slang-compile-test: 全部通过")
