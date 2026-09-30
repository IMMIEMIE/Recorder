# 交接文档：mlx-swift 单进程重构（Phase 0–2 已完成 ✅，Phase 3 代码已落地待 macOS 验证）

> 分支：`refactor/mlx-swift-20260929`
> 日期：2026-09-29（Phase 0–2 同日完成；Phase 3 模型层代码同日提交，尚未在 macOS 上编译/对拍）
> **状态更新：Phase 0 spike 通过（[docs/SPIKE-RESULTS.md](../docs/SPIKE-RESULTS.md)）；Phase 1–2 进程内后端骨架与信号链已落地（`Sources/Recorder/Backend/`，49 项 Swift 测试全绿、VAD 对拍逐帧一致，提交 `3fa60d2`、`bebad79`）。Phase 3 的 Qwen3-ASR 引擎、本地翻译引擎、AppModel 注入与 `RecorderVerify` 对拍工具已编写（`Sources/RecorderMLX/`、`Sources/Recorder/Engines/`），但编写环境为 Linux 云端容器，无 Swift 工具链与 Metal，**代码未经编译**。下一步：在 Apple Silicon Mac 上按 §4「Phase 3 验证清单」编译、修正、对拍。**
> 总体规格：[docs/REFACTOR-MLX-SWIFT.md](../docs/REFACTOR-MLX-SWIFT.md)（必读；其 §4 Phase 1–2 后已附「实施备注」记录实现与规格的偏差）
> 本文档面向：接手后续实施的开发者（人或 AI 助手）

---

## 1. 项目一句话

声笺要把 Python 双进程后端（`backend/*.py` + 捆绑 1.2 GB Python ML 栈，安装包 547 MB）重写为 mlx-swift 单进程 Swift 实现，目标 ~100-150 MB。重构分 6 阶段（规格文档 §4），**Phase 0–2 已完成；Phase 3 代码（含 Whisper）已全部写完，待 macOS 编译验证**。

## 2. 已完成的工作

### Phase 0 — 技术验证 spike（提交 `3fa60d2`）

- `spikes/QwenASRSpike/` SwiftPM 包：自移植 Qwen3-ASR 全模型（音频塔 + Qwen3 解码器）+ Whisper 式 mel 前端 + GPT-2 字节级 BPE，跑通端到端转写。
- 对拍结果：中文/英文 fixture 与 Python mlx_audio 逐字一致，混合 fixture 仅空格级差异（近义 token 浮动，规格允许）；release 构建单次推理 0.74s vs Python 0.75s（≈1.0×，验收线 ≤1.5×）；GPU 峰值内存 4.7 GB（Phase 3 复核）。
- 结论与 11 条移植教训全部写入 [docs/SPIKE-RESULTS.md](../docs/SPIKE-RESULTS.md)。**Phase 3 动手前必读**，关键条目：权重加载必须 `NestedItem.unflattened` + `verify: [.noUnusedKeys]`（扁平 key 会静默加载失败跑随机权重）；mlx-swift 0.32.2 不带 metallib，需把 venv mlx 0.32.2 的 `mlx.metallib` 放到二进制旁；mel 前端用 cblas_dgemm（vDSP_mmulD 不可靠且复用缓冲必须 beta=0）；BPE 字节表用顺序计数器映射；`<asr_text>` 是 special:false，解码时不能被跳过。

### Phase 1 — 进程内通道与后端骨架（提交 `bebad79`）

新文件均在 `Sources/Recorder/Backend/`：

