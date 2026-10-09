# 声笺安卓版

只保留实时翻译：麦克风音频通过 WebSocket 发送到 Qwen3.8 LiveTranslate（`qwen3.8-livetranslate-flash-realtime`），实时显示原文与译文，可选播放译音。没有本地模型，所有识别与翻译都由云端 API 完成。

分阶段计划见 [`docs/ANDROID-PLAN.md`](../docs/ANDROID-PLAN.md)。

## 构建

需要 JDK 17+。

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
  - `LiveTranslateClient` OkHttp WebSocket 会话（单线程状态机、拒绝重定向、发送队列上限、收尾超时）。
- `app/` — 安卓应用：
  - `SessionController` 会话状态（主线程）、字幕行、设置保存与测试连接；
  - `MicrophoneSource`（AudioRecord 16 kHz）、`SpeechPlayer`（AudioTrack 24 kHz）；
  - `SecretStore`（Android Keystore AES-GCM 加密 API Key）、`SettingsStore`；
  - `RecordingService` 麦克风类型前台服务；`MainActivity` Compose 界面。

## 使用

1. 打开「设置」，填写 LiveTranslate 服务地址（默认 `wss://maas.qianwenaiapi.com/api-ws/v1/realtime`）和专用 API Key，选择目标语言，点「保存」，可先「测试连接」。
2. 回到主界面点「开始实时翻译」，授予麦克风（和通知）权限后开始说话。
3. 点「停止」后会等待服务端返回最后一句。

隐私：开始翻译后麦克风音频会持续发送到所配置的服务；应用不保存录音，字幕只在内存中。API Key 加密保存在本机，不参与备份。
