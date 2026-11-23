# 声笺安卓版 · 分阶段计划

## 定位

声笺安卓版只做一件事：**实时语音翻译**，而且完全依靠云端 API 实现。macOS 版的本地 MLX 推理、模型下载与缓存、本地/API 转写后端、本地翻译模型、AI 工作区、文件/系统音频输入和导出格式在安卓版中全部去掉。

核心链路复用 macOS 版已验证的 LiveTranslate 协议（`Sources/Recorder/LiveTranslate*.swift`）：

```
麦克风 (AudioRecord, 16 kHz 单声道 PCM16, 100 ms/块)
  → LiveTranslateClient (OkHttp WebSocket, wss://…/api-ws/v1/realtime?model=qwen3.8-livetranslate-flash-realtime)
  → 服务端 VAD 断句 + 同时返回原文与译文（可选 24 kHz 译音）
  → LiveTranslateEvents 按 item_id 关联原文/译文 → Compose 字幕列表
  → （可选）LiveTranslatePlaybackQueue → AudioTrack 播放译音
```

代码位于仓库的 `android/` 目录，与 macOS 版共存于同一仓库：

| 模块 | 内容 | 依赖 |
| --- | --- | --- |
| `android/core` | 纯 Kotlin/JVM：配置校验、session.update、事件关联、PCM16 解码、定稿后播放队列、WebSocket 客户端、会话状态机 `LiveSession`（重连、网络切换、积压、字幕上限） | OkHttp、org.json（安卓系统自带） |
| `android/app` | 安卓应用：Compose 界面、麦克风、译音播放、Keystore 密钥、前台服务、音频路由与网络回调（`LiveSession` 的平台适配） | `:core`、Jetpack Compose |

`core` 不依赖 Android SDK，可在任何有 JDK 的机器上用仓库现有的 `tests/mock_livetranslate_server.py` 测试。

## 与 macOS 版保持一致的约束

- Qwen 3.8 预设模型为 `qwen3.8-livetranslate-flash-realtime`，具名配置可指定其他兼容模型；地址只接受 `wss://`，不允许用户名/密码、片段或除 `model` 以外的查询参数；拒绝重定向，密钥只发往所配置的主机。
- 会话顺序：`session.created` → `session.update` → 必须收到与所选输出方式、目标语言（以及 24 kHz PCM 译音格式）一致的 `session.updated` 才开始采集。
- 原文和译文只按 ID 关联（`conversation.item.created` 的 `previous_item_id`），不按文本或到达顺序；重复的 `event_id` 忽略；不对重复说出的内容去重。
- 停止时先停麦克风并等待最后一块音频入队，再发 `session.finish`，等待 `session.finished` 收尾（30 秒超时，已收到的文字保留）。
- 发送队列上限约 320 KB 原始 PCM；等待播放的译音上限 30 秒。
- 不保存录音、译音和未定稿的字幕；已定稿的原文和译文按 `docs/SESSIONS.md` 保存为会话（默认开启，可在设置中关闭），只存本机、不参与备份和设备迁移。API Key 按 `livetranslate:<endpoint>` 区分并加密保存；错误信息不回显服务端载荷和密钥。
- 会话文件格式、默认标题、导出内容与文件名和 macOS 完全一致（`docs/SESSIONS.md`，夹具 `tests/fixtures/session_export/`）。
- 设置 JSON 与 macOS 的 `livetranslate.configuration.v1` 字段一致。

## 阶段

### 阶段 0 · 分支与工程骨架 ✅（本次完成）

- 分支 `claude/tender-hypatia-k13p5b`，新增 `android/` Gradle 工程（Gradle 8.14.3 wrapper、AGP 8.9、Kotlin 2.1、minSdk 26 / targetSdk 35）。
- `:core` 与 `:app` 拆分；`-PcoreOnly=true` 可在没有 Android SDK 的机器上只构建/测试 `:core`。
- GitHub Actions `.github/workflows/android.yml`：运行 `:core:test` 并构建调试 APK（作为构件上传）。

### 阶段 1 · 第一版 MVP：麦克风实时翻译 ✅（本次完成，v0.1.0）

- LiveTranslate 协议移植到 Kotlin（配置校验、握手确认、事件关联、错误映射、收尾超时、取消后不再回调）。
- 麦克风采集（`VOICE_RECOGNITION` 音源）、前台服务（`microphone` 类型，通知栏可停止），录音中保持屏幕常亮。
- 字幕界面：原文（灰）+ 译文（大字），未定稿内容半透明，自动滚动到底部；多次会话的字幕依次保留，可复制全部、清空。
- 设置页：服务地址、专用 API Key（Android Keystore AES-GCM 加密）、8 种目标语言、译音开关、边说边播/定稿后播、音量、测试连接（只建会话不发音频）。
- 可选译音播放（AudioTrack 24 kHz，非阻塞写入，可随时停播）。
- 测试：`:core` 9 项 JVM 测试，覆盖配置兼容与校验、PCM 拼接与重复/损坏数据、定稿后播放顺序与内存上限、事件关联，以及基于 mock WebSocket 服务器的握手、尾句收尾、译音、401/重定向/服务错误/模式不符/断线/超时、发送队列上限和取消。

