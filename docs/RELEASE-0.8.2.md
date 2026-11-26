# 声笺 0.8.2

本版为 macOS 与 Android 双端新增转译系统声音模式，支持在主页面切换「麦克风 / 系统声音 / 系统声音 + 麦克风」混音采集，并在 Android 端提供可选悬浮字幕窗。

## macOS 端

- **主页面与菜单栏快捷模式切换**：底部控制区上方新增音频输入分段胶囊（麦克风、系统声音、系统声音 + 麦克风），与左侧「音频输入」栏（保留音频文件输入）及菜单栏双向同步；空闲时可一键切换、录制中自动锁定，重启应用后记住上次选择。
- **系统声音 + 麦克风软混音**：并发采集 ScreenCaptureKit 系统音频（排除声笺自身译音）与麦克风，以 20 ms 固定节拍对齐混音、静音自动补零、软限幅防削波，并在未佩戴耳机时给出温和提示。
- **权限状态与直达引导**：显示屏幕与系统音频录制权限状态，提供一键「前往系统设置」入口，并同步补齐九种界面语言词条。[macOS 系统声音改动](https://github.com/IMMIEMIE/Recorder/pull/47)（实现 [#44](https://github.com/IMMIEMIE/Recorder/issues/44)）

## Android 端

- **系统声音捕获与混音模式**：主页面底部控制坞上方新增音源切换条（麦克风、系统声音、系统 + 麦），空闲可切、录制中锁定，与「双人对话」互斥；Android 8–9 自动禁用系统声音入口并提示需 Android 10 及以上版本。
- **Android 10+ 音频捕获与 14/15 合规**：基于 `AudioPlaybackCapture` + `MediaProjection` 捕获其他应用播放的声音（通过 `excludeUid` 排除声笺自身译音），支持纯 JVM 混音器与持续静音受限应用提示；按模式动态声明前台服务类型（`microphone` / `mediaProjection` / 组合），会话内断线重连无需重复弹窗授权。
- **可选悬浮字幕窗**：支持「显示在其他应用上层」权限按需引导（未授权不影响应用内、分屏与通知栏使用），后台转译时自动显示、切回应用自动隐藏，支持拖动记位置、双语 / 仅译文切换、回到应用与一键停止；同步补齐九种界面语言词条。[Android 系统声音与悬浮字幕改动](https://github.com/IMMIEMIE/Recorder/pull/46)（实现 [#45](https://github.com/IMMIEMIE/Recorder/issues/45)）

## 安装

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| Android | `Recorder-0.8.2-android.apk` | Android 8.0 或更新（系统声音捕获需 Android 10 及以上），使用正式发行签名。 |
| macOS | `Recorder-0.8.2-arm64.dmg` | Apple Silicon，macOS 14 或更新。使用 ad-hoc 签名，尚未经 Apple 公证。 |

每份安装包均附有 SHA-256 校验文件。