| 文件 | 内容 |
| --- | --- |
| `BackendTypes.swift` | `RATE/FRAME/MAX_MESSAGE`、`TRANSLATION_TARGETS`、SegmentJob/StreamFinal、引擎协议（`ASREngine`/`TranslatorEngine`/`APIRecognizing`）、BackendError（携带 Python 异常名，错误事件文本逐字一致） |
| `ConfigStore.swift` | Config/TranslationConfig 校验与原子写（.tmp + chmod 0600 + rename）；JSON 数值严格类型检查（Python `type(v) is int` 语义；Swift 的 `NSNumber is Bool` 恒真陷阱用 objCType 绕开） |
| `BackendCore.swift` | server.py 全量语义的 actor：命令分发（hello/load/download/translation_settings/asr_stream_final/cancel_download/start/stop）、状态机、jobs 优先级（final > 翻译 > preview 单槽）、翻译逐 token 让位（自持 AsyncThrowingStream 迭代，jobs 非空即挂起）、过载自动停止（jobs≥6）、`final_segments` 防重、异常路径清缓存保文字、全部中文文案逐字保留。重活（推理/加载/翻译）为 off-actor await，控制命令不被推理阻塞。附 `ASRValidation`（adapter.validate_config 的 Swift 版）与 Phase 3 前的 Placeholder 引擎 |
| `InProcessChannel.swift` | 替代 socket Transport：同形事件字典、同序投递（hello → config+translator+status）、320 KB 背压计数、onFailure。`BackendChannel` 协议由 Transport/InProcessChannel 共同实现，AppModel 只面向协议 |
| `ASRAPIClient.swift` | asr_api.py 原样移植（URLSession + multipart WAV + 90 s 超时 + 拒重定向 + 2 MB 上限 + 错误文案）。属 Phase 3 计划，因 `load_api` 路径依赖而提前 |
| `ModelCache.swift` | model_cache.py 的 `resolve_cached_model` 算法（显式 revision 硬错误、refs/main → mtime 扫描兜底），HF 缓存布局保持 `models--<owner>--<model>/snapshots/<sha>`。属 Phase 4 计划，因 `load` 路径依赖而提前 |

AppModel 改动最小化：`transport` 换成 `BackendChannel?`；`launch()` 按 `RECORDER_INPROCESS` 编译开关走进程内分支（root 目录与 initial-config 拷贝逻辑与 Python 分支一致；attach 与首条 hello 存在 Task 竞态，core 先缓冲事件、attach 后按序补发）；`handle()` 及所有 UI **零改动**。

### Phase 2 — 信号链移植（同一提交）

| 文件 | 内容 |
| --- | --- |
| `Segmenter.swift` | core.py Segmenter 全量：预卷 240 ms、智能定稿阈值 1800/1000/500、`accept_preview` 后重查阈值、`sentence_complete`（句末标点正则逐一对照）、flush |
| `WebRTCVAD.swift` + `Sources/Cwebrtcvad/` | WebRTC VAD C 源码直接编入 SwiftPM C target（与 Python webrtcvad wheel 同源代码）；`scripts/verify_vad.sh` 生成混合信号 golden，与 Python wheel **逐帧对拍 0 差异** |
| `RecognitionCache.swift` | recognition.py 全量：last_voiced 命中、18 s 切块逐块缓存、`forget`/`clear` 时机 |
| `TranslationPlanner.swift` | translation.py 全量：单元规划、forced-cut 遗留（剥 `CUT_PUNCTUATION`、MAX_CARRY=400）、`already_in_target` 脚本计数、`same_text`、`build_messages`（Hunyuan 单轮/其余 system+2 组上下文）、`validate_translator` |

### Phase 3 — 模型层接入（代码已提交，**未编译、未对拍**）

编写环境无 Swift 工具链（Linux 容器，swift.org 下载被网络策略拦截），以下代码按 mlx-swift 0.32.2、mlx-swift-lm（main `c043fb3`）、swift-transformers 1.3.x 的源码 API 手工核对编写，首次在 Mac 上编译时预计仍需少量修正。

**构建开关改为 manifest 级**：`Package.swift` 读取 `RECORDER_INPROCESS=1` 环境变量，此时才加入 mlx-swift（exact 0.32.2）、mlx-swift-lm（按 revision 钉住，它尚无兼容 0.32 的 tag）、swift-transformers 依赖、`RecorderMLX`/`RecorderVerify` target，并给 `Recorder` target 加 `RECORDER_INPROCESS` define。默认构建与所有 `scripts/test_*.sh` 完全不变（不拉 MLX，`Engines/` 目录被 exclude）。`build.sh` 的进程内分支改为 `export RECORDER_INPROCESS=1` 并把 `.venv` 的 `mlx.metallib` 拷进 `Contents/Resources/`；AppModel 启动时 `MLXRuntime.configure(metallib:)` 指向它（`GPU.metallib`）。

