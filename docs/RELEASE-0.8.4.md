# 声笺 0.8.4

本版是 Android 端的小幅修复版本：修正录制系统声音或连续语音时悬浮字幕窗对长句末尾省略导致无法及时看到最新文字的问题。macOS 端悬浮字幕原有尾部滚动机制不受影响，仅随版本号同步发布。

## Android 端

- **悬浮字幕窗长句尾部滚动显示**：此前悬浮字幕窗的译文与原文文本框均使用固定行数配合末尾省略（`TruncateAt.END`），长句超出上限后新增文字会被隐藏在 `...` 之后。现在改用 `StaticLayout` 按实际宽度与贪婪换行测算可视行，始终截取并展示最新的尾部行（译文保留最新 3 行、原文 2 行，上一句译文 2 行、原文 1 行），屏幕旋转或尺寸变化时自动重排，使最新识别和翻译的文字立即可见。[悬浮字幕尾部滚动改动](https://github.com/IMMIEMIE/Recorder/pull/55)（修复 [#54](https://github.com/IMMIEMIE/Recorder/issues/54)）

## 安装

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| Android | `Recorder-0.8.4-android.apk` | Android 8.0 或更新（系统声音捕获需 Android 10 及以上），使用正式发行签名。 |
| macOS | `Recorder-0.8.4-arm64.dmg` | Apple Silicon，macOS 14 或更新。使用 ad-hoc 签名，尚未经 Apple 公证。 |

每份安装包均附有 SHA-256 校验文件。
