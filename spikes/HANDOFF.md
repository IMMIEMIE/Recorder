# 交接文档：mlx-swift 单进程重构（Phase 0–3 已完成 ✅，Phase 4 下载器代码已落地待 macOS 验证）

> 分支：`refactor/mlx-swift-20260929`
> 日期：2026-09-29（Phase 0–2 完成、Phase 3 代码提交）；2026-09-30（Phase 3 在 macOS 上编译并对拍通过；Phase 4 下载器代码提交，尚未在 macOS 上编译）
> **状态更新：Phase 0 spike 通过（[docs/SPIKE-RESULTS.md](../docs/SPIKE-RESULTS.md)）；Phase 1–2 进程内后端骨架与信号链已落地（提交 `3fa60d2`、`bebad79`）。Phase 3 模型层（Qwen3-ASR、Whisper、本地翻译）已在 Apple Silicon Mac 上编译并对拍：三个 fixture 的 Qwen3-ASR 与 Whisper 转写与 Python 逐字一致（修正见提交 `4b338d2`、`aefe7d2`）。Phase 4 下载器（`Sources/Recorder/Backend/ModelDownloader.swift`）与 BackendCore 的 download/cancel_download 已编写，编写环境为 Linux 云端容器，**代码未经编译**。下一步：在 Mac 上按 §4「Phase 4 验证清单」编译、跑测试、与 Python 缓存对拍。**
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

### Phase 3 — 模型层接入（macOS 编译、对拍通过 ✅）

2026-09-30 在 Apple Silicon Mac（macOS 27.0）上编译通过并修正：MelFrontend 初始化中闭包捕获 self、Whisper 权重多出的 `alignment_heads`（Python `Module.update` 非严格、只供词级时间戳用，移植版丢弃）、`gpt2`/`multilingual.tiktoken` 末行孤立的 `=`（Python 宽松 base64 解码为空字节，Swift 严格解码会跳过它导致全部特殊 token 编号错一位）、`verify_inprocess.sh` 中命令替换失败不触发 `set -e`（提交 `4b338d2`、`aefe7d2`）。对拍结果（`docs/*-verification-swift.json` 与 Python 版对照）：

| 模型 | 文本 | 单次耗时（Swift / Python） | 备注 |
| --- | --- | --- | --- |
| Qwen3-ASR-1.7B-bf16（auto） | 三个 fixture 逐字一致 | 865/930/744 ms vs 505/487/392 ms | 峰值 4.95 GB（Python 5.17 GB）；耗时偏高待复测（spike 时为 ≈1.0×） |
| whisper-large-v3-turbo（auto） | 三个 fixture 逐字一致 | 744/680/717 ms vs 469/424/451 ms | `--language Chinese` 时 504 ms；峰值 2.18 GB（Python 2.55 GB） |
| Qwen3-4B-Instruct-2507-4bit 翻译 | 译文合理，无 `<think>` | 首 token 176–182 ms，21–30 tok/s | |

以下为 Phase 3 各文件说明：

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
2. **下载器未编译**（Phase 4）：`ModelDownloader.swift` 与 BackendCore 下载流程已写好、测试已写好，待 Mac 上编译与跑 `scripts/test_download.sh`。
6. **Phase 3 推理耗时**：对拍中 Swift 单次转写比 Python 慢约 1.6–1.8×（spike 时为 1.0×），文本一致；需在空载机器上复测，若属实再用 Instruments 定位（候选：`MLXRuntime` 队列切换、Whisper/Qwen 首次调用的 kernel 编译、mel 前端）。
3. **Whisper 未验证**：代码与 Qwen 部分一样未经编译；`ASRValidation.whisperAssets` 为 nil（后端测试、默认构建）时仍跳过资产检查。`word_timestamps`、温度回退、束搜索等 adapter 不用的 mlx_whisper 功能未移植。
4. **Hunyuan-MT 分词器**：swift-transformers 的 `AutoTokenizer.from(modelFolder:)` 需要 `tokenizer.json`；若 `mlx-community/Hunyuan-MT-7B-4bit` 快照只有 tiktoken 词表，加载会失败（报错会走翻译失败路径，不影响识别），需实测。
5. **metallib 来源**：开发期与进程内打包都复用 `.venv` 中 mlx 0.32.2 wheel 的 `mlx.metallib`；Phase 5 删 Python 后需改为从 mlx 源码编译（完整 Xcode + `xcrun metal`）。

