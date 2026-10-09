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
| `android/core` | 纯 Kotlin/JVM：配置校验、session.update、事件关联、PCM16 解码、定稿后播放队列、WebSocket 客户端 | OkHttp、org.json（安卓系统自带） |
| `android/app` | 安卓应用：Compose 界面、麦克风、译音播放、Keystore 密钥、前台服务 | `:core`、Jetpack Compose |

`core` 不依赖 Android SDK，可在任何有 JDK 的机器上用仓库现有的 `tests/mock_livetranslate_server.py` 测试。

## 与 macOS 版保持一致的约束

- 固定模型 `qwen3.8-livetranslate-flash-realtime`；地址只接受 `wss://`，不允许用户名/密码、片段或除 `model` 以外的查询参数；拒绝重定向，密钥只发往所配置的主机。
- 会话顺序：`session.created` → `session.update` → 必须收到与所选输出方式、目标语言（以及 24 kHz PCM 译音格式）一致的 `session.updated` 才开始采集。
- 原文和译文只按 ID 关联（`conversation.item.created` 的 `previous_item_id`），不按文本或到达顺序；重复的 `event_id` 忽略；不对重复说出的内容去重。
- 停止时先停麦克风并等待最后一块音频入队，再发 `session.finish`，等待 `session.finished` 收尾（30 秒超时，已收到的文字保留）。
- 发送队列上限约 320 KB 原始 PCM；等待播放的译音上限 30 秒。
- 不保存录音和字幕历史（字幕只在内存中），API Key 按 `livetranslate:<endpoint>` 区分并加密保存；错误信息不回显服务端载荷和密钥。
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

### 阶段 2 · 稳定性与真机体验

- 回声：开启译音且使用扬声器时，改用 `VOICE_COMMUNICATION` 音源并启用 `AcousticEchoCanceler`，或检测到无耳机时提示。
- 音频焦点与路由：来电/其他应用占用麦克风时自动停止并提示；蓝牙耳机（SCO / LE Audio）输入输出路由。
- 网络：断线后自动重连新会话（保留旧字幕、明确标出断点），移动网络/Wi‑Fi 切换处理；弱网下的发送积压提示。
- 长会话：字幕条数上限与内存回收；后台运行时的通知内容更新（显示最新一句译文）。
- 单元测试扩展到 `SessionController`（Robolectric 或抽出纯 Kotlin 状态机）；真机冒烟测试清单写入 `docs/VALIDATION.md`。

### 阶段 3 · 字幕与使用场景

- 悬浮字幕窗（`SYSTEM_ALERT_WINDOW`），可在视频会议/其他应用上方显示译文。
- 系统音频翻译：Android 10+ `AudioPlaybackCapture`（MediaProjection），用于翻译视频、直播、会议应用的声音（受应用捕获策略限制）。
- 双向对话模式：两个目标语言快速切换，或分屏面对面显示。
- 字号、深色模式、仅显示译文等显示选项；导出 TXT/SRT（仍不自动保存历史）。

### 阶段 4 · 更多 API 组合（可选）

- 按需从 macOS 版移植其他纯 API 链路，作为 LiveTranslate 之外的备选：
  - 流式识别 `qwen-audio-3.0-asr-flash-streaming`（DashScope duplex 协议）+ OpenAI 兼容 `/chat/completions` 翻译；
  - 多服务配置档（按 base URL 保存，与 macOS `AIProfiles` 对应）。
- 用量与费用提示（会话时长、估算音频量）。

### 阶段 5 · 发布

- 正式签名（keystore 不入库，通过 CI Secret 注入）、R8 混淆验证、版本号与 `CHANGELOG`。
- 隐私政策（音频仅发往所配置的服务、不保存录音），应用商店素材；国内安卓商店与 Google Play 的权限说明（麦克风前台服务）。
- 发布说明写入 `docs/RELEASE-ANDROID-*.md`。

## 开发与验证

```bash
cd android
./gradlew -PcoreOnly=true :core:test   # 无需 Android SDK；需要 python3（mock 服务器）
./gradlew :app:assembleDebug           # 需要 Android SDK（ANDROID_HOME 或 local.properties 中的 sdk.dir）
```

第一版的已知限制：

- 当前开发环境无法访问 Google Maven / Android SDK，`:app` 的 Compose 界面未在本地编译；非界面代码已对照 Android 15 框架类编译通过，完整 APK 构建由 CI 完成，首次运行需在 CI 或本机 Android Studio 中确认。
- 尚未在真机和真实服务上验证（见阶段 1 验收）。
- 未做回声消除；外放译音时建议戴耳机。