**验收**：在真机上用真实 API Key 完成「开始 → 说话 → 实时看到原文与译文 → 停止后末句完整」；开启译音后能听到翻译；错误 Key、断网时显示中文错误且已有文字保留。

### 阶段 2 · 稳定性与真机体验 ✅（v0.2.0，模拟器验证；真机清单见 `docs/VALIDATION.md`）

- **会话状态机抽到 `:core`**：`LiveSession` 不依赖 Android，通过 `SessionPlatform`（麦克风、播放器、定时器、前台服务）驱动；`SessionController` 只做平台适配。一次用户会话可以跨多条 LiveTranslate 连接。
- **断线自动重连**（可在设置中关闭）：连接中断或服务端自行结束会话时，保留已有字幕、插入「连接中断，此处内容可能有缺失」分隔行，按 0.5/1/2/4/8 秒退避建立新会话，连续 5 次失败后停止；重连成功并稳定 30 秒后计数清零。麦克风在重连期间不停，新连接就绪后只补发最近 1 秒音频（`LiveSession.CATCH_UP_MS`），其余丢弃，之后按实时节奏发送——一次补发 5 秒会让服务端长期只按约 0.45 倍实时读取（issue #24；此前的构建补发最近 5 秒）。首次连接同样只补发 1 秒。只重试「连接本身失败 / 服务端结束会话 / 连接超时」，鉴权、额度、配置不符等错误直接结束；会话的首次连接不重试。服务端限流（关闭码 1007 或原因含 rate limit）不计入 5 次：至少等 20 秒再试，之后 40/80/160 秒，仍限流则停止；状态显示「服务限流，N 秒后重试」。60 秒无识别结果被关闭时立即续接，不插分隔行、不计入失败。任意 60 秒内最多建立 8 次连接（服务端约每分钟 10 次）。重连状态里显示最近一次断开的原因（类别 + 简短说明，不含密钥）。
- **网络切换**：监听默认网络。Wi‑Fi ↔ 移动数据切换时立即换新连接（不等旧连接超时）；完全断网时不消耗重试次数，等待恢复，最长 60 秒。
- **弱网**：发送积压超过约 1.5 秒（`SHED_AUDIO_BYTES`）时暂停上传、丢弃新的音频块并提示「网络较慢」，降到约 0.3 秒（`RESUME_AUDIO_BYTES`）以下后恢复，在字幕中插入「网络拥塞，约 N 秒语音未翻译」（会话文件里记为 `break` 行）。积压不再触发重连；只有积压约 8 秒（`STALL_MS`）完全不下降才按断线处理（关闭自动重连时停止录音）。此前的构建是积压 3 秒提示、10 秒重连，重连后的补发又造成新的积压（issue #24）。
- **回声**：开启译音且未检测到耳机（有线 / USB / 蓝牙）时，麦克风改用 `VOICE_COMMUNICATION` 音源并启用 `AcousticEchoCanceler`，同时提示建议佩戴耳机。
- **麦克风被占用**：Android 10+ 通过录音配置回调检测本应用被系统静音（来电、优先级更高的录音应用）超过 2 秒，自动停止并提示。
- **音频焦点**：播放译音时申请可压低其他应用的短暂焦点；被通话或其他播放器夺走时停止译音，字幕继续。
- **蓝牙耳机麦克风**（设置中可选，默认关）：Android 12+ 用 `setCommunicationDevice`（SCO / LE Audio），更早版本用 `startBluetoothSco`；译音同时走通话通路。未连接耳机时回退到手机麦克风并提示。
- **长会话**：每条连接只按 ID 跟踪最近 200 行，更早的行冻结进历史；历史最多 1000 行，超出后移除最早的并在列表顶部说明；事件去重只记最近 4096 个 `event_id`。
- **通知**：前台通知显示本次会话最新一句译文（每秒最多更新一次），重连时标题改为「正在重新连接」。
- **界面**：重连状态与按钮、断点分隔行、弱网提示；仅当停留在列表末尾时自动跟随新字幕，往回翻阅时出现「回到最新」。
- **测试**：`:core` 共 22 项——`LiveSessionTest` 用假连接、假麦克风和虚拟时钟覆盖重连顺序与补发、退避与放弃、网络丢失/切换、积压、麦克风失败、译音跟随会话、字幕上限；`LiveTranslateClientTest` 新增经真实 WebSocket 的掉线重连（mock 路由 `/drop-once/<name>`、`/finished-early`）与各错误是否可重试。
- **构建**：`gradle/gradle-daemon-jvm.properties` 把 Gradle 守护进程固定为 JDK 17（缺失时自动下载），因此用 Android Studio 自带的 JDK 25 也能直接构建。调试构建额外允许 `ws://127.0.0.1`，可通过 `adb reverse` 连接仓库里的 mock 服务器做端到端验证。