## 4. 待完成的工作（按序执行）

### Phase 3 — 验证与收尾（✅ 已完成，剩余项转后续）

对拍清单 1–4 已完成（结果见 §2 Phase 3 表格）。仍待办：app 内切换 Qwen/Whisper/翻译模型时的 GPU 内存观察（清单 5）、结果写入 `docs/VALIDATION.md`（清单 6）、`verify_pipeline`/`verify_endpoints` 场景的 Swift 复现（需把 `Sources/Recorder/Backend` 拆成库 target 或在 CLI 中复用 swiftc 文件列表，按需决定）。

### Phase 4 — 下载器（代码已提交，**未编译**）

| 文件 | 内容 |
| --- | --- |
| `Sources/Recorder/Backend/ModelDownloader.swift` | `ModelDownloading` 协议 + `HubDownloader`：不依赖 swift-transformers 的 `HubApi`（它的缓存布局与 huggingface_hub 不同），按 huggingface_hub 1.30 `_hf_hub_download_to_cache_dir` 直接写 HF 缓存。`GET /api/models/<repo>[/revision/<rev>]?blobs=true` → 按 download.py 扩展名过滤（**含 `.jinja`**）→ 钉 commit SHA 逐文件 `GET /<repo>/resolve/<sha>/<file>`（LFS 跟随 302 到 CDN）。blob 名 = LFS 的 sha256，否则 git blob id（与 huggingface_hub 取 `X-Linked-Etag`/`ETag` 的结果相同，也是其 `verify` 用的校验值）；`snapshots/<sha>/<file>` 为相对符号链接 `../../blobs/<etag>`（子目录多一级 `../`）；SHA 版本不写 `refs/`；写 `CACHEDIR.TAG`（同内容）。下载完成先校验大小与 sha256 / git-sha1，再原子 rename 成 blob。`HF_ENDPOINT` 环境变量照 Python 生效 |
| `BackendCore.swift` | server.py `download`/monitor/`cancel_download` 移植：`正在查询模型资源…`/`正在查询翻译模型资源…` → `progress` 事件（带 `role`，数值用 NSNumber，与 socket JSON 同样可读为 Double/Int）→ 成功后钉 revision、`status loading` 并排队 `load`/`load_translator`；失败发 `下载失败 (<异常名>): <原因>` 与「下载失败；可重试，已下载缓存可复用」；取消即 `Task.cancel()`，状态回 `ready`/`idle` +「下载已取消，可重试续传」，被取消或已被替换的下载其结果不再上报（对应 Python `self.downloader is not process`）；一次只允许一个下载（「请等待当前下载结束」）；`shutdown` 取消下载。另补齐 adapter.load 语义：`load` 带显式路径（本地目录、下载结果）时也跑 `ASRValidation.validate` |
| `tests/BackendTests.swift` | 新增 4 项：下载后加载 ASR（状态序列、progress 形状、revision 落盘）、失败文案与重试、取消（忽略迟到结果、忙时拒绝第二个下载）、翻译模型下载后加载 |
| `tests/DownloaderTests.swift` + `tests/mock_hub_server.py` + `scripts/test_download.sh` | 本地假 Hub（模拟 model_info、resolve、LFS 302 到异主机 CDN、Range、`X-Error-Code`）上的 8 项：布局（blob 命名、相对链接、过滤、无 refs、CACHEDIR.TAG、ModelCache 可离线解析）与 progress 形状、已缓存零传输/只补链接、取消保留分片并以 Range 续传（跨 302）、服务器忽略 Range 时重写、校验失败不落盘、错误名（ValueError/RepositoryNotFoundError/RevisionNotFoundError）、不安全文件名、**Python 对拍**（`.venv` 有 huggingface_hub 时先用 `backend/download.py` 从同一假 Hub 下载，两份缓存目录逐项比较：路径、链接目标、文件 sha256） |

