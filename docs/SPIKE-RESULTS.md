# Phase 0 Spike 结果:mlx-swift 单进程 Qwen3-ASR 推理验证

> 日期:2026-09-29 · 分支:`refactor/mlx-swift-20260929`
> 结论:**SPIKE 通过**——mlx-swift 可完整跑通 Qwen3-ASR-1.7B-bf16 推理,三个 fixture 对拍全部达标。
> 重构立项的前提条件成立,可进入 Phase 1。

## 1. 环境

| 项 | 值 |
| --- | --- |
| mlx-swift | 0.32.2(SwiftPM 解析的最新版;spike 代码按其 API 修正) |
| Swift / OS | 6.3.3 / macOS 27.0 arm64 |
| 模型 | `mlx-community/Qwen3-ASR-1.7B-bf16`(本地 HF 缓存快照,707 个权重分片 1 个) |
| 参照 | `.venv` 内 mlx_audio 0.32.2(Python 侧同为 0.32.2 内核,保证 kernel 语义一致) |

## 2. 对拍结果(判定线:文本一致或差异仅标点/空格级)

| fixture | 模式 | Python (mlx_audio) | Swift (spike) | 判定 |
| --- | --- | --- | --- | --- |
| chinese.aiff | Chinese | 你好,这是一个本地语音识别测试。今天下午三点开会,请记住数字一二三四五。(19 tok) | **逐字一致**(19 tok) | ✅ 完全一致 |
| chinese.aiff | auto | 同上(22 tok) | 同上(22 tok,含 `language Chinese<asr_text>` 前缀剥除) | ✅ 完全一致 |
| english.aiff | English | This is a local speech recognition test. Please remember the number one, two, three, four, five.(22 tok) | **逐字一致**(22 tok) | ✅ 完全一致 |
| mixed.aiff | auto | 今天我们测试 Python 和 Swift,所有音频都在本地处理。谢谢,谢谢。(19 tok) | 今天我们测试Python和Swift,所有音频都在本地处理。谢谢,谢谢。(19 tok) | ✅ 空格级差异 |

mixed 的空格差异来源:两栈浮点 kernel 累积误差不同,解码第 6 步在近对数分(logit tie)处选择了不同但语义相同的分词(带 Ġ 前缀 vs 不带)。属验收标准明确允许的差异。

## 3. 中间量对拍(逐级验证,均达标)

| 阶段 | 对拍方法 | 最大误差 |
| --- | --- | --- |
| 音频样本(22050→16k 重采样后) | 逐样本 diff | **0(逐位一致)** |
| log-mel 前端 (128×800) | 全量 diff vs transformers 官方输出 | **2.1e-5**(float32 舍入级) |
| 音频编码器输出 (104×2048) | 全量 diff | **3.0e-4**(bf16 权重精度级) |
| prefill 首 token | logits argmax + top5 | **同 id(108386「你好」)**,top5 顺序一致 |

## 4. 性能(release 构建;Python 为热身后数值)

| 指标 | Python (mlx_audio) | Swift (spike, release) | 判定 |
| --- | --- | --- | --- |
| 单次推理(8s 音频,不含模型加载) | 0.75–1.38 s | **0.74 s**(冷启动另加 ~3.5 s Metal kernel JIT) | ✅ ≈1.0×,远优于 ≤1.5× 验收线 |
| GPU 峰值内存 | 未测(参照实现) | **4.7 GB** | Phase 3 需关注:App 常驻模型 + VAD/回放并存的预算要复核 |

Swift 侧含 AVAudioFile 解码+重采样、mel 前端(CPU/vDSP)、编码、贪心解码全流程;Python 侧 `elapsed_s` 仅计 generate。

## 5. spike 过程中发现并修复的问题(Phase 3 移植必读)

1. **权重加载必须用嵌套结构**:`Module.update(parameters:)` 要求嵌套的 `ModuleParameters`,不能用带点号的扁平字典——用 `ModuleParameters(item: NestedItem.unflattened([...]))` 构造。此前扁平构造**静默失败**,整个模型跑的是随机权重(`verify: [.noUnusedKeys]` 可在加载期捕获此类问题,建议 Phase 3 沿用)。
2. **`TextModel` 返回的是归一化隐状态,不是 logits**:argmax 前必须过 tie-embedding 的 `embedTokens.asLinear(_)`。
3. **GPT-2 字节表**:`bytes_to_unicode` 的非打印字节映射是 `U+0100 + n`(n 为非打印字节的顺序计数),不是 `256+字节值`;且不能用单字节 UTF-8 解码构造字符(会变 U+FFFD)。decode 时 `<asr_text>`(special=false)必须保留,语言前缀剥除依赖它。
4. **`featOutLength` 公式**:交接文档中的转抄多了一个 `-1`;正确公式 `leave=n%100; feat=(leave-1)>>1+1; ((feat-1)>>1)>>1+1 + (n/100)*13`,且必须用 Python 向下取整语义(Swift 用算术移位 `>>` 实现)。
5. **有效帧数**:transformers 的 attention mask 语义是 `floor(样本数/160)`,不是 ceil。
6. **hann 窗是周期窗**(`2π/400`),不是对称窗(`2π/399`)。
7. **mel 分块注意力窗口**:窗口切分对象是**整条序列**的 post-CNN 长度(window = maxAfterCnn×8),不是逐 chunk 切。
8. **cblas `beta` 必须 0**:`cblas_dgemm` 会加 `beta×C`,复用输出缓冲时传 1.0 会静默累加出错值。另 `vDSP_mmulD` 行为异常(疑似列主序+越界读),mel/DFT 矩阵乘一律用 `cblas_dgemm`(行主序语义明确)。
9. **AVAudioFile.read 越界抛 nilError**:按 `file.length` 精确读取,不要用「读到返回 0 为止」的循环。
10. **mlx-swift 不自带 Metal kernel 库**:SwiftPM 可执行文件需把 `mlx.metallib` 放到可执行文件同目录(loader 首选 `current_binary_dir()/mlx.metallib`)。开发期可直接复用 `.venv/.../mlx/lib/mlx.metallib`(两侧内核同为 0.32.2,函数签名一致);**Phase 5 打包时需用 `xcrun metal` 从 mlx 源码自行编译**(需完整 Xcode 且已接受许可)。
11. **MLXNN 无 KVCache**:spike 内联实现了约 20 行的 SimpleKVCache(concat 于 axis 2 + offset),语义与 mlx_lm 一致,已验证。

## 6. 后续

- 按 `REFACTOR-MLX-SWIFT.md` §4 启动 Phase 1(`InProcessChannel` + `BackendCore` actor + `ConfigStore`)。
- spike 代码(`spikes/QwenASRSpike/`)将作为 Phase 3 模型层底稿;`SPIKE_DEBUG=1` 环境变量保留了对拍 dump(mel/编码器/首 token logits/字节表),移植期可复用。
- 待办:翻译模型 `Qwen3-4B-Instruct-2507-4bit` 的 MLXLMCommon 流式验证(可并入 Phase 1–2 之间)。
