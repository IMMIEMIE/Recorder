# 声笺 0.8.3

本版是 macOS 端的小幅修复版本：不再在每次启动时弹出钥匙串密码框，并修正默认窗口过窄导致顶部工具栏按钮换行的问题。Android 端无功能变化，仅随版本号同步发布。

## macOS 端

- **API Key 不再触发钥匙串密码弹窗**：由于发行版使用 ad-hoc 签名，旧版每次启动读取已保存的 API Key 时都会弹出「登录」钥匙串密码框，拒绝后显示「无法读取钥匙串（-128）」。现在 API Key 改存于本机 `~/Library/Application Support/LocalRecorder/APIKeys/keys.json`（目录权限 0700、文件 0600，原子写入），并在本次运行期间缓存在内存中。旧版保存在钥匙串中的 Key 会在首次使用时迁移一次，迁移成功后删除钥匙串条目；若在迁移弹窗中选择「拒绝」，不再报错也不再询问，重新填写 Key 即可。Key 不会写入 `config.json`、日志或上传。[API Key 存储改动](https://github.com/IMMIEMIE/Recorder/pull/52)（修复 [#50](https://github.com/IMMIEMIE/Recorder/issues/50)）
- **主窗口与转写工具栏布局**：默认窗口加宽至 1440×820（最小 1100×600）；工具栏按钮统一单行、等高；窗口变窄时「AI 提问」「导出会话…」「复制」先收为图标，再收入「更多操作」菜单，字幕、置顶、翻译菜单与「停止译音」始终可见，会话标题过长时从中间省略。[工具栏布局改动](https://github.com/IMMIEMIE/Recorder/pull/53)（修复 [#51](https://github.com/IMMIEMIE/Recorder/issues/51)）

## 安装

| 平台 | 安装包 | 系统要求 |
| --- | --- | --- |
| Android | `Recorder-0.8.3-android.apk` | Android 8.0 或更新（系统声音捕获需 Android 10 及以上），使用正式发行签名。 |
| macOS | `Recorder-0.8.3-arm64.dmg` | Apple Silicon，macOS 14 或更新。使用 ad-hoc 签名，尚未经 Apple 公证。 |

每份安装包均附有 SHA-256 校验文件。