与 Python 的有意差异（缓存结果不受影响）：
- **断点续传**：huggingface_hub 1.30 每个文件都下到唯一临时名、失败即删（Python 版取消后实际只保留已完成的文件）；Swift 版 LFS 分片保存为 `blobs/<etag>.incomplete`，重试时以 `Range` 续传（服务器不支持时自动从头写），「可重试续传」的文案因此名副其实。小的 git 文件不续传（可能 gzip 传输）。
- **完整性校验**：每个文件落盘前校验 sha256 / git-sha1，Python 只校验大小。
- 不创建 `<cache>/.locks/`（仅一个下载器，且 rename 是原子的）；Xet 存储的文件走 resolve 的普通 HTTP 回退（huggingface_hub 未装 hf_xet 时同样如此）；不读取 `~/.cache/huggingface/token`（默认模型均为公开仓库）。
- 进度事件形状沿用 download.py：每个文件开始时发一次累计进度（detail=文件名，total=全部文件大小），传输中发该文件自身进度（detail=tqdm 的 desc，超 40 字符取尾部加「(…)」，≥0.1 s 节流）。进度条因此在两种比例间跳变，与 Python 版一致，保持未改。

**Phase 4 验证清单**（Apple Silicon Mac）：
1. `swift build` 与 `RECORDER_INPROCESS=1 swift build -c release` 编译通过（重点核对：`FileTransfer` 的 URLSession 代理方法签名能被调用、`AsyncThrowingStream` 取消时 `onTermination` 触发、CryptoKit `Insecure.SHA1`）。
2. `./scripts/test_backend.sh`（54 项）与 `./scripts/test_download.sh`（8 项；有 `.venv` 时含 Python 对拍）全绿。
3. `./scripts/test_download.sh hub mlx-community/Qwen3-4B-Instruct-2507-4bit`：用真实 Hub 的 model_info 核对 `models/` 中 Python 下载的缓存——每个指针的链接目标与大小都应与 Swift 版会写入的一致（不下载权重）。可再加 `--full` 实际下载到临时目录并逐字节比较（约 2.3 GB）。
4. `RECORDER_INPROCESS=1 ./scripts/build.sh` 后在 app 中：删除（或改名）某个模型缓存后点「下载模型」→ 进度与文件名显示 → 自动加载就绪；下载中点「取消下载」→ 状态回退、再次下载从断点继续；翻译模型同样验证一次（设置 → 翻译 →「下载翻译模型」）。
5. 双轨互认：Swift 版下载的缓存用默认（Python sidecar）构建加载一次，反之亦然。结果写入 `docs/VALIDATION.md`。

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
- 常用命令：`swift build`（默认，Python sidecar）/ `RECORDER_INPROCESS=1 swift build`（进程内，含 MLX 依赖；不再需要 `-Xswiftc -D`）；`./scripts/test_backend.sh`；`./scripts/verify_vad.sh`；`./scripts/verify_inprocess.sh [asr|whisper|translate]`；`./scripts/test_download.sh [hub <model_id> [--full]]`。
- 依赖参照源码：mlx-whisper 0.4.3 wheel（`transcribe.py`、`decoding.py`、`whisper.py`、`tokenizer.py`、`audio.py`）；mlx-swift 0.32.2（`GPU.metallib`、`Memory.clearCache`、`quantize(model:filter:)`）、mlx-swift-lm main（`MLXLMCommon/Evaluate.swift` 的 `TokenIterator`、`ModelFactory.swift` 的 `load(from:using:)`、`MLXHuggingFaceMacros` 中分词器桥的写法）、mlx-audio 0.5.1 wheel（`mlx_audio/stt/models/qwen3_asr/qwen3_asr.py`）。
- 提交记录：`3fa60d2` Phase 0 spike；`bebad79` Phase 1–2；Phase 3 模型层见本分支后续提交。spike 的调试经验（对拍方法、常见数值坑）在 `docs/SPIKE-RESULTS.md`，Phase 3 移植时先读。
