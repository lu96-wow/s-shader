#lang racket/base

;; ============================================================
;; 共享词汇 · types.rkt —— GLSL 内建类型名 + 别名表
;;
;; 这是**类型词汇表**的共享底座：
;;   - interface.rkt 用它做完整类型目录 / 反射；
;;   - value/type.rkt 用它把 CPU 类型查询（glsl-size / type-kind …）规范化。
;;
;; ★ 与 glsl/names.rkt 的分工：
;;   names.rkt     处理**标识符**（变量 / 函数 / 关键字别名）
;;   本模块        处理**内建类型名**（vec3 / sampler2D / mat3x2 …）
;;
;; 别名规则（与 names.rkt 的 kebab / 全小写下划线风格一致）：
;;   vec3            → vec-3 / vec_3
;;   ivec2           → ivec-2 / ivec_2
;;   mat3x2          → mat-3x2 / mat_3x2
;;   sampler2D       → sampler-2d / sampler_2d
;;   sampler2DArray  → sampler-2d-array / sampler_2d_array
;;   isampler2D      → isampler-2d / isampler_2d
;;   image2D         → image-2d / image_2d
;;   atomic_uint     → atomic-uint
;;
;; 规范拼写（vec3 / sampler2D / …）永远可用；别名只增加入口，不改变 canonical 名。
;; ============================================================

(require racket/list racket/string)

(provide builtin-glsl-type-names
         builtin-scalar-names builtin-vector-names
         builtin-matrix-square-names builtin-matrix-rect-names
         builtin-sampler-names builtin-image-names
         glsl-builtin-type? glsl-type-alias?
         glsl-type-canonical-name glsl-type-canonical-symbol
         glsl-type-alias-forms)

