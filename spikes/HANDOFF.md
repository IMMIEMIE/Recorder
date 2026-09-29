# 交接文档：mlx-swift 单进程重构（Phase 0 spike 已完成 ✅）

> 分支：`refactor/mlx-swift-20260929`
> 日期：2026-09-29（spike 验证当日完成）
> **状态更新：Phase 0 已通过（[docs/SPIKE-RESULTS.md](../docs/SPIKE-RESULTS.md)，三 fixture 对拍达标，性能 ≈ Python 1.0×）；Phase 1–2 已完成（`Sources/Recorder/Backend/` 进程内后端骨架 + 信号链，49 项 Swift 测试与 VAD 对拍全绿），当前下一步为 Phase 3（模型层接入）。**
> 总体规格：[docs/REFACTOR-MLX-SWIFT.md](../docs/REFACTOR-MLX-SWIFT.md)（必读，本文档只覆盖当前进度与下一步）
> 本文档面向：接手 spike 验证与后续实施的开发者（人或 AI 助手）

---

## 1. 项目一句话

声笺要把 Python 双进程后端（`backend/*.py` + 捆绑 1.2 GB Python ML 栈）重写为 mlx-swift 单进程 Swift 实现，安装包从 547 MB 降到 ~100-150 MB。重构分 6 阶段（见规格文档 §4），当前处于 **Phase 0（技术验证 spike）**：证明 mlx-swift 能跑通 Qwen3-ASR 推理。**这是整个项目的生死关：spike 失败则重构不立项**（备选方案见规格文档 §7）。

## 2. 当前进度

### 已完成

1. **重构规格文档** `docs/REFACTOR-MLX-SWIFT.md`：两份深度代码探索（Python 后端 + Swift 侧）汇成移植面清单，含协议全字段、线程模型不变量、组件映射表、6 阶段计划、风险表。
2. **Spike 代码全部写完**（未编译、未运行）：

| 文件 | 内容 | 移植参照（Python 源） |
| --- | --- | --- |
| `spikes/QwenASRSpike/Package.swift` | SwiftPM 包，依赖 `ml-explore/mlx-swift` ≥0.30 | — |
| `spikes/QwenASRSpike/Sources/QwenASRSpike/MelFrontend.swift` | Whisper 式 log-mel 前端：slaney mel 滤波器组（128 mel/201 bin/0-8000 Hz）、center reflect pad（±200 样本）、hann(400)、hop 160、power 2、log10、floor 1e-10、丢末帧、clamp max-8、(x+4)/4、30 s 零填充；vDSP 实现 | `.venv/.../transformers/audio_utils.py` 的 `spectrogram`/`mel_filter_bank` + `models/whisper/feature_extraction_whisper.py` |
| `spikes/QwenASRSpike/Sources/QwenASRSpike/BPETokenizer.swift` | GPT-2 字节级 BPE（vocab.json + merges.txt）+ tokenizer_config.json 的 added_tokens 特殊 token | — |
| `spikes/QwenASRSpike/Sources/QwenASRSpike/Qwen3ASRModel.swift` | 模型全量：音频编码器（3×Conv2d stride2 → linear 投影 → 正弦位置编码 → 24 层块注意力 transformer → proj 到 2048）+ Qwen3 文本解码器（28 层、GQA 16/8、RMSNorm QK、标准 1D RoPE）+ 贪心生成循环 + safetensors 分片加载与 sanitize | `.venv/.../mlx_audio/stt/models/qwen3_asr/qwen3_asr.py`（1743 行主文件已逐行读完） |
| `spikes/QwenASRSpike/Sources/QwenASRSpike/main.swift` | AVFoundation 音频解码 → 16k mono float32 → 特征 → prompt → 端到端转写 | — |
| `spikes/qwen_asr_reference.py` | Python 对拍基准：同一音频走 mlx_audio 原路径出 JSON | — |

