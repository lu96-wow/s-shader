#lang racket/base

;; ============================================================
;; experiments/slang-vulkan-compute.rkt —— Slang 方言产出的 SPIR-V 真跑在 Vulkan 上
;;
;; 运行：
;;   SLANGC=~/Desktop/work/tools/bin/slangc \
;;   VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
;;   racket experiments/slang-vulkan-compute.rkt
;;
;; 它把整条链路串起来：
;;   1. `(slang ...)` 生成 Slang 文本（push constant + StructuredBuffer + RWStructuredBuffer）
;;   2. slangc 编译成 SPIR-V（`-target spirv -matrix-layout-column-major`）
;;   3. racket-vulkan 建 instance/device/pipeline/descriptor set，dispatch 一次
;;   4. 读回 dst，逐元素校验 dst[i] = src[i] * scale
;;
;; 依赖：slangc（外部）、racket-vulkan、Vulkan ICD、可选的校验层。
;; 本文件不参与包编译（info.rkt 的 compile-omit-paths 含 experiments）。
;; ============================================================

(require racket/file
         racket/list
         racket/port
         racket/string
         racket/system
         ffi/unsafe
         ffi/vector
         slang/rewrite
         shader/program
         vulkan)

;; ---------- 0. 找 slangc ----------

(define slangc (or (getenv "SLANGC") (find-executable-path "slangc")))
(unless slangc
  (eprintf "需要 slangc：设 SLANGC=/path/to/slangc 或把它放进 PATH\n")
  (exit 0))

;; ---------- 1. 生成 Slang 并编译成 SPIR-V ----------

(define nthreads 8)
(define n 8.0)

(define cs
  (slang
    (push-const Push (float scale) (uint count))
    (resource src (sbuffer float) (set 0) (binding 0))
    (resource dst (rw-sbuffer float) (set 0) (binding 1))
    (define (cs-main (uint3 id SV-DispatchThreadID))
            (attr (shader compute) (numthreads 8 1 1)) void
      (uint i (.x id))
      (if (>= i count) (return))
      (set! (aref dst i) (* (aref src i) scale)))))

