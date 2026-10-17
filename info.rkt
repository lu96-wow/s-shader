#lang info
;; ============================================================
;; racket-glsl —— 纯 GLSL 包（collection: glsl）
;;
;; #lang glsl：只装 GLSL 语言 + CPU 值层 + 报错层，不依赖 opengl。
;; OpenGL 绑定 / 编译 / 链接在另一个包 racket-glsl-opengl（collection: glsl-opengl），
;; 它依赖本包：
;;   #lang glsl-opengl   →   (require glsl) + OpenGL 层
;;
;; 本仓库就是独立的 racket-glsl 包（仓库根 = 包根）。
;; 安装（在仓库根执行）：
;;   raco pkg install --link .
;; OpenGL 层是另一个独立包 racket-glsl-opengl，不在本仓库内。
;; ============================================================

(define collection "glsl")

(define deps '("base"))
(define build-deps '("rackunit-lib"))   ; core-test 用

;; core-test 只是本仓库的测试，不参与包编译 / `raco setup`（`raco test` 仍可显式运行）。
(define compile-omit-paths '("core-test"))

(define pkg-desc "GLSL DSL for Racket: #lang glsl (language + CPU value layer, no OpenGL)")
(define pkg-authors '("lu96"))
(define license '("MIT"))