| 文件 | 内容 |
| --- | --- |
| `Sources/RecorderMLX/MLXRuntime.swift` | 全部模型工作（加载/预热/推理/逐 token/卸载）串行跑在一条专用 DispatchQueue 上（对应 Python 单 worker 线程，也避免阻塞协作线程池）；`configure(metallib:)`、`clearCache()`（`Memory.clearCache`）、`peakMemory` |
| `Sources/RecorderMLX/Qwen3ASR/Qwen3ASRModel.swift` | spike 模型固化：尺寸改从 `config.json`（含 `thinker_config` 嵌套）解析；支持 `quantization`（仅量化文本解码器，按 `.scales` 存在判断，对齐 `model_quant_predicate`）；非 tie 模型保留 `lm_head`；去掉 SPIKE_DEBUG 转储 |
| `Sources/RecorderMLX/Qwen3ASR/MelFrontend.swift` | **与 spike 的差异**：spike 固定补零到 30 s，而 mlx_audio 实际以 `padding=True, truncation=False` 调用特征提取器（不补 30 s，log-mel 最大值只在真实帧上取，末帧反射填充取真实音频）。现按真实长度计算，与 Python 生产路径一致，也省去 30 s 的 CPU 计算；DFT 与 mel 改为整块 `cblas_dgemm`（仍 beta=0、行主序） |
| `Sources/RecorderMLX/Qwen3ASR/ASRTokenizer.swift` | spike BPE 固化（`<asr_text>` special:false 保留、字节表顺序计数）；读取 `eos_token` |
| `Sources/RecorderMLX/Qwen3ASR/Qwen3ASR.swift` | `load_model + generate` 对应：权重 sanitize（剥 `thinker.`、tie 时丢 `lm_head`、未转换 HF 卷积转置）、`NestedItem.unflattened` + `.noUnusedKeys`；**不足 1 s 补零到 1 s**（`split_audio_into_chunks` 的 `min_chunk_duration`，spike 未覆盖，影响预热与短片段的音频 token 数）；`support_languages` 大小写匹配；EOS = tokenizer eos ∪ `<|im_end|>`/`<|endoftext|>`；auto 模式按 `extract_language` 语义剥「language X<asr_text>」；`max_tokens=512` |
| `Sources/RecorderMLX/TextGenerator.swift` | 翻译：`LLMModelFactory.load(from: 目录)` + 自写 swift-transformers 分词器桥（等价 MLXHuggingFace 宏展开，免宏插件与 Hub 客户端）；qwen3 模板传 `enable_thinking: false`；贪心（temperature 0）；停止词 = config/generation_config eos ∪ tokenizer eos。`MLXGenerationSession.step()` **拉一次只解一个 token**（`TokenIterator`，首步做 prefill），返回累计译文（结尾 U+FFFD 的半个字符暂扣，结束时补发） |
| `Sources/Recorder/Engines/MLXASREngine.swift` | `ASREngine` 实现：按 `model_type` 分派 Qwen3-ASR / Whisper（Whisper 语言按 `WHISPER_LANGUAGES` 映射：auto→自动检测、Chinese→zh、Cantonese→yue…）；预热 16000 字节静音；卸载后在 MLX 队列上 `clearCache` |
| `Sources/RecorderMLX/NPZ.swift` | `.npz` 读取器（mlx-swift 只能读 safetensors）：按中央目录取尺寸（numpy 的本地文件头是 zip64 占位）、支持 zip64、stored/deflate（Compression 框架 `COMPRESSION_ZLIB` 即裸 DEFLATE）、`.npy` v1–v3。用于 `mel_filters.npz` 与旧式 `weights.npz` |
| `Sources/RecorderMLX/Whisper/WhisperModel.swift` | mlx_whisper `whisper.py` 移植：编码器（Conv1d×2 + 正弦位置编码）、解码器（`positional_embedding` 参数、fp16 下饱和为 -inf 的因果 mask）、q/k 各乘 `head_dim^-0.25` + `precise` softmax、自注意力/交叉注意力 KV cache；支持 `quantization`（Linear/Embedding 且存在 `.scales`） |
| `Sources/RecorderMLX/Whisper/WhisperTokenizer.swift` | tiktoken 字节级 BPE（按 rank 合并）+ Whisper 特殊 token 编号（语言数随 `n_vocab`）；`non_speech_tokens` 用同一算法的 Python 原型在 multilingual.tiktoken 上核对过，与 Whisper 公开的 suppress 列表逐项一致 |
| `Sources/RecorderMLX/Whisper/Whisper.swift` | `transcribe()` 等价实现（adapter 参数：fp16、temperature 0 无回退、不以前文为条件、`sample_len=224`、默认 no_speech 0.6 / logprob -1.0、开时间戳）：GPU 上以相同 float32 算子算 log-mel（尾部补 30 s 静音）；auto 时用前 30 s 检测语言；逐窗口贪心解码 + SuppressBlank / SuppressTokens / ApplyTimestampRules（mlx-whisper 0.4.3 中「时间戳不递减」规则因用序号切片而实际为空操作，照此不复现）；无语音跳窗、按连续时间戳切段与 seek 推进、清掉瞬时/空白段；另加一处保护：seek 不前进时强制跳过整窗（Python 在该极端情况下会死循环） |
| `assets/whisper/` | mlx-whisper 0.4.3 的 `mel_filters.npz`、`multilingual.tiktoken`、`gpt2.tiktoken` 原样入库（MIT，sha256 见该目录 README）；`build.sh` 进程内分支拷到 `Contents/Resources/whisper/`，AppModel 设 `ASRValidation.whisperAssets` 指向它，校验缺失时报与 Python 相同的「Whisper 运行环境缺失…」「Whisper 离线辅助资源缺失: …」 |
| `Sources/Recorder/Engines/MLXTranslatorEngine.swift` | `TranslatorEngine` 实现：`AsyncThrowingStream(unfolding:)` 惰性拉取——BackendCore 在 jobs 非空时停止调用 `next()`，GPU 即让给识别，与 Python 挂起生成器语义一致；丢弃迭代器即释放 KV cache；`build_messages`/`max_tokens` 复用 `TranslationText` |
| `Sources/RecorderVerify/main.swift` + `scripts/verify_inprocess.sh` | 对拍 CLI：`asr`（等价 verify_model.py：AVAudioFile→16 kHz→PCM16 量化→转写，输出 load/warmup/逐文件耗时/`mlx_peak_bytes`）与 `translate`（首 token 延迟、tokens/s）。报告写入 `docs/model-verification-swift.json`、`docs/translation-verification-swift.json` |

