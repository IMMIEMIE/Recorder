# 声笺 0.8.1

本版修复 Android 端切换界面语言时页面偶发闪烁的问题。macOS 端无功能改动，同步更新版本号以保持双端发布一致。

## 修复

- **Android 界面语言切换不再闪烁**：为 `MainActivity` 原地处理 `locale|layoutDirection` 配置变更（Android 13+ 通过 `onConfigurationChanged` 原地重组，Android 8–12 通过 Compose 本地化上下文原地刷新），不再在切换界面语言时销毁重建页面；语言选择弹窗在完全收起后再应用切换，并移除组合阶段的主线程同步写盘。[界面语言切换修复](https://github.com/IMMIEMIE/Recorder/pull/43)（修复 [#42](https://github.com/IMMIEMIE/Recorder/issues/42)）

## 安装

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| Android | `Recorder-0.8.1-android.apk` | Android 8.0 或更新，使用正式发行签名。 |
| macOS | `Recorder-0.8.1-arm64.dmg` | Apple Silicon，macOS 14 或更新。使用 ad-hoc 签名，尚未经 Apple 公证。 |

每份安装包均附有 SHA-256 校验文件。
