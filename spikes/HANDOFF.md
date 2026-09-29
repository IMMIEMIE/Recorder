# 交接文档：mlx-swift 单进程重构（Phase 0–2 已完成 ✅，下一步 Phase 3）

> 分支：`refactor/mlx-swift-20260929`
> 日期：2026-09-29（Phase 0–2 同日完成）
> **状态更新：Phase 0 spike 通过（[docs/SPIKE-RESULTS.md](../docs/SPIKE-RESULTS.md)）；Phase 1–2 进程内后端骨架与信号链已落地（`Sources/Recorder/Backend/`，49 项 Swift 测试全绿、VAD 对拍逐帧一致，提交 `3fa60d2`、`bebad79`）。当前下一步为 Phase 3（模型层接入）。**
> 总体规格：[docs/REFACTOR-MLX-SWIFT.md](../docs/REFACTOR-MLX-SWIFT.md)（必读；其 §4 Phase 1–2 后已附「实施备注」记录实现与规格的偏差）
> 本文档面向：接手后续实施的开发者（人或 AI 助手）

---

## 1. 项目一句话

声笺要把 Python 双进程后端（`backend/*.py` + 捆绑 1.2 GB Python ML 栈，安装包 547 MB）重写为 mlx-swift 单进程 Swift 实现，目标 ~100-150 MB。重构分 6 阶段（规格文档 §4），**Phase 0–2 已完成，当前处于 Phase 3（模型层接入）开工前**。

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

### 测试基建

- `scripts/test_backend.sh` + `tests/BackendTests.swift`：移植 `tests/test_core.py`、`test_endpoint.py`、`test_translation.py` 的断言（swiftc 显式文件列表 + `@main` 模式，与现有 `test_ai.sh` 一致），**49 项全绿**。覆盖：配置校验/原子写、分帧/预卷/智能定稿、识别缓存复用、规划器、翻译让位与抢占、API/流式路径、过载、hello 竞态。
- `scripts/verify_vad.sh`：VAD 对拍（可复跑）。
- 双轨开关：`build.sh` 在 `RECORDER_INPROCESS=1` 时追加 `-Xswiftc -DRECORDER_INPROCESS`；**默认关闭，仍走 Python sidecar**，两种编译均已验证通过。

## 3. 已知偏差与阶段缺口（均有明确中文报错，不影响双轨默认路径）

1. **模型下载未接入**（Phase 4）：in-process 模式下 `download` 命令与翻译模型下载返回「下载功能尚未接入，请等待后续版本更新」；`cancel_download` 为 no-op。
2. **本地引擎占位**（Phase 3）：`PlaceholderASREngine`/`PlaceholderTranslatorEngine` 在 load 时抛「本地识别模型引擎尚未接入…」。AppModel 进程内分支目前使用占位引擎。
3. **whisper 校验分支不完整**（Phase 3）：`ASRValidation.validate` 的 whisper 分支跳过 mlx_whisper 运行环境与资产检查（资产改为随 app 打包是 Phase 3 工作）。
4. 翻译 `enable_thinking=False`（qwen3）与 Qwen3-4B 流式验证并入 Phase 3。

## 4. 待完成的工作（按序执行）

### Phase 3 — 模型层接入（2–3 周，**下一步**）

1. **`Qwen3ASRModel.swift` 固化**：把 spike 代码迁入 `Sources/Recorder/Backend/`，实现 `ASREngine` 协议（`load/warmup/unload/transcribe`，替换 Placeholder）。要点：`validate_config` 的 qwen3_asr 分支已就位；warmup 用 0.5 s 静音（对齐 Python `b'\0'*16000`）；unload 释放引用 + `MLX.GPU.clearCache()`；metallib 加载方案按 SPIKE-RESULTS 教训处理（Phase 5 需改为从源码编译，需接受许可的完整 Xcode）。
2. **`Translator.swift`**：MLXLMCommon 加载 `Qwen3-4B-Instruct-2507-4bit`，实现 `TranslatorEngine` 协议（`stream` 返回 AsyncThrowingStream，BackendCore 的让位循环已就绪，无需改动）。验证 `enable_thinking=False`、Hunyuan-MT 架构支持缺口、warmup（'Good morning.'）。**这是 Phase 0 遗留的第 6 项验证**。
3. **`WhisperModel.swift`**（备选模型，可后置）：mlx_whisper 对应移植（temperature=0.0、condition_on_previous_text=false、sample_len=224）+ mel filters/tiktoken 资产随 app 打包；补全 `ASRValidation` whisper 分支。
4. **收尾**：引擎注入 AppModel 进程内分支（替换 Placeholder）；`scripts/verify_pipeline.py`/`verify_translation.py` 场景改由 Swift 复现或对拍，结果记入 `docs/VALIDATION.md`；GPU 内存复核（spike 单模型 4.7 GB，双模型驻留策略要验证「切模型先卸载」时序）。
5. 验收：`tests/fixtures` 全量对拍一致；单次转写延迟、翻译吞吐不劣于 Python 版 ±30%。

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
- 常用命令：`swift build`（默认）/ `swift build -Xswiftc -DRECORDER_INPROCESS`；`./scripts/test_backend.sh`；`./scripts/verify_vad.sh`。
- 提交记录：`3fa60d2` Phase 0 spike；`bebad79` Phase 1–2。spike 的调试经验（对拍方法、常见数值坑）在 `docs/SPIKE-RESULTS.md`，Phase 3 移植时先读。