其他：`TranslationText.maxTokens` 改按 Unicode 标量计数（Python `len()` 语义，原先按字素簇）。

### 测试基建

- `scripts/test_backend.sh` + `tests/BackendTests.swift`：移植 `tests/test_core.py`、`test_endpoint.py`、`test_translation.py` 的断言（swiftc 显式文件列表 + `@main` 模式，与现有 `test_ai.sh` 一致），**49 项全绿**。覆盖：配置校验/原子写、分帧/预卷/智能定稿、识别缓存复用、规划器、翻译让位与抢占、API/流式路径、过载、hello 竞态。
- `scripts/verify_vad.sh`：VAD 对拍（可复跑）。
- 双轨开关：`RECORDER_INPROCESS=1`（环境变量）；**默认关闭，仍走 Python sidecar**。Phase 1–2 时为 `-Xswiftc -DRECORDER_INPROCESS`（两种编译均验证通过）；Phase 3 起改由 `Package.swift` 读取环境变量，同时控制 MLX 依赖与 define（见上文）。

## 3. 已知偏差与阶段缺口（均有明确中文报错，不影响双轨默认路径）

1. **Phase 3 代码未编译**：见上文；首要任务是在 Mac 上 `RECORDER_INPROCESS=1 swift build` 并修正编译错误。
2. **模型下载未接入**（Phase 4）：in-process 模式下 `download` 命令与翻译模型下载返回「下载功能尚未接入，请等待后续版本更新」；`cancel_download` 为 no-op。
3. **Whisper 未验证**：代码与 Qwen 部分一样未经编译；`ASRValidation.whisperAssets` 为 nil（后端测试、默认构建）时仍跳过资产检查。`word_timestamps`、温度回退、束搜索等 adapter 不用的 mlx_whisper 功能未移植。
4. **Hunyuan-MT 分词器**：swift-transformers 的 `AutoTokenizer.from(modelFolder:)` 需要 `tokenizer.json`；若 `mlx-community/Hunyuan-MT-7B-4bit` 快照只有 tiktoken 词表，加载会失败（报错会走翻译失败路径，不影响识别），需实测。
5. **metallib 来源**：开发期与进程内打包都复用 `.venv` 中 mlx 0.32.2 wheel 的 `mlx.metallib`；Phase 5 删 Python 后需改为从 mlx 源码编译（完整 Xcode + `xcrun metal`）。

