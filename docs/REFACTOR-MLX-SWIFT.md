# 重构实现文档：移除 Python 后端，迁移至 mlx-swift 单进程架构

> 分支：`refactor/mlx-swift-20260929`
> 状态：Phase 0（spike）、Phase 1（进程内通道与后端骨架）、Phase 2（信号链移植）已完成；Phase 3（模型层）代码已提交、待 macOS 编译与对拍；Phase 4 起待实施。实现与规格的偏差记录在 §4 各阶段之后的「实施备注」。
> 前置结论：安装包 547 MB 中约 96% 是捆绑的 Python ML 推理栈（1.2 GB 磁盘），其中 torch 526 MB 仅为 mlx-whisper 的传递依赖。Swift 应用本体仅 2.5 MB。

---

## 1. 背景与动机

### 1.1 体积构成（实测）

| 组成 | 磁盘大小 | 说明 |
| --- | --- | --- |
| Swift 应用本体 | 2.5 MB | SwiftUI 界面 + Unix socket 协议层 |
| Python 后端代码 | 80 KB | `backend/*.py`，共约 1 300 行 |
| torch | 526 MB | 仅 `mlx_whisper/torch_whisper.py`（torch 写的模型定义，加载后转 MLX） |
| mlx + mlx-metal | 202 MB | 真正的推理引擎 |
| llvmlite + numba | 137 MB | mlx-whisper 传递依赖 |
| scipy / sklearn / librosa 链 | ~110 MB | 传递依赖 |
| transformers + tokenizers | 61 MB | mlx-lm tokenizer 依赖 |
| sympy、numpy 等 | ~60 MB | |
| Python 解释器 + 标准库 | ~50 MB | |

后端自身**从不直接 import torch/librosa**（已 grep 验证）；全部是 `mlx-whisper`、`mlx-audio`、`transformers` 的传递依赖。

### 1.2 重构目标

- 单进程 Swift 应用：`mlx-swift`（MLX 官方 Swift 绑定）在进程内完成本地识别与翻译推理。
- 删除捆绑 Python 运行时，安装包预期从 547 MB 降至约 100–150 MB（mlx-swift 以 SwiftPM 静态链接 Metal 内核）。
- 删除 Unix socket 与双进程生命周期管理。
- **行为不变**：UI、事件流、配置持久化、模型缓存布局对用户保持兼容（已下载的模型权重必须继续可用）。

### 1.3 非目标

- 不改 UI 交互与文案。
- 不改 API 识别 / LiveTranslate / AI 提问（它们本来就与 Python 后端无关或仅弱耦合）。
- 不升级协议语义（`protocol_version` 仍为 1；进程内事件沿用现有字段）。

---

## 2. 现状架构摘要（移植面清单）

以下为两份代码探索报告的结论汇编，是移植规格的权威依据。行号以当前 `main`（916b42f）为准。

### 2.1 进程与协议