;; ---------- 规范类型名清单（唯一来源） ----------
(define builtin-scalar-names '(float int uint bool double void atomic_uint))

(define builtin-vector-names
  (for*/list ([p '("" "i" "u" "b" "d")] [n '(2 3 4)])
    (string->symbol (format "~avec~a" p n))))

(define builtin-matrix-square-names
  (for*/list ([p '("" "d")] [n '(2 3 4)])
    (string->symbol (format "~amat~a" p n))))

(define builtin-matrix-rect-names
  (for*/list ([p '("" "d")] [c '(2 3 4)] [r '(2 3 4)])
    (string->symbol (format "~amat~ax~a" p c r))))

(define builtin-sampler-names
  '(sampler1D sampler2D sampler3D samplerCube
    sampler1DArray sampler2DArray samplerCubeArray
    sampler2DMS sampler2DMSArray samplerBuffer
    sampler2DRect sampler2DRectShadow
    sampler1DShadow sampler2DShadow samplerCubeShadow
    sampler1DArrayShadow sampler2DArrayShadow samplerCubeArrayShadow
    isampler1D isampler2D isampler3D isamplerCube
    isampler1DArray isampler2DArray isamplerCubeArray
    isampler2DMS isampler2DMSArray isamplerBuffer isampler2DRect
    usampler1D usampler2D usampler3D usamplerCube
    usampler1DArray usampler2DArray usamplerCubeArray
    usampler2DMS usampler2DMSArray usamplerBuffer usampler2DRect))

(define builtin-image-names
  '(image1D image2D image3D imageCube
    image1DArray image2DArray imageCubeArray
    image2DMS image2DMSArray imageBuffer
    iimage1D iimage2D iimage3D iimageCube
    iimage1DArray iimage2DArray iimageCubeArray
    iimage2DMS iimage2DMSArray iimageBuffer
    uimage1D uimage2D uimage3D uimageCube
    uimage1DArray uimage2DArray uimageCubeArray
    uimage2DMS uimage2DMSArray uimageBuffer))

(define builtin-glsl-type-names
  (append builtin-scalar-names builtin-vector-names
          builtin-matrix-square-names builtin-matrix-rect-names
          builtin-sampler-names builtin-image-names))

;; ---------- canonical → 别名 ----------
;; 返回一个 kebab-case 字符串；没有别名返回 #f。
(define (vector-alias name)
  (define m (regexp-match #rx"^(i|u|b|d)?vec([234])$" (symbol->string name)))
  (and m (format "~avec-~a" (or (cadr m) "") (caddr m))))

(define (matrix-alias name)
  (define m (regexp-match #rx"^(d)?mat([234])(?:x([234]))?$" (symbol->string name)))
  (and m (format "~amat-~a~a"
                 (or (cadr m) "") (caddr m)
                 (if (cadddr m) (format "x~a" (cadddr m)) ""))))

(define sampler-suffixes
  '(("1D" . "1d") ("2D" . "2d") ("3D" . "3d") ("Cube" . "cube")
    ("1DArray" . "1d-array") ("2DArray" . "2d-array")
    ("CubeArray" . "cube-array")
    ("2DMS" . "2d-ms") ("2DMSArray" . "2d-ms-array") ("Buffer" . "buffer")
    ("2DRect" . "2d-rect") ("2DRectShadow" . "2d-rect-shadow")
    ("1DShadow" . "1d-shadow") ("2DShadow" . "2d-shadow")
    ("CubeShadow" . "cube-shadow")
    ("1DArrayShadow" . "1d-array-shadow")
    ("2DArrayShadow" . "2d-array-shadow")
    ("CubeArrayShadow" . "cube-array-shadow")))

(define image-suffixes
  '(("1D" . "1d") ("2D" . "2d") ("3D" . "3d") ("Cube" . "cube")
    ("1DArray" . "1d-array") ("2DArray" . "2d-array")
    ("CubeArray" . "cube-array")
    ("2DMS" . "2d-ms") ("2DMSArray" . "2d-ms-array")
    ("Buffer" . "buffer")))

(define (sampler-or-image-alias name prefix-word suffixes)
  (define s (symbol->string name))
  (define m (regexp-match (regexp (format "^(i|u)?~a(.+)$" prefix-word)) s))
  (and m
       (let ([suffix (assoc (caddr m) suffixes)])
         (and suffix
              (format "~a~a-~a" (or (cadr m) "") prefix-word (cdr suffix))))))

(define (canonical->alias name)
  (cond
    [(eq? name 'atomic_uint) "atomic-uint"]
    [(memq name builtin-vector-names) (vector-alias name)]
    [(memq name builtin-matrix-square-names) (matrix-alias name)]
    [(memq name builtin-matrix-rect-names) (matrix-alias name)]
    [(memq name builtin-sampler-names) (sampler-or-image-alias name "sampler" sampler-suffixes)]
    [(memq name builtin-image-names) (sampler-or-image-alias name "image" image-suffixes)]
    [else #f]))

;; 一个 canonical 名的全部别名（kebab + 全小写下划线；去掉与 canonical 相同的）
(define (alias-forms-for name)
  (define kebab (canonical->alias name))
  (and kebab
       (let* ([snake (string-replace kebab "-" "_")]
              [forms (if (string=? kebab snake) (list kebab) (list kebab snake))])
         (for/list ([s (in-list forms)] #:unless (string=? s (symbol->string name)))
           (cons (string->symbol s) name)))))

;; ---------- 别名表 ----------
(define canonical-table
  (for/hash ([n (in-list builtin-glsl-type-names)]) (values n #t)))

(define alias-table
  (for*/fold ([h (hash)]) ([n (in-list builtin-glsl-type-names)]
                           [p (in-list (or (alias-forms-for n) (quote ())))])
    (define alias (car p))
    (when (hash-has-key? h alias)
      (error 'type-names "类型别名冲突：~a → ~a" alias n))
    (hash-set h alias n)))

(define glsl-type-alias-forms
  (sort (for/list ([(alias canonical) (in-hash alias-table)])
          (cons alias canonical))
        (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))))

;; ---------- 查询 ----------

(define (as-string who x)
  (cond
    [(symbol? x) (symbol->string x)]
    [(string? x) x]
    [else (error who "需要 symbol 或 string，实际 ~s" x)]))

;; 规范/别名 → canonical 字符串；不是内建类型返回 #f。
(define (glsl-type-canonical-name x)
  (define s (as-string 'glsl-type-canonical-name x))
  (define sym (string->symbol s))
  (cond
    [(hash-ref canonical-table sym #f) s]
    [(hash-ref alias-table sym #f) => symbol->string]
    [else #f]))

;; 规范/别名 → canonical symbol；未知类型原样返回（让上层报「未知类型」）。
(define (glsl-type-canonical-symbol x)
  (define s (as-string 'glsl-type-canonical-symbol x))
  (string->symbol (or (glsl-type-canonical-name s) s)))

;; 是不是内建类型（规范名或别名）
(define (glsl-builtin-type? x)
  (and (or (symbol? x) (string? x))
       (and (glsl-type-canonical-name x) #t)))

;; 这个拼写是不是别名（而不是 canonical 名）
(define (glsl-type-alias? x)
  (define s (as-string 'glsl-type-alias? x))
  (and (hash-ref alias-table (string->symbol s) #f) #t))