## 4. 待完成的工作（按序执行）

### Phase 3 — 验证与收尾（**下一步**）

**Phase 3 验证清单**（需 Apple Silicon Mac、`.venv`、`models/` 下已缓存的默认两个模型）：

1. `RECORDER_INPROCESS=1 swift build -c release`：修正编译错误（重点核对：`quantize(model:filter:)` 重载、`TokenIterator`/`GenerateParameters` 初始化、`LLMModelFactory.load(from:using:)`、`AsyncThrowingStream(unfolding:)`、AVAudioConverter 回调）。同时确认默认 `swift build`、`scripts/test_backend.sh` 等仍通过。
2. `./scripts/verify_inprocess.sh asr`：三个 fixture 与 `docs/model-verification.json`（Python）对比，要求逐字一致或仅标点/空格差异；另跑 `--language Chinese`。若与 spike 结论出现偏差，先怀疑 MelFrontend 改为「不补 30 s」这一处（可临时补零到 480000 样本对照）。
3. `./scripts/verify_inprocess.sh whisper`（需已缓存 `whisper-large-v3-turbo`）：与 `docs/whisper-verification.json` 对比文本；另跑 `--language Chinese`。`./scripts/test_backend.sh` 新增的 `whisper validation` 用例也应通过。
4. `./scripts/verify_inprocess.sh translate`：确认 `enable_thinking=False` 生效（输出不含 `<think>`）、译文合理；对比 `docs/translation-verification.json` 的吞吐（±30%）。Hunyuan-MT 若已缓存一并试。
5. `RECORDER_INPROCESS=1 ./scripts/build.sh` 后运行 app：加载→预热→麦克风转写→开启本地翻译→切换 Qwen/Whisper/翻译模型；观察翻译逐 token 让位（识别 final 不被翻译拖慢）、切模型先卸载后加载的 GPU 内存（`MLXRuntime.peakMemory`/活动监视器）。
6. 结果写入 `docs/VALIDATION.md`，并在规格文档 §4 Phase 3「实施备注」补上验证结论。

**Phase 3 剩余开发**：

- `verify_pipeline.py`/`verify_endpoints.py` 场景（实时节奏 PCM 经 BackendCore 全链路）可在 `RecorderVerify` 增加 `pipeline` 子命令复现——需要把 `Sources/Recorder/Backend` 拆成库 target 或在 CLI 中复用 swiftc 文件列表方式，按需决定。

### Phase 4 — 下载器（1 周）

