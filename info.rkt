#lang info
;; ============================================================
;; racket-shader —— 着色语言 DSL 包（collection: shader）
;;
;; 三个语言入口（都是本集合的子集合）：
;;   #lang shader        core：CPU 值层 + 类型词汇表（不含任何方言）
;;   #lang shader/glsl   core + (glsl ...) 宏（GLSL 方言）
;;   #lang shader/slang  core + (slang ...) 宏（Slang 方言，step 4 落地）
;;
;; 目录即依赖边界：
;;   types.rkt value/     ← 方言无关（core）
;;   glsl/                ← 只 require core，不认识 slang/
;;   slang/               ← 只 require core，不认识 glsl/
;;
;; 迁移计划见 PLAN-racket-shader.md。
;; ============================================================

(define collection "shader")

(define deps '("base"))
(define build-deps '("rackunit-lib"))   ; test 用

;; test 只是本仓库的测试，不参与包编译 / `raco setup`（`raco test` 仍可显式运行）。
(define compile-omit-paths '("test"))

(define pkg-desc "Shader DSLs for Racket: #lang shader/glsl (GLSL), #lang shader/slang (Slang)")
(define pkg-authors '("lu96"))
(define license '("MIT"))