### 会话管理与导出 ✅（issue #13，与 macOS 同一规范）

- **会话记录**：每次「开始实时翻译」新建一个会话；在历史会话上「继续录制」追加新的一段，导出和查看时显示「继续录制 yyyy-MM-dd HH:mm」。只保存已定稿的行（原文定稿后保存，译文定稿后就地补上；断线分隔行保存为 `break` 行），写盘约 1 秒节流，停止录制和应用进入后台时立即写。文件为 `filesDir/sessions/<id>.json`（临时文件 + rename 原子写入），损坏或更高版本的文件跳过、不删除。
- **「保存会话记录」开关**（`android.options.v1` 的 `saveSessions`，默认开）：关闭后不再写盘，新会话只保留到应用退出；已有会话仍可查看、导出、删除。
- **界面**：手机用抽屉、宽度 ≥ 840dp 用常驻侧栏；顶部「新建会话」，按最后更新分组「今天 / 昨天 / 7 天内 / 更早」，录制中的会话有标记；长按或顶栏菜单可重命名（留空恢复自动标题）、导出、删除（需确认，录制中的会话不能删）；设置中「清空全部会话」（需确认）。录制时可以浏览其他会话，新内容仍写入正在录制的会话。
- **导出**：TXT / Markdown，双语 / 仅原文 / 仅译文；系统分享（`ACTION_SEND` 文本）、「保存到文件」（`ACTION_CREATE_DOCUMENT`，不申请存储权限）或复制到剪贴板。只含定稿文字，不含服务地址和 API Key。
- **代码**：`:core` 的 `com.localrecorder.sessions`（`SessionRecord`、`SessionStore`、`SessionExport`、`SessionRecorder`）；应用侧 `SessionLibrary` 在单独的 I/O 线程读写文件。
- **测试**：`SessionExportTest` 逐字节对比夹具（导出、文件名、默认标题，时区 `Asia/Shanghai`）；`SessionStoreTest` 覆盖往返、重命名、删除、损坏/新版本文件跳过、原子写入；`LiveSessionTest.recorderKeepsOnlyFinalizedRows` 用虚拟时钟验证只存定稿行、节流写入、停止时立即写、继续录制与无内容会话的丢弃。

### 阶段 3 · 字幕与使用场景

- 悬浮字幕窗（`SYSTEM_ALERT_WINDOW`），可在视频会议/其他应用上方显示译文。
- 系统音频翻译：Android 10+ `AudioPlaybackCapture`（MediaProjection），用于翻译视频、直播、会议应用的声音（受应用捕获策略限制）。
- 双向对话模式：两个目标语言快速切换，或分屏面对面显示。
- 字号、深色模式、仅显示译文等显示选项；导出 SRT。

### 阶段 4 · 更多 API 组合（可选）

- 按需从 macOS 版移植其他纯 API 链路，作为 LiveTranslate 之外的备选：
  - 流式识别 `qwen-audio-3.0-asr-flash-streaming`（DashScope duplex 协议）+ OpenAI 兼容 `/chat/completions` 翻译；
  - 多服务配置档（按 base URL 保存，与 macOS `AIProfiles` 对应）。
- 用量与费用提示（会话时长、估算音频量）。

### 阶段 5 · 发布

- ✅ 正式签名（keystore 不入库，通过 CI Secret 注入）、R8 + 资源压缩、体积上限 10 MB（`scripts/check_android_apk.sh`）；推送 `v<版本>` 标签由 `.github/workflows/release.yml` 构建签名 APK 并上传到 GitHub Release。
- 与 macOS 统一版本号、同一 Release 同时发布 DMG 与 APK（issue #13）。
- 隐私政策（音频仅发往所配置的服务、不保存录音），应用商店素材；国内安卓商店与 Google Play 的权限说明（麦克风前台服务）。
- 发布说明写入 `docs/RELEASE-ANDROID-*.md`。

## 开发与验证

```bash
cd android
./gradlew -PcoreOnly=true :core:test   # 无需 Android SDK；需要 python3（mock 服务器）
./gradlew :app:assembleDebug           # 需要 Android SDK（ANDROID_HOME 或 local.properties 中的 sdk.dir）
```

已知限制（v0.2.0）：

- 仍未在真机和真实服务上验证（阶段 1 验收与 `docs/VALIDATION.md` 的真机清单）。模拟器没有回声消除、蓝牙和通话，以下路径只经过编译和代码审查：回声消除效果、蓝牙耳机麦克风路由、来电时自动停止、音频焦点被夺。
- 外放译音时回声消除的效果因机型而异，仍建议佩戴耳机；会话进行中插拔耳机不会重新选择音源。
- 重连期间只补发最近 1 秒音频；已发送但服务端尚未返回结果的那一句会丢失（分隔行标出位置）。网络拥塞时丢弃的语音不会翻译（「网络拥塞」行标出位置）。
- LiveTranslate 是否限制单次会话时长未经实测；若服务端主动结束会话，会按断线自动续接。
