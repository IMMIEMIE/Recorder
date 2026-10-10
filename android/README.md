# 声笺安卓版

只保留实时翻译：麦克风音频通过 WebSocket 发送到 Qwen3.8 LiveTranslate（`qwen3.8-livetranslate-flash-realtime`），实时显示原文与译文，可选播放译音。没有本地模型，所有识别与翻译都由云端 API 完成。

分阶段计划见 [`docs/ANDROID-PLAN.md`](../docs/ANDROID-PLAN.md)。

## 构建

需要能启动 Gradle 的任意 JDK（包括 Android Studio 自带的 JBR）：Gradle 守护进程固定使用 JDK 17，本机没有时会按 `gradle/gradle-daemon-jvm.properties` 自动下载。命令行构建若没有 `java`，可先 `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`。

```bash
./gradlew -PcoreOnly=true :core:test   # 协议核心测试，无需 Android SDK（mock 服务器需要 python3）
./gradlew :app:assembleDebug           # 需要 Android SDK；APK 位于 app/build/outputs/apk/debug/
```

也可以直接用 Android Studio 打开 `android/` 目录。GitHub Actions（`.github/workflows/android.yml`）会运行测试并上传调试 APK。

## 结构

- `core/` — 纯 Kotlin/JVM，从 macOS 版 `LiveTranslate*.swift` 移植：
  - `LiveTranslateConfig` 地址校验、固定模型、`session.update`、与 macOS 相同的设置 JSON；
  - `LiveTranslateEvents` 按 item ID 关联原文和译文；
  - `LiveTranslateAudioDecoder` / `LiveTranslatePlaybackQueue` 拼接 PCM16、定稿后按句播放；
  - `LiveTranslateClient` OkHttp WebSocket 会话（单线程状态机、拒绝重定向、发送队列上限、收尾超时）；
  - `LiveSession` 会话状态机：一次会话可跨多条连接（断线重连、网络切换、弱网积压、字幕上限），通过 `SessionPlatform` 接口使用麦克风、播放器和定时器，不依赖 Android。
- `app/` — 安卓应用：
  - `SessionController` 实现 `SessionPlatform`（主线程），并负责设置保存、测试连接、通知内容；
  - `MicrophoneSource`（AudioRecord 16 kHz，外放译音时走回声消除通路）、`SpeechPlayer`（AudioTrack 24 kHz，带音频焦点）、`AudioRouting`（耳机检测、蓝牙耳机麦克风）；
  - `SecretStore`（Android Keystore AES-GCM 加密 API Key）、`SettingsStore`（与 macOS 相同的配置 JSON，另存安卓专有选项）；
  - `RecordingService` 麦克风类型前台服务，通知显示最新译文；`MainActivity` Compose 界面。

## 使用

1. 打开「设置」，填写 LiveTranslate 服务地址（默认 `wss://maas.qianwenaiapi.com/api-ws/v1/realtime`）和专用 API Key，选择目标语言，点「保存」，可先「测试连接」。
2. 回到主界面点「开始实时翻译」，授予麦克风（和通知）权限后开始说话。
3. 点「停止」后会等待服务端返回最后一句。

连接中断或切换网络时会自动建立新会话并在字幕中标出断点（可在设置中关闭）；开启译音但没戴耳机时会启用回声消除并提示。

## 用 mock 服务器做端到端验证

调试构建允许 `ws://127.0.0.1`（正式构建只接受 `wss://`），可以不用真实 API Key 在模拟器或真机上跑通整条链路：

```bash
python3 ../tests/mock_livetranslate_server.py /tmp/port.txt &
adb reverse tcp:18080 tcp:$(cat /tmp/port.txt)
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

在应用设置里把服务地址填成 `ws://127.0.0.1:18080/ok`、API Key 填 `mock-only`。开始后会出现固定的示例字幕；中途结束 mock 进程再重启（并重新执行 `adb reverse`）可以观察自动重连。

隐私：开始翻译后麦克风音频会持续发送到所配置的服务；应用不保存录音，字幕只在内存中。API Key 加密保存在本机，不参与备份。
