# 声笺 0.6.0

macOS 和 Android 现在都可以保存多套实时转译服务配置。同一服务可以使用多个模型，切换时直接选择已保存的配置。安卓手机和平板采用新界面，Mac 改进了长转写的阅读体验和 AI 回答的排版。

| 安装包 | 系统要求 |
| --- | --- |
| `Recorder-0.6.0-arm64.dmg` | Apple Silicon Mac，macOS 14 或更新。应用使用 ad-hoc 签名，尚未经 Apple 公证。 |
| `Recorder-0.6.0-android.apk` | Android 8.0（API 26）或更新。使用正式发行证书签名，可覆盖安装 0.5.0。 |

两个安装包均附有 SHA-256 校验文件。升级后，原有云端地址、密钥和转译偏好会迁移到默认配置。

## 自定义实时转译

- 在设置中填写配置名称、WebSocket 服务地址、模型 ID 和 API Key。首版支持 Qwen 3.8 LiveTranslate 兼容协议，上行音频为 16 kHz 单声道 PCM16。
- 同一地址的不同模型可复用该地址的密钥。不同地址的密钥分别保存在 macOS 钥匙串或 Android Keystore 中。
- “测试连接”使用当前草稿完成握手。测试期间不会采集音频，鉴权或协议不匹配时可以放弃草稿，继续使用原配置。[服务与模型配置](https://github.com/IMMIEMIE/Recorder/pull/33)

## 录制、阅读与导出

- 安卓手机从顶栏打开会话记录，平板宽屏常驻侧栏。录制按钮位于底部，向上阅读旧字幕后可点“回到最新”。设置和导出支持浅色、深色及大字号。[界面与截图](https://github.com/IMMIEMIE/Recorder/pull/31)
- macOS 转写更新时仍可用鼠标或键盘选择目标语言。上翻长转写时，新字幕会保留当前阅读位置。[语言菜单](https://github.com/IMMIEMIE/Recorder/pull/30) · [长列表滚动](https://github.com/IMMIEMIE/Recorder/pull/32)
- macOS 可在设置里选择简体中文、英文或跟随系统。安卓跟随系统语言，Android 13 及以上可使用系统的单应用语言设置。[界面语言](https://github.com/IMMIEMIE/Recorder/pull/27)
- Mac 的 AI 回答支持流式 Markdown，包括标题、列表、代码块和表格。服务提供公开推理摘要时可展开查看。[AI 回答](https://github.com/IMMIEMIE/Recorder/pull/29)
- macOS 本地翻译和逐句 API 翻译支持在录制期间更换目标语言。会话中已有的语言切换标记和说话人信息可随 TXT 或 Markdown 导出。云端双路对话和手机分屏仍在开发中。[双人对话进展](https://github.com/IMMIEMIE/Recorder/issues/22)

## 验证与已知范围

合入后的回归通过了 Android 的 47 项核心测试、9 张界面截图比对，以及 macOS 的 145 项会话检查。Android 35 模拟器验证了错误凭据回退、强停后恢复所选模型和双语导出。macOS 的 5,000 行转写测试中，追加内容后阅读位置偏移为 0。[集成构建](https://github.com/IMMIEMIE/Recorder/actions/runs/45176829040)

本版 macOS 的实验性本地 Hy-SimulMT 同传入口保持关闭。安卓正式签名包在实体手机上连续转译至少 5 分钟的验收仍待完成，包括同一 Wi-Fi 下的重连、延迟、尾句和译音。[发布验收 #13](https://github.com/IMMIEMIE/Recorder/issues/13) · [重连验收 #24](https://github.com/IMMIEMIE/Recorder/issues/24)
