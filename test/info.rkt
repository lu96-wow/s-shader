#lang info
;; 不参与 `raco setup` 的编译（测试/实验按需 `raco test` / 手跑即可）。
;; 注意：多集合包里包根 info.rkt 的 compile-omit-paths 对**非集合目录**不生效，
;; 所以每个这类目录单独放一个 info.rkt。
(define compile-omit-paths 'all)