3. **代码考古关键结论**（都已验证，写代码时已采用）：
   - `mlx_audio` 的 Qwen3-ASR 文本解码器用**标准 1D RoPE**（`nn.RoPE(head_dim, base=rope_theta)`），忽略 config.json 里的 mrope 设置——Swift 版照做，不需要 M-RoPE。
   - 特殊 token id：audio_start=151669、audio_end=151670、audio_pad=151676、`<|im_end|>`=151645、eos 兜底集合 {151643, 151645}。
   - prompt 模板：`<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|><|audio_pad|>×N<|audio_end|><|im_end|>\n<|im_start|>assistant\nlanguage X<asr_text>`（language 为 auto 时 assistant 前缀为空，模型自己输出 `language X<asr_text>` 需剥掉）。
   - 音频 token 数公式（`featOutLength`，Swift 已实现）：`leave = n%100; feat = (leave-1)/2+1; ((feat-1)/2+1-1-1)/2+1 + (n/100)*13`，n = 有效 mel 帧数 = `ceil(样本数/160)` 上限 3000。
   - 块注意力窗口：`windowAfterCnn = maxAfterCnn * (800/(50*2)) = maxAfterCnn*8`。
   - conv2d 权重：mlx-community 的这份快照已是 MLX 布局（sanitize 里 `is_formatted=True` 分支，不转置）。
   - 后端调用参数：`generate(audio=float32数组, max_tokens=512, language=Config.language or 省略)`，temperature 0（贪心）。

### 中断原因

权限分类器（glm-5.3-flash）持续超时，所有 Bash 命令被挡，无法执行 `swift build`。只读工具（Read/Grep/Glob）不受影响。代码已自查过一轮（修掉 MLXArray 不可变下标赋值、改用拼接实现 audio_pad 嵌入替换、清理死代码），但**未经编译器验证**。

## 3. 下一步（按序执行）

### 3.1 编译 spike（预期要修 API 名）

```bash
cd spikes/QwenASRSpike
swift package resolve      # 拉取 mlx-swift（首次需网络）
swift build
```

预期报错集中在 MLXNN API 签名差异，按编译器提示修：

- `Conv2D` 构造参数：可能是 `inputChannels/outputChannels/kernelSize/stride/padding`（Int 或 tuple）——以报错为准。
- `Embedding`：可能是 `Embedding(_:vocabularySize:embeddingDimensions:)` 或参数顺序不同；`asLinear` 方法名需确认。
- `MLXNN.gelu` / `silu`：可能是自由函数 `MLXNN.gelu(x)` 或 `x.gelu()`；也可能在 MLX 模块。
- `RoPE` 构造与调用：`RoPE(dimensions:traditional:base:)`、`rope(x, offset:)` 签名确认。
- `KVCache`：`cache.update(keys:values:)` 返回元组的调用方式、`cache.offset` 属性名。
- `Linear` bias 参数：`bias: true` 或 `noBias: false`。
- `MLXFast.scaledDotProductAttention` 的 `mask` 参数类型（可选 MLXArray 应该没问题）。
- `loadWeights`：函数名可能是 `MLXNN.loadWeights(url)` 或在别处；返回 `[String: MLXArray]`。
- `model.update(parameters:weights, verify: [.none])`：verify 枚举写法确认。
- main.swift 里 `MLXArray(tokenizer.encode(prompt))`：确认 `[Int]` 初始化器存在，否则 `MLXArray(ids.map { Int32($0) })`。
- `MLX.argmax(x, axis: -1)` 的 API 名可能是 `argMax`。
- `x.item(Int32.self)`：可能是 `x.item()` + 转换。

修到编译通过为止。MelFrontend 纯 Foundation/Accelerate，应该没问题。

### 3.2 生成 Python 基准

```bash
.venv/bin/python spikes/qwen_asr_reference.py \
  ~/Library/Application\ Support/LocalRecorder/models/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/e1f6c266914abc5a46e8756e02580f834a6cf8a7 \
  tests/fixtures/chinese.aiff Chinese
```

（再跑一遍不带 language 的 auto 模式。）记下 JSON 里的 text 和 elapsed_s。

### 3.3 跑 Swift spike 对拍

```bash
.build/debug/QwenASRSpike \
  ~/Library/Application\ Support/LocalRecorder/models/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/e1f6c266914abc5a46e8756e02580f834a6cf8a7 \
  tests/fixtures/chinese.aiff Chinese
```

**判定**：文本一致或差异可解释（标点/空格级别）= spike 通过；乱码/空文本 = 按下面排查。

### 3.4 调试路线（若输出错误，按此顺序排查）