(define (compile! prog)
  (define tmp (make-temporary-file "slang-compute-~a" 'directory))
  (define src (build-path tmp "cs.slang"))
  (define spv (build-path tmp "cs.spv"))
  (call-with-output-file src #:exists 'replace
    (lambda (o) (write-string (shader-program-src prog) o)))
  (define ok?
    (parameterize ([current-error-port (current-output-port)])
      (system* slangc src "-target" "spirv" "-entry" "cs_main" "-stage" "compute"
               "-matrix-layout-column-major" "-o" spv)))
  (unless (and ok? (file-exists? spv))
    (error 'experiment "slangc 编译失败"))
  (define bytes (file->bytes spv))
  (delete-directory/files tmp)
  (printf "[ok] slangc: ~a 字节 SPIR-V\n" (bytes-length bytes))
  bytes)

(define spv-bytes (compile! cs))

;; ---------- 2. Vulkan 样板 ----------

(define (fail! msg) (error 'experiment msg))

;; instance
(define-values (_instance0 instance)
  (vkCreateInstance
   (lambda ()
     (define app (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                         #f #"slang-compute" 0 #"racket-shader" 0 VK_API_VERSION_1_2))
     (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
             #f 0 app 0 #f 0 #f))
   #f))
(void (vk-use-instance! instance))
(printf "[ok] instance\n")

;; physical device
(define physical-device
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkEnumeratePhysicalDevices instance cnt #f)
    (define arr (vk-malloc _VkPhysicalDevice (ptr-ref cnt _uint32)))
    (raw:vkEnumeratePhysicalDevices instance cnt arr)
    (ptr-ref arr _VkPhysicalDevice)))

;; compute queue family
(define queue-family-index
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt #f)
    (define nn (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkQueueFamilyProperties nn))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt arr)
    (or (for/fold ([acc #f]) ([i (in-range nn)] #:break acc)
          (define p (ptr-ref arr _VkQueueFamilyProperties i))
          (if (and (> (VkQueueFamilyProperties-queueCount p) 0)
                   (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags p)
                                            VK_QUEUE_COMPUTE_BIT))))
              i #f))
        (fail! "没有 compute 队列族"))))
(printf "[ok] compute queue family = ~a\n" queue-family-index)

;; device + queue
(define-values (_device0 device)
  (vkCreateDevice physical-device
   (lambda ()
     (define prio (vk-malloc _float))
     (ptr-set! prio _float 1.0)
     (define qci (vk-new make-VkDeviceQueueCreateInfo VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                         #f 0 queue-family-index 1 prio))
     (vk-new make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
             #f 0 1 qci 0 #f 0 #f #f))
   #f))
(void (vk-use-device! device))

(define queue
  (let ()
    (define p (vk-malloc _VkQueue))
    (raw:vkGetDeviceQueue device queue-family-index 0 p)
    (ptr-ref p _VkQueue)))
(printf "[ok] device + queue\n")

;; ---------- 3. 两个 host-visible 存储缓冲 ----------

(define elem-count 8)
(define buffer-size (* 4 elem-count))   ; float32 × 8

(define (memory-type-index type-bits properties)
  (define pdmp (vk-zero _VkPhysicalDeviceMemoryProperties))
  (raw:vkGetPhysicalDeviceMemoryProperties physical-device pdmp)
  (define mp (ptr-ref pdmp _VkPhysicalDeviceMemoryProperties))
  (or (for/fold ([acc #f])
                ([i (in-range (VkPhysicalDeviceMemoryProperties-memoryTypeCount mp))] #:break acc)
        (define mt (array-ref (VkPhysicalDeviceMemoryProperties-memoryTypes mp) i))
        (if (and (not (zero? (bitwise-and type-bits (arithmetic-shift 1 i))))
                 (= (bitwise-and (VkMemoryType-propertyFlags mt) properties) properties))
            i #f))
      (fail! "找不到合适的显存类型")))

;; 建一个 host-visible/coherent 的 storage buffer；返回 (values buffer memory)
(define (make-storage-buffer)
  (define-values (_b buffer)
    (vkCreateBuffer device
     (lambda ()
       (vk-new make-VkBufferCreateInfo VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
               #f 0 buffer-size VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
               VK_SHARING_MODE_EXCLUSIVE 0 #f))
     #f))
  (define req-p (vk-zero _VkMemoryRequirements))
  (raw:vkGetBufferMemoryRequirements device buffer req-p)
  (define req (ptr-ref req-p _VkMemoryRequirements))
  (define-values (_m memory)
    (vkAllocateMemory device
     (lambda ()
       (vk-new make-VkMemoryAllocateInfo VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
               #f (VkMemoryRequirements-size req)
               (memory-type-index (VkMemoryRequirements-memoryTypeBits req)
                                  (bitwise-ior VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))))
     #f))
  (raw:vkBindBufferMemory device buffer memory 0)
  (values buffer memory))

(define-values (src-buffer src-memory) (make-storage-buffer))
(define-values (dst-buffer dst-memory) (make-storage-buffer))
(printf "[ok] storage buffers\n")

;; 填 src：0,1,2,...,7
(let ()
  (define p (vk-malloc _pointer))
  (raw:vkMapMemory device src-memory 0 buffer-size 0 p)
  (define fp (ptr-ref p _pointer))
  (for ([i (in-range elem-count)]) (ptr-set! fp _float i (exact->inexact i)))
  (raw:vkUnmapMemory device src-memory))

;; ---------- 4. descriptor set + pipeline layout + pipeline ----------

(define-values (_dsl0 descriptor-set-layout)
  (vkCreateDescriptorSetLayout device
   (lambda ()
     (define bs (vk-malloc _VkDescriptorSetLayoutBinding 2))
     (ptr-set! bs _VkDescriptorSetLayoutBinding 0
               (vk-new make-VkDescriptorSetLayoutBinding
                       0 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1 VK_SHADER_STAGE_COMPUTE_BIT #f))
     (ptr-set! bs _VkDescriptorSetLayoutBinding 1
               (vk-new make-VkDescriptorSetLayoutBinding
                       1 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1 VK_SHADER_STAGE_COMPUTE_BIT #f))
     (vk-new make-VkDescriptorSetLayoutCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
             #f 0 2 bs))
   #f))

(define-values (_pool0 descriptor-pool)
  (vkCreateDescriptorPool device
   (lambda ()
     (define s (vk-new make-VkDescriptorPoolSize VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 2))
     (vk-new make-VkDescriptorPoolCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
             #f 0 2 1 s))
   #f))

(define-values (_sets0 descriptor-sets)
  (vkAllocateDescriptorSets device
   (lambda ()
     (define l (vk-malloc _VkDescriptorSetLayout))
     (ptr-set! l _VkDescriptorSetLayout 0 descriptor-set-layout)
     (vk-new make-VkDescriptorSetAllocateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
             #f descriptor-pool 1 l))))
(define descriptor-set (vector-ref descriptor-sets 0))

(let ()
  (with-vk-arena
    (define i0 (vk-new make-VkDescriptorBufferInfo src-buffer 0 buffer-size))
    (define i1 (vk-new make-VkDescriptorBufferInfo dst-buffer 0 buffer-size))
    (define ws (vk-malloc _VkWriteDescriptorSet 2))
    (ptr-set! ws _VkWriteDescriptorSet 0
              (vk-new make-VkWriteDescriptorSet VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                                                #f descriptor-set 0 0 1
                                                VK_DESCRIPTOR_TYPE_STORAGE_BUFFER #f i0 #f))
    (ptr-set! ws _VkWriteDescriptorSet 1
              (vk-new make-VkWriteDescriptorSet VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                                                #f descriptor-set 1 0 1
                                                VK_DESCRIPTOR_TYPE_STORAGE_BUFFER #f i1 #f))
    (raw:vkUpdateDescriptorSets device 2 ws 0 #f)))
(printf "[ok] descriptor set\n")

;; push constant: { float scale; uint count; } = 8 字节
(define push-size 8)

(define-values (_layout0 pipeline-layout)
  (vkCreatePipelineLayout device
   (lambda ()
     (define l (vk-malloc _VkDescriptorSetLayout))
     (ptr-set! l _VkDescriptorSetLayout descriptor-set-layout)
     (define r (vk-new make-VkPushConstantRange VK_SHADER_STAGE_COMPUTE_BIT 0 push-size))
     (vk-new make-VkPipelineLayoutCreateInfo VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
             #f 0 1 l 1 r))
   #f))

(define-values (_module0 shader-module)
  (vkCreateShaderModule device
   (lambda ()
     (define code (stable-bytes spv-bytes))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (bytes-length spv-bytes) code))
   #f))

(define pipeline
  (let ()
    (define-values (_p0 ps)
      (vkCreateComputePipelines device
       (lambda ()
         (define name (stable-bytes #"main"))     ; slangc 把入口名固定为 "main"
         (define ssci (vk-new make-VkPipelineShaderStageCreateInfo
                              VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                              #f 0 VK_SHADER_STAGE_COMPUTE_BIT shader-module name #f))
         (vector (vk-new make-VkComputePipelineCreateInfo VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
                                                          #f 0 ssci pipeline-layout #f 0)))
       #f #f))
    (vector-ref ps 0)))
(printf "[ok] compute pipeline\n")

;; ---------- 5. 录制命令 + 提交 ----------

(define-values (_cp0 command-pool)
  (vkCreateCommandPool device
   (lambda () (vk-new make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                                    #f 0 queue-family-index))
   #f))

(define-values (_cb0 command-buffers)
  (vkAllocateCommandBuffers device
   (lambda () (vk-new make-VkCommandBufferAllocateInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                                                       #f command-pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 1))))
(define command-buffer (vector-ref command-buffers 0))

;; push constant 数据：{ float scale = 2.0; uint count = 8; } —— 8 字节
(define pc (vk-malloc _uint32 2))
(ptr-set! pc _float 0 2.0)
(ptr-set! pc _uint32 1 elem-count)

(let ()
  (with-vk-arena
    (define cbbi (vk-new make-VkCommandBufferBeginInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                         #f VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT #f))
    (raw:vkBeginCommandBuffer command-buffer cbbi)
    (raw:vkCmdBindPipeline command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline)
    (define sets (vk-malloc _VkDescriptorSet))
    (ptr-set! sets _VkDescriptorSet descriptor-set)
    (raw:vkCmdBindDescriptorSets command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline-layout
                                 0 1 sets 0 #f)
    (raw:vkCmdPushConstants command-buffer pipeline-layout VK_SHADER_STAGE_COMPUTE_BIT
                            0 push-size pc)
    (raw:vkCmdDispatch command-buffer 1 1 1)    ; 8 个线程 = 一个 workgroup
    (raw:vkEndCommandBuffer command-buffer)))

(define-values (_f0 fence)
  (vkCreateFence device
   (lambda () (vk-new make-VkFenceCreateInfo VK_STRUCTURE_TYPE_FENCE_CREATE_INFO #f 0))
   #f))

(let ()
  (with-vk-arena
    (define cb (vk-malloc _VkCommandBuffer))
    (ptr-set! cb _VkCommandBuffer command-buffer)
    (define si (vk-new make-VkSubmitInfo VK_STRUCTURE_TYPE_SUBMIT_INFO #f 0 #f #f 1 cb 0 #f))
    (define fences (vk-malloc _VkFence))
    (ptr-set! fences _VkFence fence)
    (raw:vkQueueSubmit queue 1 si fence)
    (raw:vkWaitForFences device 1 fences VK_TRUE (* 10 1000000000))))
(printf "[ok] submitted + waited\n")

;; ---------- 6. 读回并校验 ----------

(define dst-floats
  (let ()
    (define p (vk-malloc _pointer))
    (raw:vkMapMemory device dst-memory 0 buffer-size 0 p)
    (define fp (ptr-ref p _pointer))
    (define out (for/list ([i (in-range elem-count)]) (ptr-ref fp _float i)))
    (raw:vkUnmapMemory device dst-memory)
    out))

(printf "[ok] dst = ~a\n" dst-floats)
(define expected (for/list ([i (in-range elem-count)]) (exact->inexact (* 2 i))))
(unless (andmap = dst-floats expected)
  (eprintf "结果不符：期望 ~a，实际 ~a\n" expected dst-floats)
  (exit 1))
(printf "全部通过：Slang → SPIR-V → Vulkan compute 结果 = ~a\n" dst-floats)
