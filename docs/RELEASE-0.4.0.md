# 声笺 0.4.0

推理后端改为 Swift 单进程实现：识别、翻译与模型下载都在应用进程内完成（mlx-swift），不再附带 Python 运行环境与推理依赖。

- 界面、快捷键、字幕、导出、API 识别、WebSocket 流式识别、LiveTranslate 与 AI 提问的行为不变；错误与状态文案沿用旧版。
- 设置与模型继续使用 ~/Library/Application Support/LocalRecorder/：旧版下载的 Qwen3-ASR、Whisper 与翻译模型直接可用，无需重新下载；新版下载的模型也与旧版缓存格式相同。
- 模型下载支持断点续传：取消或断网后再次下载会从中断处继续；每个文件下载后都会校验内容。
- 本地识别与翻译仍然离线运行，只有下载模型、API 服务、LiveTranslate 与 AI 提问需要联网。

构建：需要完整 Xcode（含 Metal Toolchain 组件）；`./scripts/build.sh` 会从 mlx-swift 源码编译 Metal 内核，不再需要 `setup.sh` 与 Python 环境。

验证：Qwen3-ASR、Whisper 与本地翻译的逐字对拍、下载器与真实缓存核对已在 macOS 上通过（见 docs/VALIDATION.md）；打包体积、全新安装与旧版升级回归待补记录。