`ModelDownloader.swift`：`HubApi`（swift-transformers）或自写——model_info(files_metadata) → 扩展名过滤（**含 `.jinja`**）→ 钉 commit SHA 逐文件下载 → 进度回调映射 `progress` 事件（含 `role` 区分 ASR/翻译）→ 取消（保留已缓存 blob 续传）。替换 BackendCore 中「下载功能尚未接入」的两处报错，实现 downloader 状态与 `cancel_download`。验收：下载后缓存目录布局与 Python 版逐字节同构，同一份缓存可被双轨互相识别。

### Phase 5 — 拆除与瘦身（3–5 天）

- 删 `Transport.swift` socket 实现、AppModel `launch()` 进程逻辑、`backend/` 目录、`requirements.lock`、runtime 打包。
- `build.sh`/`package.sh`：去掉 Python runtime 组装与 `initial-config.json` 钉 revision（改由 Swift 端做）；`RECORDER_INPROCESS` 开关转正；metallib 改为源码编译（需完整 Xcode 并接受许可，`xcrun metal`）。
- 更新 README/CLAUDE 架构描述；版本号 bump。预期 DMG ~100-150 MB。
- 验收：全新安装全流程回归；旧安装（已有 models 缓存与 config.json/translation.json）升级后无损可用；`scripts/package.sh` 拒绝打包权重的检查继续生效。

## 5. 重要约束（不可破坏）

- 模型权重永不进 app bundle（package.sh 检查）。
- 本地推理离线；仅下载/API/LiveTranslate 联网。
- 不持久化原始音频与转写历史。
- HF 缓存目录布局 `models/models--<owner>--<model>/snapshots/<sha>` 必须保持（用户已下载的 4-6 GB 权重要继续可用）。
- 全部中文错误文案、状态机语义逐字保留（清单见规格文档 §6）。
- 用户可见行为不变（详见规格文档 §6 验收标准）。
- 前端负数单元 ID：`-1` API 翻译、`-2` LiveTranslate；本地翻译必须用正数 ≥1（BackendCore 已遵守）。

## 6. 环境备忘

- 模型快照（已缓存）：`~/Library/Application Support/LocalRecorder/models/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/e1f6c266914abc5a46e8756e02580f834a6cf8a7`；翻译模型 `models--mlx-community--Qwen3-4B-Instruct-2507-4bit` 也在。
- Python 参照实现：`.venv/lib/python3.12/site-packages/` 下 `mlx_audio/stt/models/qwen3_asr/`、`mlx_audio/lm/generate.py`、`transformers/audio_utils.py`、`transformers/models/whisper/feature_extraction_whisper.py`；webrtcvad C 源取自 webrtcvad-wheels 2.0.14 sdist。
- Swift 6.3.3 / macOS arm64；mlx-swift 解析为 0.32.2。注意：新版工具链下 `AsyncThrowingStream` 用 `makeAsyncIterator()`（`makeIterator` 不存在）。
- 常用命令：`swift build`（默认，Python sidecar）/ `RECORDER_INPROCESS=1 swift build`（进程内，含 MLX 依赖；不再需要 `-Xswiftc -D`）；`./scripts/test_backend.sh`；`./scripts/verify_vad.sh`；`./scripts/verify_inprocess.sh [asr|translate]`。
- 依赖参照源码：mlx-whisper 0.4.3 wheel（`transcribe.py`、`decoding.py`、`whisper.py`、`tokenizer.py`、`audio.py`）；mlx-swift 0.32.2（`GPU.metallib`、`Memory.clearCache`、`quantize(model:filter:)`）、mlx-swift-lm main（`MLXLMCommon/Evaluate.swift` 的 `TokenIterator`、`ModelFactory.swift` 的 `load(from:using:)`、`MLXHuggingFaceMacros` 中分词器桥的写法）、mlx-audio 0.5.1 wheel（`mlx_audio/stt/models/qwen3_asr/qwen3_asr.py`）。
- 提交记录：`3fa60d2` Phase 0 spike；`bebad79` Phase 1–2；Phase 3 模型层见本分支后续提交。spike 的调试经验（对拍方法、常见数值坑）在 `docs/SPIKE-RESULTS.md`，Phase 3 移植时先读。
