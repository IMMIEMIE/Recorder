# 首版验证记录

日期：2026-09-05。本机：Apple M5 Pro，48 GB 内存，macOS 26.5.1，arm64；开始时可用磁盘约 836 GiB。

## 已实际通过

- Swift release 构建、完整 Python 运行环境打包、临时代码签名；应用约 654 MB，模型约 4.08 GB，模型与运行环境分开。
- 真实桌面启动、设置/设备列表/状态 UI、应用内默认模型离线加载和预热。
- 固定模型 revision：`e1f6c266914abc5a46e8756e02580f834a6cf8a7`。
- 依赖：MLX Audio 0.5.1、MLX 0.32.2、Transformers 5.16.1、Hugging Face Hub 1.30.0、WebRTC VAD Wheels 2.0.14；全部包见 `requirements.lock`。
- 9 项自动化测试：配置校验/原子保存、长时间静音、前置缓冲与短尾句 flush、预览修订与停顿定稿、长语音有界及连续范围、碎片消息/长度限制、停止幂等与重复词保留、丢失序号可见错误、预览合并。
- 真实默认模型：中文、英文、中英混合系统合成样本的文件识别。识别文本与输入内容一致，英文数字间标点有自然变化。中英混合的「谢谢，谢谢」保留。
- 使用 **App 内置 Python** 和真实模型，通过 Unix socket 以实际音频速度输入三段样本，经历三个完整开始/停止会话；共 15 个预览、3 个最终段，没有重复最终提交，子进程正常退出。
- 测试中启用 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`。并未更改系统网络开关；这是依赖级离线模式验证，不等同于干净机器物理断网验收。
- 图标原图、多尺寸 PNG 与 ICNS 已生成，并配置到应用包。最终构建真实启动后，经应用内按钮从专属缓存加载默认模型，界面确认「准备就绪 · 模型已就绪 · 本地推理」。加载后的严格签名校验通过。

## 实测数据

第一次独立进程加载约 2.25 秒、预热 2.10 秒。重复运行利用系统缓存后加载 0.72 秒、预热 0.16 秒。尚未区分真正冷磁盘启动与系统页缓存，不能作为冷启动承诺。

| 合成样本 | 音频长度 | 文件识别耗时 | 实时管道停止至就绪 |
| --- | ---: | ---: | ---: |
| 中文 | 8.01 秒 | 0.505 秒 | 0.467 秒 |
| 英文 | 5.19 秒 | 0.487 秒 | 0.506 秒 |
| 中英混合 | 6.60 秒 | 0.392 秒 | 0.414 秒 |

第二轮文件验证进程最大 RSS 为 4,322,770,944 字节；MLX 报告峰值分配 5,172,307,744 字节。两者口径不同，不相加，均不是完整桌面应用峰值。

数据来自非常小的合成样本集，不能据此推断真人 CER/WER、噪声条件、P95 延迟或 30 分钟吞吐稳定性。停止至就绪的测试不包含等候自动停顿的 760 ms。

机器可读结果保存在 `model-verification.json`、`pipeline-verification.json`。测试脚本在 `scripts/` 中，可复现。

## 已发现并修复

- 工具沙盒无法访问 Metal：真实模型验证在获准的本机 GPU 环境进行。
- MLX Audio 0.3.1 默认强制 English；改为固定 0.5.1 的真实自动语言接口。
- 首次启动设备变更通知可能误判中断：先启动音频引擎，再观察真正停止引擎的配置变化。
- 停止时 AVAudioConverter 仍可能持有少量样本：增加 end-of-stream 排空后再发送 stop。
- 下载任务独立进程可取消，下载缓存保留；普通加载固定离线。
- 修改模型 ID 才清除 revision，程序读取成功配置不会意外清除版本信息。

- 应用启动禁用 Python bytecode 写入，将 Numba 缓存放到应用数据目录，避免修改已签名资源。
- 默认模型安装到应用专属缓存，避免后台访问受 macOS 保护的文稿目录；加载前的文件检查也移到工作线程。

## 待手工验收 / 已知限制

- 麦克风权限允许/拒绝、连续实际采集及实时重采样、44.1/48 kHz 设备对比、外设拔插、睡眠唤醒、全局快捷键及按住说话需要目标机器上的用户手工验收。界面开发期间看到了设备切换提示，已修复启动误报；不声称修复后经过完整硬件验收。
- 本地临时签名在重建后可能导致 macOS 重新请求麦克风权限。稳定分发需要固定开发者签名及必要公证。
- 没有连续 30 分钟真人录音或干净机器安装验证；首版用于本机试用。
- 当前强制分段是相邻、不重叠的音频范围，没有实现边界音频重叠融合；保证不会文本误去重，但跨切点词语可能受影响。
- 配置中语言/窗口等修改需重新「加载并保存」后生效。快捷键提供三个预设按键组合，并非任意组合录制器。
- 未实现可选系统输入、历史、导出、字幕、说话人分离、精确词级时间戳。

## 2026-09-26 — LiveTranslate 独立模式

- `scripts/test_livetranslate.sh`：本机真实 WebSocket 握手、文本输出配置确认、PCM 队列顺序、原文/译文关联、重复及迟到事件、UTF-8、停止收尾、无音频连接测试、取消、断线、鉴权/限流错误、错误输出模态和超时均通过。
- 使用合成 WAV 经 `AppModel` 的文件输入流程到模拟 WebSocket，确认 EOF 尾句、双语记录与导出、连续两次会话及旧回调隔离；验证启用状态恢复后无需 Python 运行环境或本地模型，其他识别/翻译加载入口被禁用。
- `scripts/test_ai.sh`、`scripts/test_audio.sh` 通过；Python 回归测试 64 项通过。新增界面和悬浮双语字幕已用原生 macOS 视图渲染检查。
- 未使用真实服务密钥，未测量真实翻译质量和延迟。本轮未现场采集麦克风或系统声音；这两种音源复用现有采集及统一 PCM 通道，现场权限和设备行为仍需实际使用验证。
- LiveTranslate 只请求文字，密钥独立存入钥匙串；测试使用虚构密钥和合成音频，不读取现有服务密钥。

## 2026-09-26 — Qwen Audio 3.1 实时接口识别

- `scripts/test_qwen_asr.sh`：真实本机 WebSocket 握手，WSS 配置校验、PCM 原样与顺序、手动提交模式确认、输入转写增量/最终事件、重复事件与 Unicode、回答事件隔离、无音频连接测试、鉴权/服务错误、断线、错误模式、超时与取消均通过。
- Python 回归 65 项通过；新增桥接测试覆盖多块 PCM、过期请求结果隔离、不发送识别预览和等待最终结果后恢复就绪。Qwen 密钥由原生客户端读取，后端只收到音频、请求 ID 与识别结果。
- 该接入按本机停顿分段后提交到实时接口，不是持续上传全程录音。未使用真实千问密钥，模型权限、真实识别效果及延迟仍需用户在「测试连接」及实际转写中验证。

## 2026-09-26 — WebSocket 流式识别（qwen-audio-3.0-asr-flash-streaming）

- 按官方 DashScope duplex 协议替换原「千问实时语音」逐段提交：录音全程保持一个识别任务，音频约 100 ms 一帧持续上传，中间结果实时显示，服务端断句后的整句进入原有定稿与翻译流程。原 `asr_bridge.py`、`asr_api_audio`/`asr_api_result` 与 `scripts/test_qwen_asr.sh` 已移除。
- `scripts/test_streaming_asr.sh`：本机真实 WebSocket 握手、run-task 参数（格式、采样率、语种提示、停顿阈值、心跳）、任务启动前拒收音频、~100 ms 帧合并与 PCM 原样、中间结果与心跳过滤、其他任务事件忽略、整句顺序先于结束回调、无音频连接测试、401/重定向/task-failed/服务端关闭/意外结束/连接与尾句超时、密钥脱敏均通过。
- Python 回归 65 项通过；新增测试覆盖流式会话不建本地分段器并拒收后端音频、跨会话与重复结果处理、定稿先于结束就绪。`test_livetranslate.sh`、`test_ai.sh`、`test_audio.sh` 通过，`scripts/build.sh` 构建成功。
- 未使用真实密钥，真实识别效果与延迟需用户在「测试连接」与实际转写中验证。

## 2026-09-28 — LiveTranslate 译音输出

- 新增可选译音输出和音量，使用系统当前输出设备；旧配置迁移保持原服务/语言/开关，默认关闭译音。
- LiveTranslate 回归测试通过：文字模式、音频模式协商、音频字幕事件、重复音频消息、跨消息 PCM 样本拼接、损坏数据、错误采样率，以及原有文件输入流程和连接异常。
- 使用 AVAudioEngine 离线渲染验证 PCM 播放、音量和队列收尾，测试不向扬声器播放声音。实体扬声器/耳机及真实模型译音质量尚未验证。
- 系统声音采集仍通过 excludesCurrentProcessAudio 排除声笺自身；麦克风模式建议使用耳机，避免扬声器声音被重新收录。


### LiveTranslate 可选播放时机

- 新增「边说边播放」和「定稿后播放」，保存后下次会话生效；旧配置默认延续边说边播放。
- 定稿模式按服务端消息 ID 关联原文和译音，等待原文、译文及音频结束事件后按句序释放，停止本次播放时清除缓存。缓存上限为 30 秒译音；超限停止本次播放并提示，字幕继续更新。
- 回归覆盖音频早于关联信息、原文晚定稿、后句先完成、重复事件、缓存限制及旧设置迁移；真实服务的最终分句时机由服务端决定。

### LiveTranslate 分段译音重播

- 已定稿且完整收到译音的文本块右下角显示播放按钮，支持再次播放、停止和切换段落；重播会停止本次自动译音，字幕继续更新。
- 译音仅缓存在内存中，清空文本或退出应用后释放；完成片段最多保留 128 MB，超出时淘汰最早片段，单段上限 30 秒。
- `scripts/test_livetranslate.sh` 通过，新增覆盖音频先到、定稿与音频完成关联、重复事件、重复读取、跨会话隔离、容量淘汰和清空；现有 WebSocket、文件输入与离线播放回归通过。尚未用真实服务及实体输出设备验收重播。

## 2026-09-30 — mlx-swift 单进程重构（0.4.0）

### Phase 3 模型层对拍（macOS 27.0，Apple Silicon，release 构建）

| 模型 | 三个 fixture 文本 | 单次耗时 Swift / Python | MLX 峰值 Swift / Python |
| --- | --- | --- | --- |
| Qwen3-ASR-1.7B-bf16（auto） | 与 `model-verification.json` 逐字一致 | 865/930/744 ms vs 505/487/392 ms | 4.95 GB / 5.17 GB |
| whisper-large-v3-turbo（auto） | 与 `whisper-verification.json` 逐字一致 | 744/680/717 ms vs 469/424/451 ms（`--language Chinese` 504 ms） | 2.18 GB / 2.55 GB |
| Qwen3-4B-Instruct-2507-4bit 翻译 | 译文合理，无 `<think>` | 首 token 176–182 ms，21–30 tok/s | 2.52 GB |

Swift 版单次转写慢约 1.6–1.8×（spike 时 ≈1.0×），待空载复测。数据：`docs/*-verification-swift.json`。

### Phase 4 下载器

按 `spikes/HANDOFF.md` 的 Phase 4 清单在 macOS 上验证通过（提交 `3f51422` 含三处编译/测试修正）：缓存布局与 huggingface_hub 相同，Python 与 Swift 两版可共用同一份缓存。

### Phase 5（删除 Python 后端）— 2026-10-01 在 macOS 27.0（Apple Silicon，Xcode 27.0 + Metal Toolchain 27A266a）验证通过

按 `spikes/HANDOFF.md` §4 清单逐项执行：

- **编译**：`swift build -c release` 与 `--product RecorderVerify` 通过。修正一处编译错误：`InProcessChannel.swift` 协议成员误标 `public`（Swift 不允许，协议本身已 `public`），见提交 `b018e08`。其余仅警告（Swift 6 并发、`cblas_dgemm` 弃用）。
- **metallib**：`scripts/build_metallib.sh` 从 mlx-swift 0.32.2 源码编出 `.build/metallib/mlx.metallib`（2.35 MB）。前置条件：`sudo xcodebuild -license accept` + `xcodebuild -downloadComponent MetalToolchain`；xcode-select 指向 CommandLineTools 时需 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- **测试脚本**：`test_backend.sh` 54 项、`test_download.sh` 7 项、`test_livetranslate.sh`、`test_ai.sh`、`test_audio.sh`、`test_streaming_asr.sh` 全绿。
- **模型对拍**（自编 metallib）：`verify_inprocess.sh asr / whisper` 三个 fixture 文本与 Python 基线（`docs/*-verification.json`）逐字一致——同时证明自编 metallib 与 wheel 版 `mlx.metallib` 等效。`translate`：译文干净无 `<think>`，首 token 175–176 ms，24–30 tok/s。
- **pipeline**（`docs/pipeline-verification-swift.json`）：`passed: true`。三个 fixture final 文本与 Python 基线一致（mixed 仅空格级差异 `Python 和 Swift`/`Python和Swift`，近义 token 浮动，规格允许）；Qwen→Whisper→Qwen 切换文本逐字一致，回切后 active bytes 4,082,276,760 → 4,082,281,900（ratio 1.000 ≤ 1.10）；同语言目标（中→简体中文）正确跳过。译文与 Python 基线存在生成级浮动（日译「スピーキング/スピーチ」等），语义等价。
- **打包**：`build.sh && package.sh` 产出 `声笺-0.4.0-arm64.dmg` **15.3 MB**（0.3.1 为 574 MB；app 本体 50 MB，无 Python runtime）。向 bundle 临时放入 `x.safetensors` 后 `package.sh` 正确拒绝打包；移除后重打通过，sha256 校验 OK。
- **升级回归**（0.3.x 数据）：DMG 替换安装 /Applications 旧版，模型缓存与 `config.json`（钉 revision `e1f6c26…`）/`translation.json` 原地沿用，启动无 Python sidecar。人工实测：麦克风转写、本地翻译、字幕模式、TXT 导出、API 识别、WebSocket 流式识别、LiveTranslate 全部正常。
- 全新用户目录安装（无 config → refs/main→mtime 解析 + 应用内下载默认模型）路径未在本轮覆盖。

### 遗留开放项

- **推理速度**：Phase 3 单发 1.6–1.8× 差距仍在；pipeline 实测单次调用 534–737 ms（Python smart 定稿历史值 ~288 ms/call，段长不同非严格可比）。待空载复测 + Instruments 定位（候选：MLXRuntime 队列切换、kernel JIT、mel 前端）。
- Hunyuan-MT-7B-4bit 分词器：未缓存未测；若快照无 `tokenizer.json`，`AutoTokenizer.from(modelFolder:)` 会失败（走翻译失败路径，不影响识别）。
- `verify_endpoints.py` 的旧定稿对比未移植（与「从不强制定稿」设计矛盾）；智能定稿指标可与 `docs/endpoint-*-metrics.json` 历史值对照。

## 2026-10-10 — 声笺安卓版 0.2.0（阶段 2：稳定性）

环境：macOS 27.0，Android Studio 自带 JBR 25 启动 Gradle 8.14.3（守护进程 JDK 17 自动下载），Android SDK Platform 35，模拟器 Medium Phone API 37（arm64，无声卡）。

### 已实际通过

- `cd android && ./gradlew :core:test`：22 项全绿（会话状态机 11 项、WebSocket 客户端 6 项、协议逻辑 5 项）。`scripts/test_livetranslate.sh`（与安卓共用的 mock 服务器新增了两条路由）全绿。
- `./gradlew :app:assembleDebug` 首次在本机编译通过（0.1.0 的 Compose 界面此前只在 CI 构建）；`:app:lintDebug` 无错误。
- 模拟器端到端（调试构建经 `adb reverse` 连接 `tests/mock_livetranslate_server.py`，凭据为 fixture 的 `mock-only`）：
  - 设置页保存地址与密钥、测试连接成功；开始后进入「正在转写」，前台服务类型为 microphone，出现示例原文与译文；通知正文更新为最新译文。
  - 会话中结束 mock 进程：状态变为「连接中断，正在重新连接（第 n 次）」，字幕保留并出现分隔行；重启 mock 后自动恢复转写。停止后尾句定稿、服务退出。
  - 开启译音：未检测到耳机的提示、`VOICE_COMMUNICATION` 音源、24 kHz AudioTrack 启动、「停播」按钮；停止后尾音播完自动释放。
  - 会话中开关飞行模式：「网络已断开，等待恢复…」→ 恢复后立即重连。

### 真机冒烟清单（尚未执行，需要真实 API Key）

1. 开始 → 说话 → 实时出现原文与译文 → 停止后末句完整；错误 Key、断网启动时显示中文错误。
2. 会话中关闭 Wi‑Fi 切到移动数据、再切回：字幕出现分隔行并继续，重连前后各说一句确认补发的音频被识别。
3. 开飞行模式 10 秒再关闭：等待后自动恢复；超过 60 秒不恢复则停止并保留文字。
4. 连续翻译 30 分钟以上：确认服务端是否主动结束会话（若有，应自动续接）、内存平稳、锁屏/切到后台后仍在转写且通知显示最新译文。
5. 开启译音、不戴耳机外放：记录机型是否支持回声消除，以及译音是否被再次识别；戴有线/蓝牙耳机后不应出现回声提示。
6. 会话中拨入或拨出电话：约 2 秒后自动停止并提示麦克风被占用（Android 10+）。
7. 播放译音时打开音乐或视频应用：译音停止、字幕继续。
8. 设置中开启「使用蓝牙耳机麦克风」并连接耳机：确认由耳机收音、译音从耳机播放；断开耳机后再开始应回退到手机麦克风并提示。
9. 通知栏「停止」按钮、返回桌面后从通知回到应用。