1. **前端对拍**：在 Python 里打印 `_preprocess_audio` 的 `input_features[0,:,0]` 前几帧，与 Swift `MelFrontend.logMel` 同位置比对（误差应 <1e-4）。mel 滤波器组的 slaney 归一化（`enorm = 2/(upper-lower)` 用 Hz 宽度 vs librosa 的 mel 空间带宽）是最可能出错的点——transformers 版在 mel 空间三角化后除以 Hz 宽度，Swift 实现照抄了这一点，但值得先验证。
2. **帧数/有效帧**：`validFrames = ceil(样本数/160)`、`numAudioTokens` 与 Python 一致。
3. **编码器输出**：Python `model.get_audio_features(feats, mask)` 的输出均值/方差 vs Swift `audioTower(...)`。
4. **prompt token 序列**：两边 tokenizer.encode(同一 prompt 字符串) 的 id 序列逐位比对（BPE 实现错误会直接毁掉输入）。
5. **首 token logits**：prefill 后 argmax 的 id 是否与 Python 第一个生成 token 一致——定位问题在前向（权重/结构/RoPE）还是解码循环。

### 3.5 收尾

结果（文本、耗时、GPU 内存、结论）写入 `docs/SPIKE-RESULTS.md`。同时 benchmark Python 版耗时做对比（验收线：Swift 单次推理 ≤ Python 版 1.5 倍）。

## 4. spike 通过后的路线（摘要）

按 `docs/REFACTOR-MLX-SWIFT.md` §4 顺序：

1. **Phase 1**（1 周）：`InProcessChannel`（同形事件字典替代 socket）+ `BackendCore` actor（server.py 的 RLock 域）+ `ConfigStore`。AppModel.handle() 零改动，加 `RECORDER_INPROCESS` 双轨开关。
2. **Phase 2**（1 周）：Segmenter（智能定稿 1800/1000/500 ms 阈值）+ WebRTCVAD 移植 + RecognitionCache + TranslationPlanner，PCM 回放对拍。
3. **Phase 3**（2-3 周）：模型层接入——spike 代码固化为 `Qwen3ASRModel.swift` + Whisper（备选模型，需另移植）+ Translator（MLXLMCommon + 逐 token 让位生成循环）+ ASRAPIClient。
4. **Phase 4**（1 周）：ModelDownloader（保持 HF 缓存布局、`.jinja` 过滤、钉 SHA 续传）。
5. **Phase 5**（3-5 天）：拆 Python、删 runtime、build.sh/package.sh 瘦身。

翻译侧还需一个小验证（可并入 Phase 1-2 之间）：MLXLMCommon 跑 `mlx-community/Qwen3-4B-Instruct-2507-4bit`（已缓存于同目录 models/）流式生成 + `enable_thinking=False`，验证逐 token 让位（AsyncStream + actor）可行。

## 5. 重要约束（不可破坏）

- 模型权重永不进 app bundle（package.sh 检查）。
- 本地推理离线；仅下载/API/LiveTranslate 联网。
- 不持久化原始音频与转写历史。
- HF 缓存目录布局 `models/models--<owner>--<model>/snapshots/<sha>` 必须保持（用户已下载的 4-6 GB 权重要继续可用）。
- 全部中文错误文案、状态机语义逐字保留（清单见规格文档 §6）。
- 用户可见行为不变（详见规格文档 §6 验收标准）。

## 6. 环境备忘

- 模型快照（已缓存）：`~/Library/Application Support/LocalRecorder/models/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/e1f6c266914abc5a46e8756e02580f834a6cf8a7`；翻译模型 `models--mlx-community--Qwen3-4B-Instruct-2507-4bit` 也在。
- Python 参照实现在 `.venv/lib/python3.12/site-packages/`：`mlx_audio/stt/models/qwen3_asr/`（主文件 1743 行）、`mlx_audio/lm/generate.py`（generate_step 118-203 行）、`transformers/audio_utils.py`（mel/spectrogram）、`transformers/models/whisper/feature_extraction_whisper.py`。
- Swift 6.3.3 / macOS 28 arm64。mlx-swift 尚未拉取（`swift package resolve` 未跑成）。
- 测试音频：`tests/fixtures/chinese.aiff` 等（16 kHz 以下需重采样，spike 的 AVFoundation 路径已处理）。
- 分支上有未提交改动：`Sources/Recorder/LiveTranslateAudio.swift`（编译修复：`LiveTranslatePlaybackQueue` 加显式 `init(timing:)`，main 上该文件编译不过）、本文档、规格文档、spike 目录。**建议提交一次作为 spike 基线**。