- `AppModel.launch()`（AppModel.swift:240-319）spawn `runtime/bin/python3 backend/server.py --socket /tmp/recorder-<uuid>.sock --root ~/Library/Application Support/LocalRecorder`，env 含 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1` 等。连接重试 100 × 0.1 s。
- 帧格式（core.py:143-162 ↔ Transport.swift:48-56）：4 字节大端长度（= 1 字节 kind + payload，上限 256 KB）+ kind。kind `J`(74) JSON 控制/事件，`A`(65) 音频。音频 payload = 4 字节大端头长（≤4096）+ JSON 头（`session_id, sequence, start_sample, sample_rate:16000, channels:1, format:"s16le"`）+ 原始 PCM16。
- 服务端事件信封（server.py:71-78）：`{protocol_version:1, session_id, request_id, **event}`，`ensure_ascii=False`，send_lock 串行。
- Transport 客户端 320 KB 音频背压上限（Transport.swift:50）；超限丢帧 → 序号不连续 → 服务端 flush 并报错，AppModel 停止采集。

### 2.2 命令面（Swift → 后端，全部经 `command()`，AppModel.swift:344-349）

| 命令 | 字段 | 服务端行为要点（server.py 行号） |
| --- | --- | --- |
| `hello` | — | 回 `config` + `translator` 状态 + `status`（389-397） |
| `load`（ASR） | `config`，可选 `api_key` | 校验状态机后入队 `load`/`load_api` job（410-431） |
| `download`（ASR） | `config` | 拒绝 provider=api / local_model_path / 并发下载（410-431） |
| `load`/`download`（翻译） | `role:"translator"`, `translation` | busy 拒绝、provider≠local 拒绝（398-409） |
| `cancel_download` | — | terminate 子进程，状态回 ready/idle（468-475） |
| `translation_settings` | `enabled`/`target_language`/`provider`/`api_profile`（可部分） | **总是先写 translation.json**；busy 且 enabled/provider 变化则拒绝；禁用或切 API → `drop_pending_translations` + 卸载模型（432-455） |
| `start` | `session_id`（必需），可选 `endpoint_mode`/`endpoint_silence_ms`（变化则重解析并保存） | 仅 `ready` 态；建 VAD(2)；重置 final_segments/pending/seq/samples；流式会话不建 Segmenter（476-493） |
| `asr_stream_final` | `session_id, segment_id, text, start_sample` | 仅流式会话且 recording/finalizing 态；校验 segment_id≥1、去重、text UTF-8 ≤200 000、start_sample≥0；入队 `stream_final`（456-467） |
| `stop` | `session_id` | 匹配当前会话才 `flush()`（494-496） |

错误路径：`control()`/`audio()` 内的异常 → `error` 事件，循环继续；帧级错误（EOF/坏帧）→ 退出。

### 2.3 事件面（后端 → Swift，`AppModel.handle`，AppModel.swift:660-748）

| 事件 | 字段 | UI 依赖的语义 |
| --- | --- | --- |
| `config` | `config: asdict(Config)` | 后端是配置持久化的唯一真相源，UI 整体镜像回显 |
| `status` | `state, detail` | 状态机 `idle/loading/warming/ready/recording/finalizing/downloading/error`（`connecting` 仅客户端）；`recording` 触发 `beginCapture()`；离开 `recording` 触发无条件拆除输入（覆盖自动停止，L687-691） |
| `partial`/`final` | `text, elapsed_ms, session_id, segment_id, revision, start_sample, end_sample?, forced_cut` | `(session, segment)` 去重 + revision 单调；`final` 建 Transcript 行（seconds = start_sample/16000）；`final` 后触发翻译 |
| `translation` | `session_id, segment_id, unit_id, revision, text, done, skipped?, elapsed_ms?` | revision 单调；`done && text 空` = 跳过（同语种/过载/取消）；会话结束后仍可送达并落在原行 |
| `translator` | `state, detail, active_model, config` | 独立子状态机 `idle/downloading/loading/warming/ready/error` |
| `progress` | `detail, completed, total, role` | `role` 区分 ASR/翻译模型下载进度 |
| `error` | `message` | UI 橙色横幅 |

### 2.4 后端线程模型（server.py）——移植的核心不变量

- **三个线程**：reader（主线程，跑 control/audio/flush/download/cancel）、worker（所有模型加载/推理/翻译步进/配置保存）、per-download monitor。
- **单个 RLock**（`threading.Condition(RLock())`）同时作为任务队列锁与 Segmenter 锁——音频边界、任务队列、识别反馈三方一致的基石。
- **worker 优先级**：`jobs` FIFO（final/finish/load/load_api/load_translator/unload_translator）> 翻译 > preview（单槽，只保留最新）。
- **翻译可挂起**：翻译是 `mlx_lm.stream_generate` 生成器，**每个 token 之后**检查 `jobs` 非空即挂起（KV-cache 保留在生成器里），worker 处理完积压 job 再恢复。只有 worker 线程可关闭生成器（`cancel_translations`）；其他线程只能打标 `drop_pending_translations`。
- **过载自动停止**：audio() 喂帧后 `len(jobs) >= 6`（不含 preview）→ `error` 事件「推理落后…」+ `flush()`。
- 翻译失败**绝不**影响 ASR 状态或其队列；ASR worker 异常路径会清缓存、快照清空 jobs、报错但保留已确认文字。
- `final_segments` 防止 segment 双重定稿（迟到的 preview 作废；`asr_stream_final` 拒绝已定稿 id）。

### 2.5 Config（core.py:45-140）

- `Config`：`schema_version=1, model_id('mlx-community/Qwen3-ASR-1.7B-bf16'), local_model_path, revision, language('auto'), preview_interval_ms(1200, 800-10000), endpoint_mode('smart'), endpoint_silence_ms(1000, 300-2000), max_segment_seconds(18, 5-25), provider('local'), api_base_url, api_model, api_protocol('openai')`。未知键拒绝；API URL 校验（https/wss、无 userinfo/query/fragment、无尾斜杠；openai 允许 localhost 明文 http）。
- `TranslationConfig`（独立 `translation.json`）：`schema_version, enabled(False), provider('local'), api_profile, target_language('简体中文'), model_id('mlx-community/Qwen3-4B-Instruct-2507-4bit'), revision`。`TRANSLATION_TARGETS` 9 项目标语言，必须与 `AppModel.translationTargets`（AppModel.swift:72）保持一致。
- 保存：原子写（`.tmp` + chmod 0600 + rename）；**仅在加载/预热成功后**保存（失败切换保留旧配置）。例外：`translation_settings` 总是立即保存。
- 保存时机：本地 load 成功、load_api 成功、start 时 endpoint 字段有变、translation_settings、load_translator 成功（enabled=True 烧入）、翻译模型加载失败且无驻留模型（enabled=False）。

### 2.6 Segmenter（core.py:165-268）

- 20 ms 帧（320 样本 = 640 字节 PCM16）+ WebRTC VAD（aggressiveness 2）。
- 预卷（preroll）240 ms（12 帧），仅静默后使用；开段时作为段头。
- 定稿条件：`silent*20 >= threshold()`；段内 voiced ≥ 2 帧才出 final。
- **智能定稿阈值**（227-237）：无预览结果或预览过期/非句末 → 1800 ms；单条当前+句末完整 → 1000 ms；连续两条相同预览（识别已稳定）→ 500 ms。fixed 模式用 `endpoint_silence_ms`。
- 预览快照条件：voiced ≥ 3 帧且有新语音且距上次 ≥ `preview_interval_ms`。
- `accept_preview`：仅同段同起点且 revision 更新才接受；保留最近 2 条；**接受后重查阈值**（预览补全句末可立即触发快速定稿）。
- `max_segment_seconds` 只限制推理切片（RecognitionCache 按 18 s × 16000 × 2 = 576 000 字节切块、逐块转写、`join_text` 拼接——ASCII/ASCII 边界加空格），**从不强制定稿**。当前 Segmenter 永远 `forced_cut: false`。
- `sentence_complete`（165-180）：保守句末判断（剥引号/括号；`。！？!?` 结尾为真；`.` 结尾排除编号/缩写/姓氏首字母等）。

### 2.7 模型层（移植最大风险区）

| 调用点 | Python 现状 | mlx-swift 对应 | 风险 |
| --- | --- | --- | --- |
| Qwen3-ASR 加载 | `mlx_audio.stt.utils.load_model(path)`（adapter.py:80） | **无现成实现**，需自行移植模型结构（audio tower + LLM decoder）到 Swift | **高** |
| Qwen3-ASR 推理 | `model.generate(audio=mx.array(float32), max_tokens=512, language?)` → `.text`（adapter.py:111-113） | 自实现 generate 循环 + 从 `preprocessor_config.json` 还原音频前端 | **高** |
| Whisper 加载/推理 | `mlx_whisper.transcribe.transcribe(..., temperature=0.0, condition_on_previous_text=False, sample_len=224)`，fp16 | mlx-swift 无官方 whisper；需移植或用社区实现 + mel filters/tiktoken 资产 | 中 |
| 翻译加载 | `mlx_lm.load(path)` | `MLXLMCommon`（mlx-swift-examples）支持 qwen2/qwen3/llama/mistral | 低 |
| 翻译 prompt | `tokenizer.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False(qwen3))` | MLXLMCommon chat 模板渲染（jinja） | 低 |
| 翻译生成 | `mlx_lm.stream_generate(model, tokenizer, prompt, max_tokens=min(1024, 64+3*len(text)))`，逐 token 产出累计文本 | 自持 generate 循环（Swift 可控逐 token 挂起） | 中（挂起语义） |
| VAD | `webrtcvad.Vad(2)`（C 库） | 移植 webrtcvad C 源（约 1 500 行，含 GMM 模型数据）或找 Swift 移植 | 中 |
| 内存 | `mx.clear_cache()` + 清 mlx-whisper 全局 ModelHolder | `MLX.GPU.clearCache()` + 释放引用 | 低 |

**Qwen3-ASR 输入**：float32 [-1,1)、16 kHz 单声道、无前端预处理（在 `mlx_audio` 的 generate / preprocessor_config 内部处理）。**语言参数**：`auto|Chinese|English|Cantonese|Japanese|Korean` 原样传入。

### 2.8 翻译规划（translation.py）

- `TranslationPlanner`：静默结束的 final = 一个翻译单元；forced-cut 遗留逻辑保留（末句携至下一 final、剥 CUT_PUNCTUATION、`MAX_CARRY=400`）；新会话自动重置；空 final 不移动锚点。
- `already_in_target` 文字系统计数启发（避免无谓 GPU 调用）：简中 `kana==0 && hangul==0 && han≥0.7*total`；日语 `kana>0 && han+kana≥0.7*total`；韩语 `hangul≥0.7*total`；俄语 `2*cyrillic≥0.7*total`；拉丁/繁中目标恒 false（靠 `same_text` 兜底）。
- `same_text`：`re.sub(r'[\W_]+','',s).casefold()` 归一后相等 = 译文与原文相同 → 跳过。
- `build_messages`：Hunyuan 单轮（中/英指令二选一）；其余架构 system prompt（防注入）+ 最近 2 组 `(source, translation)` 上下文（同目标语言同会话过滤）+ 当前文本。
- `validate_translator`：架构白名单 `('qwen2','qwen3','hunyuan_v1_dense','llama','mistral')`、无 `auto_map`、必须 chat template（`chat_template.jinja` 或 tokenizer_config 键）、safetensors 完整性。
- 服务端翻译调度：`MAX_PENDING_TRANSLATIONS=4`，超限丢最旧并发过载 error（按会话去重）；流式 translation 事件 ≥0.2 s 节流；占位事件（revision 0 空文本）在入队时即发。

### 2.9 下载与模型缓存

- `download.py` 子进程：`HfApi.model_info(files_metadata=True)` → 过滤扩展名 `.json/.safetensors/.txt/.model/.tiktoken/.npz/.jinja`（**`.jinja` 必须保留**，否则翻译模型丢 chat template）→ 逐文件 `hf_hub_download(revision=commit_sha)`（钉死同一快照）→ stdout JSON-lines 进度 → `{'type':'downloaded', path, revision}`。异常 → `{'type':'error'}` + exit 1。
- 父进程剥离 `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE` 再 spawn；下载完成入队 load job（带快照路径 + revision）。
- `model_cache.resolve_cached_model`：先 `snapshot_download(local_files_only=True)` + validate；显式 revision 失败则**硬错误**（绝不静默换版本）；否则按 mtime 新→旧扫描 `models--<owner>--<model>/snapshots/*` 逐个 validate。**Swift 端必须保持此缓存目录布局**，否则用户已下载的约 4–6 GB 权重作废。

### 2.10 Swift 侧移植边界（探索结论）

**唯一后端接缝是 `Transport.onEvent`/`onFailure`**。以下为强耦合面（需重接）：

- `Transport.swift` 整文件（socket 帧协议、320 KB 背压）。
- `AppModel.launch()/shutdown()/command()`（进程 spawn/env/socket/连接重试/终止处理）。
- `AppModel.handle(_:)`（事件解码——**保持事件字典形状不变即可整体复用**）。
- `AppModel.start()/stop()/beginCapture()/audio()`（命令时序、seq/samples 记账、背压停止——`asr_stream_final` 路径、流式 ASR `start` 握手）。
- `AppModel.load()/loadTranslator()/cancelDownload()/setTranslation*` 及配置字典构造。
- 下载进度 UI 状态流。

**与后端无关、完全不动**：`AIClient/AIProfiles/AIWorkspace/APITranslationQueue`（纯 HTTP/Keychain）；`LiveTranslate*`（纯 WSS 云服务，此模式下后端本来就不启动）；`StreamingASR.swift` 客户端本身；`AudioCapture/AdditionalAudioInput/InputPCMConverter`（纯采集重采样，onPCM 接口不变）；`SubtitleWindow/TextExport`、菜单栏、快捷键、权限处理、导出复制。

### 2.11 前端保留的负数单元 ID

- `-1` = API 翻译（APITranslationQueue）；`-2` = LiveTranslate 译文。后端本地翻译用正数 ≥1。移植后进程内翻译器继续分配正数 id，不得冲突。

---

## 3. 目标架构

```
┌────────────────────────── 声笺.app（单进程） ──────────────────────────┐
│                                                                        │
│  SwiftUI 层（不变）        AppModel（handle() 不变，launch 重写）        │
│                                                                        │
│  ── InProcessChannel（替代 Transport：同形事件字典、主线程回调）──       │
│                                                                        │
│  BackendCore（actor，替代 server.py 的 RLock 域）                       │
│   ├─ 命令处理（control() 的 Swift 版：同校验、同错误消息）              │
│   ├─ 任务调度（jobs 优先级 > 翻译 > preview；翻译逐 token 让位）        │
│   ├─ Segmenter（+ VAD） / RecognitionCache / TranslationPlanner         │
│   ├─ ConfigStore（原子写、0600、仅成功后保存、双文件）                  │
│   └─ Downloader（HubApi，保持 HF 缓存布局与 .jinja 过滤）               │
│                                                                        │
│  模型层（MLXSwift）                                                     │
│   ├─ Qwen3ASRModel（自移植：加载 safetensors + generate）               │
│   ├─ WhisperModel（移植或社区实现 + mel/tiktoken 资产）                 │
│   └─ Translator（MLXLMCommon + 自持逐 token 生成循环）                  │
└────────────────────────────────────────────────────────────────────────┘
```

关键设计决策：

1. **保留事件协议形状**。新建 `InProcessChannel`，暴露与 `Transport` 相同的 `send`/`audio`/`onEvent`/`onFailure` 接口，事件以同样的 `[String:Any]` 字典、同样顺序（`hello` → `config`+`translator`+`status`）投递到主线程。这样 `AppModel.handle()`、所有 UI、下载进度流**零改动**。协议从「跨进程帧」退化为「进程内函数调用」，但语义逐一保留（含 320 KB 背压——改为 channel 内计数，超限同样触发 seq 断裂错误路径，AppModel 的停止逻辑不变）。
2. **BackendCore 用 Swift actor 承载原 RLock 域**。actor 天然串行化，对应「一把 RLock 管队列+分段器+反馈」；音频喂入从「reader 线程同步处理」变为「actor 方法调用」（async）。需注意：现有 `audio()` 回调在音频线程，改为 `Task { await core.audio(...) }` 投递，**顺序必须保持**（actor 邮箱天然 FIFO，满足）。
3. **翻译逐 token 让位**：不再用可挂起生成器，而是在自持的 Swift generate 循环里每产出一个 token 检查 `jobs` 非空即 `await` 让出。KV-cache 生命周期由闭包持有的模型状态保证——Swift 版比 Python 版更直接（无生成器 close 语义，改用 Task 取消 + 显式释放）。
4. **模型缓存目录不动**：继续读写 `~/Library/Application Support/LocalRecorder/models/models--<owner>--<model>/snapshots/<sha>`，`resolve_cached_model` 的算法（显式 revision 硬错误、mtime 扫描兜底）逐行移植。
5. **配置文件不动**：`config.json` / `translation.json` 字段、校验、原子写、保存时机逐行移植，旧安装升级后配置无损。

---

## 4. 分阶段实施计划

### Phase 0 — 技术验证 spike（先行，1–2 周，最高风险前置）

目的：在动架构之前回答「mlx-swift 能不能跑 Qwen3-ASR」。

1. 新建 `spikes/QwenASRSpike/` SwiftPM 包，依赖 `ml-explore/mlx-swift`。
2. 用 mlx-swift 的 safetensors 加载器读 `mlx-community/Qwen3-ASR-1.7B-bf16` 权重（用已缓存快照）。
3. 逐层移植模型结构（对照 `mlx_audio` Python 源码与 `config.json`/`preprocessor_config.json`）：audio encoder（卷积前端 + transformer）、projector、LLM decoder。
4. 实现最小 generate：贪心解码、`max_tokens=512`、language 提示注入方式对照 `mlx_audio` 的 `generate`。
5. **验收**：与 Python 后端在同一批 `tests/fixtures/*.aiff` 上的转写文本一致（或差异可解释）；单次推理延迟不劣于 Python 版 1.5 倍。
6. 同期验证：MLXLMCommon 跑 `Qwen3-4B-Instruct-2507-4bit` 流式生成 + `enable_thinking=False`；逐 token 让位的可行性 demo（AsyncStream + actor）。
7. 产出 `docs/SPIKE-RESULTS.md` 记录结论。**若 Qwen3-ASR 移植失败，此重构不立项**（备选：保留 Python 或转 whisper.cpp——见 §7）。

### Phase 1 — 进程内通道与后端骨架（1 周）

新建文件（均在 `Sources/Recorder/Backend/`）：

| 新文件 | 移植自 | 内容 |
| --- | --- | --- |
| `InProcessChannel.swift` | Transport.swift 接口语义 | 同形事件投递（主线程）、`send`/`audio`/背压计数、`onFailure` |
| `BackendCore.swift` | server.py 23-113, 389-557 | actor：命令分发、状态机、jobs deque、preview 槽、过载自动停止（≥6）、`final_segments`、异常路径（清缓存/保文字） |
| `ConfigStore.swift` | core.py 31-140 | Config/TranslationConfig 校验、原子写 0600、保存时机 |
| `BackendTypes.swift` | core.py 常量 | `RATE=16000`、`FRAME=320`、`MAX_MESSAGE`、`TRANSLATION_TARGETS` |

改动：

- `AppModel.launch()`：不再 spawn 进程，构造 `BackendCore` + `InProcessChannel`，发 `hello`；`shutdown()` 改为向 core 发关闭并释放模型。**generation UUID 守卫机制保留**（防旧回调）。
- `AppModel.command()` 路由到 channel；`handle()` 不动。
- `build.sh`：暂保留 Python runtime 打包（双轨可切），加编译开关 `RECORDER_INPROCESS`（默认关）。

验收：`tests/` 中 `test_core` 的命令/状态/错误路径断言改为（或平行新建）Swift 测试；`scripts/test_*.sh` 的 mock 流程概念移植。进程内 `hello` 回复与原后端逐字段一致。

### Phase 2 — 信号链移植（1 周）

| 新文件 | 移植自 | 要点 |
| --- | --- | --- |
| `Segmenter.swift` | core.py 165-268 | 预卷、智能/固定阈值（1800/1000/500）、`accept_preview` 重查阈值、`sentence_complete`（正则逐一对照）、`flush` |
| `WebRTCVAD.swift` | webrtcvad C 源 | 移植或引入 Swift 移植；aggressiveness 2；20 ms/16 kHz 接口 |
| `RecognitionCache.swift` | recognition.py | 全结果缓存（last_voiced 命中）、18 s 切块、整块缓存、`forget`/`clear` 时机 |
| `TranslationPlanner.swift` | translation.py 16-109 | 单元规划、forced-cut 遗留、`already_in_target`、`same_text`、`join_text`、`build_messages`、`max_tokens` |

验收：用录制的 PCM 回放（`tests/fixtures/`）比对 Python 与 Swift 的 final 切分点、revision、文本逐项一致。`docs/SMART-ENDPOINTS.md` 的智能定稿行为作为基准用例。

Phase 1–2 实施备注（2026-09-29）：

- 新文件落在 `Sources/Recorder/Backend/`：BackendTypes、ConfigStore、Segmenter、WebRTCVAD、RecognitionCache、TranslationPlanner、BackendCore（actor）、InProcessChannel、ASRAPIClient、ModelCache。WebRTC VAD 以 C 源码直接编入 SwiftPM C target `Cwebrtcvad`（与 Python webrtcvad wheel 同源），`scripts/verify_vad.sh` 逐帧对拍一致。
- 计划中属于 Phase 3 的 `ASRAPIClient`（asr_api.py）与 Phase 4 的 `ModelCache.resolve_cached_model` 算法提前移植——`load`/`load_api` 命令路径依赖它们，先补齐使 BackendCore 语义完整。
- 阶段性缺口（待后续阶段补上，均有明确报错文案）：模型下载（Phase 4）在 in-process 模式返回「下载功能尚未接入」；本地 ASR/翻译引擎（Phase 3）由 `PlaceholderASREngine`/`PlaceholderTranslatorEngine` 占位。
- `ASRValidation.validate` 的 whisper 分支暂跳过 mlx_whisper 运行环境与资产检查（资产改为随 app 打包是 Phase 3 工作）。
- 事件投递：BackendCore.actor 单一隔离域对应 Python 的 Condition(RLock)；重活（识别/翻译/加载）为 off-actor await，控制命令不被推理阻塞；翻译逐 token 让位用自持 `AsyncThrowingStream` 迭代实现。attach 与首条命令存在 Task 竞态，core 先缓冲事件、attach 后按序补发。
- 测试：`scripts/test_backend.sh`（swiftc 显式文件列表）+ `tests/BackendTests.swift`，移植 test_core/test_endpoint/test_translation 的断言，49 项全绿。
- 双轨开关：`build.sh` 在 `RECORDER_INPROCESS=1` 时加 `-Xswiftc -DRECORDER_INPROCESS`；默认关闭，仍走 Python sidecar。（Phase 3 起改为 `Package.swift` 读取该环境变量，见下方 Phase 3 实施备注。）

### Phase 3 — 模型层接入（2–3 周，依赖 Phase 0 结论）

| 新文件 | 移植自 | 要点 |
| --- | --- | --- |
| `Qwen3ASRModel.swift` | Phase 0 spike 固化 | 加载校验（`validate_config` 的 qwen3_asr 分支：必需文件清单、auto_map 拒绝、index weight_map 完整性）、`transcribe(pcm)`、warmup（0.5 s 静音）、卸载 + `MLX.GPU.clearCache()` |
| `WhisperModel.swift` | adapter.py whisper 分支 + mlx_whisper | 同上校验分支；fp16；`temperature=0.0, condition_on_previous_text=false, sample_len=224`；mel filters/tiktoken 资产随 app 打包（当前从 Python 包 assets 取） |
| `Translator.swift` | translation.py 142-182 + server.py 220-343 | MLXLMCommon 加载、validate_translator、warmup（'Good morning.'）、**自持逐 token 生成循环 + 让位检查**、`cancel`/`drop` 两个取消层（对应「仅 worker 可关生成器」的约束） |
| `ASRAPIClient.swift` | asr_api.py | 原样移植（stdlib→URLSession）：multipart WAV、90 s 超时、拒重定向、2 MB 响应上限、错误文案 |

验收：`scripts/verify_pipeline.py` / `verify_translation.py` / `verify_endpoints.py` 的场景改由 Swift 可执行目标复现（或写 `scripts/verify_inprocess.py` 直连 Swift 测试壳），结果写入 `docs/VALIDATION.md`。

**Phase 3 实施备注**（代码已提交，尚未在 macOS 上编译与对拍；验证清单见 `spikes/HANDOFF.md` §4）：

- 模型层放在独立库 target `RecorderMLX`（`Qwen3ASR`、`MLXTextGenerator`、`MLXRuntime`），供 app 与对拍 CLI `RecorderVerify` 共用；`ASREngine`/`TranslatorEngine` 适配器在 `Sources/Recorder/Engines/`。`scripts/verify_inprocess.sh` 取代计划中的 `verify_inprocess.py`，覆盖 verify_model.py 与 verify_translation.py 的场景；实时节奏全链路（verify_pipeline/verify_endpoints）尚未复现。
- 双轨开关改为 manifest 级：`Package.swift` 读取 `RECORDER_INPROCESS=1` 才加入 mlx-swift（exact 0.32.2）、mlx-swift-lm（main 按 revision 钉住）、swift-transformers（`Tokenizers`，自写分词器桥，不用 MLXHuggingFace 宏），默认构建不拉 MLX。
- Metal kernel：`build.sh` 进程内分支把 `.venv` 中 mlx 0.32.2 的 `mlx.metallib` 放进 `Contents/Resources/`，启动时经 `GPU.metallib` 指定（Phase 5 改为源码编译）。
- 全部模型计算串行在一条专用队列上（对应 Python 单 worker 线程）；翻译用 `TokenIterator` 拉一次解一个 token，BackendCore 停止拉取即让出 GPU，取代计划中的「cancel/drop 两层取消」——丢弃迭代器即释放 KV cache。
- 与 spike 的有意差异：mel 前端不再补零到 30 s（mlx_audio 以 `padding=True` 调用特征提取器）；不足 1 s 的输入补零到 1 s（`min_chunk_duration`）；Qwen3-ASR 支持 `quantization` 配置。
- Whisper 未移植：进程内加载 whisper 架构时报「Whisper 本地识别引擎尚未接入…」。

### Phase 4 — 下载器（1 周）

| 新文件 | 移植自 | 要点 |
| --- | --- | --- |
| `ModelDownloader.swift` | download.py + server.py 345-387 + model_cache.py | `HubApi`（swift-transformers）或自写：model_info(files_metadata) → 扩展名过滤（**含 `.jinja`**）→ 钉 SHA 逐文件下载 → 进度回调（映射 `progress` 事件 + role）→ 取消（保留已缓存 blob 续传）；`resolve_cached_model` 算法（local_files_only、显式 revision 硬错误、mtime 扫描） |

验收：下载 `Qwen3-4B-Instruct-2507-4bit` 后，缓存目录布局与 Python 版逐字节同构；取消/重试/断点续传可用；同一份缓存能被 Python 版和 Swift 版互相识别（过渡期双轨）。

### Phase 5 — 拆除与瘦身（3–5 天）

- 删除 `Transport.swift` 的 socket 实现（接口并入 InProcessChannel）、`AppModel.launch()` 进程逻辑、`backend/` 目录、`requirements.lock`、runtime 打包。
- `build.sh`/`package.sh`：去掉 Python runtime 组装与 `initial-config.json` 钉 revision 逻辑（配置校验改由 Swift 端做）；版本号 bump。
- SwiftPM 依赖：`mlx-swift`、`swift-transformers`（tokenizer/HUB）、（Whisper 资产）。
- `README.md`、`CLAUDE.md` 更新架构描述。
- 预期产物：DMG ~100-150 MB。

验收：全新目录安装 → 下载默认模型 → 麦克风转写 + 本地翻译 + 字幕 + 导出全流程回归；旧安装（已有 models 缓存与 config.json）升级后模型与配置直接可用。

---

## 5. 组件映射总表

| Python | Swift（新） | 备注 |
| --- | --- | --- |
| `server.py` Server.run/reader | `BackendCore.actor` 命令入口 | control/audio 同步语义 → actor 方法 |
| `server.py` worker 循环 | `BackendCore` 内串行执行任务 | 优先级不变 |
| `threading.Condition(RLock())` | actor 隔离域 | 队列+分段器+反馈同域 |
| `mlx_lm.stream_generate` 挂起 | 自持 generate 循环 + `await` 让位 | 每 token 检查 jobs |
| `core.py` read/encode_message | 删除（进程内直调） | 帧格式仅存于注释/历史 |
| `core.py` Segmenter | `Segmenter.swift` | 含 sentence_complete 正则 |
| `core.py` Config/TranslationConfig | `ConfigStore.swift` | 双文件、原子写、保存时机 |
| `recognition.py` | `RecognitionCache.swift` | worker 域内私有 |
| `adapter.py` | `Qwen3ASRModel` + `WhisperModel` + 统一 `ASRModel` 协议 | validate_config 两分支拆开 |
| `translation.py` | `TranslationPlanner.swift` + `Translator.swift` | MLXLMCommon |
| `asr_api.py` | `ASRAPIClient.swift` | URLSession |
| `download.py` + monitor | `ModelDownloader.swift` | 子进程 → 结构化并发 Task |
| `model_cache.py` | `ModelCache.swift`（并入 Downloader） | 布局兼容 |
| `webrtcvad` | `WebRTCVAD.swift` | C 移植 |
| `Transport.swift`（socket） | `InProcessChannel.swift` | 接口同形 |

## 6. 必须原样保留的用户可见行为

1. 全部中文错误文案（「推理落后：已自动停止录音…」「翻译跟不上语速…」「请等待翻译模型操作结束」等，逐一从 server.py 抄录）。
2. 状态机与状态触发点（`recording` 才开始采集、离开 `recording` 无条件拆除、过载自动停止含错误事件）。
3. `final` 连续不重叠不去重；智能定稿阈值；预览复用。
4. 翻译事件节流（0.2 s）、占位事件、跳过语义（done+空文本）、会话后送达。
5. 配置文件位置、字段、版本号、权限（0600）；模型缓存布局；`translationTargets` 两端一致。
6. API Key 安全边界：仅内存、Keychain 存储、不落盘、不进后端配置；下载子进程剥离 offline 环境变量的等价物（Swift 版无环境变量问题，但下载任务必须允许联网、其余路径保持离线承诺）。

## 7. 风险与备选

| 风险 | 等级 | 缓解 |
| --- | --- | --- |
| Qwen3-ASR 无 Swift 实现，自移植模型结构出错 | **高** | Phase 0 spike 前置，逐层输出与 Python 版对拍；失败则项目止损 |
| 逐 token 让位调度在 Swift 的延迟/开销 | 中 | spike 里 benchmark；必要时批 N token 让位一次 |
| webrtcvad 移植的判定差异会改变切分 | 中 | 用同一 PCM 序列对拍 VAD 输出逐帧一致 |
| MLXLMCommon 对 Hunyuan-MT 架构支持缺口 | 中 | Phase 0 一并验证；缺口则手写该架构加载 |
| 内存峰值：双模型驻留（ASR+翻译）在 Swift 侧无 gc | 中 | 卸载路径显式释放 + `MLX.GPU.clearCache()`，对齐现有「切模型先卸载」时序 |
| tokenizer/聊天模板行为差异 | 中 | 用同一批文本对拍 prompt 字符串 |
| 备选方案 A：保留 Python 双进程但裁剪（Qwen-only 去 torch，DMG ~200 MB） | — | 若 Phase 0 失败的退路，1–2 天可做 |
| 备选方案 B：whisper.cpp + llama.cpp（~20 MB，但放弃 Qwen3-ASR 默认模型） | — | 产品上不可接受（默认模型变更），仅作记录 |

## 8. 测试策略

- **对拍为主**：过渡期保留 Python 后端可运行（`RECORDER_INPROCESS=0` 切回），同一 PCM/命令序列分别喂两版，断言事件序列一致（状态、文本、revision、错误）。
- 现有回归资产直接复用：`tests/test_core.py`（命令/分段/配置）、`test_endpoint.py`（智能定稿）、`test_translation.py`（规划器）、`scripts/test_audio.sh`（采集，不依赖后端改动）、`tests/fixtures/*.aiff`（端到端音频）。
- Swift 侧新增 XCTest 或 swift-testing 目标（当前项目无 XCTest，需在 `scripts/` 增加 `test_backend.sh`，沿用「显式文件列表 + swiftc -parse-as-library」模式）。
- 真模型验证沿用 `verify_*.py` 的场景清单，结果记入 `docs/VALIDATION.md`。

## 9. 验收标准（整体）

1. DMG ≤ 150 MB；bundle 内无 Python。
2. `tests/fixtures` 全量对拍一致；智能定稿行为与 `docs/SMART-ENDPOINTS.md` 记录一致。
3. 旧版用户数据（config.json、translation.json、models/ 缓存、Keychain）升级后无损可用。
4. 单次转写延迟、翻译吞吐不劣于 Python 版（±30% 以内）。
5. 全部中文文案与状态机行为不变；`scripts/package.sh` 拒绝打包权重的检查继续生效。
