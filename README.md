# 声笺 · Local Recorder

> Local-first, real-time speech transcription and translation for Apple Silicon Macs.
> 面向 Apple Silicon Mac 的本地优先实时语音转写与翻译工具。

![A microphone feeding a waveform into multilingual transcripts and subtitles](assets/readme/hero.png)

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-555555)](#requirements--环境要求)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## What it does / 项目简介

**声笺 (Shengjian)** turns microphone, audio-file, or system-audio input into near-real-time text on your Mac. Recognition can use local MLX models, an OpenAI-compatible audio transcription API, or Qwen Audio realtime WebSocket; the app can also show a floating subtitle window and translate completed sentences with either a local model or an API.

**声笺**可将麦克风、音频文件或系统声音近实时转写为文本。识别可使用本机 MLX 模型、兼容 OpenAI 音频转写接口的 API 或千问 Qwen Audio 实时 WebSocket；应用还支持悬浮字幕窗口，以及通过本地模型或 API 对定稿句子进行翻译。

Local transcription does not upload audio. LiveTranslate streams audio to the selected service. API transcription sends speech segments to the selected service. Model downloads, optional AI prompts, and optional API translation also require network access; see [Privacy / 隐私](#privacy--隐私) for the exact boundary.

本地转写不会上传音频。LiveTranslate 会持续发送音频到所选服务。API 识别会将语音片段发送到所选服务。模型下载、可选 AI 提问和可选 API 翻译也需要联网；准确的数据边界见[隐私](#privacy--隐私)。

## Highlights / 特性

- **Three audio sources** — microphone, audio file (WAV, AIFF, M4A, MP3, and other system-decodable formats), or system audio.
  **三种音源** — 麦克风、音频文件（WAV、AIFF、M4A、MP3 等系统可解码格式）和系统声音。
- **Local, near-real-time transcription** — Qwen3-ASR 1.7B by default; Whisper Large v3 Turbo is also available.
  **本地近实时识别** — 默认 Qwen3-ASR 1.7B，也可切换至 Whisper Large v3 Turbo。
- **API transcription** — OpenAI-compatible audio transcription or Qwen Audio realtime WebSocket, with configurable address, model ID, and API key.
  **API 识别** — 支持 OpenAI 兼容音频转写和千问 Qwen Audio 实时 WebSocket，可配置地址、模型 ID 与 API Key。
- **Smart endpointing** — reuses previews and conservatively detects sentence endings to reduce duplicate inference and awkward cutoffs.
  **智能定稿** — 复用预览结果并保守判断句末，减少重复推理与生硬断句。
- **Live translation** — local Qwen3/Hunyuan models or saved OpenAI-compatible API profiles, with nine target languages.
  **实时翻译** — 可用本地 Qwen3/Hunyuan 模型或已保存的 OpenAI 兼容 API 服务，并内置九种目标语言。
- **Subtitle and workflow tools** — always-on-top subtitles, text copy/export, menu-bar controls, and configurable shortcuts.
  **字幕与工作流工具** — 置顶字幕、复制与导出文本、菜单栏控制及可配置快捷键。

## Requirements / 环境要求

| Requirement / 要求 | Details / 说明 |
| --- | --- |
| Hardware / 硬件 | Apple Silicon Mac |
| Operating system / 系统 | macOS 14 Sonoma 或更高版本 |
| Build tools / 构建工具 | Xcode Command Line Tools |
| Disk & network / 磁盘与网络 | Model weights are downloaded separately; the default ASR model is about 4.08 GB / 模型权重需另行下载；默认识别模型约 4.08 GB |

> The app is currently locally signed and not notarized, so macOS may require manual approval on first launch.
> 当前应用为本地签名、未公证版本；首次启动时 macOS 可能要求手动允许。

## Quick start / 快速开始

### Build from source / 从源码构建

```bash
git clone https://github.com/IMMIEMIE/Recorder.git
cd Recorder
./scripts/setup.sh
./scripts/build.sh
open "dist/声笺.app"
```

`setup.sh` creates a project-local Python 3.12.14 environment and installs locked dependencies. `build.sh` produces `dist/声笺.app`. To make a DMG as well:

`setup.sh` 会创建项目内的 Python 3.12.14 环境并安装锁定依赖；`build.sh` 生成 `dist/声笺.app`。如需 DMG，可继续运行：

```bash
./scripts/package.sh
```

### First transcription / 第一次转写

1. In **Settings → Transcription**, choose a local ASR model and select **Download model**, or choose **API service** and enter its base URL, audio transcription model ID, and API key before selecting **Connect / Switch**.
   在**设置 → 转写**选择本地识别模型并点击**下载模型**，或选择 **API 服务**，填写 Base URL、音频转写模型 ID 和 API Key 后点击**连接 / 切换**。
2. Choose microphone, audio file, or system audio in the main window.
   在主窗口选择麦克风、音频文件或系统声音。
3. Click **Start transcription** and grant the requested macOS permission.
   点击**开始转写**，按提示授予 macOS 权限。
4. Stop to process the final phrase; then copy or export the transcript.
   停止后会处理尾句；随后可复制或导出文本。

The default shortcut is `Control + Option + Space`. Open subtitle mode from the toolbar or menu bar.
默认快捷键为 `Control + Option + Space`；可从工具栏或菜单栏打开字幕模式。

## Models and translation / 模型与翻译

### Speech recognition / 语音识别

| Preset / 预设 | Model ID | Approx. download / 约下载大小 |
| --- | --- | --- |
| Qwen3-ASR 1.7B (default / 默认) | `mlx-community/Qwen3-ASR-1.7B-bf16` | 4.08 GB |
| Whisper Large v3 Turbo | `mlx-community/whisper-large-v3-turbo` | 1.61 GB |

Custom MLX-compatible Qwen3-ASR or Whisper IDs and local model directories are supported. Arbitrary Hugging Face and raw PyTorch/Transformers checkpoints are not directly supported.
支持兼容 MLX 的自定义 Qwen3-ASR / Whisper ID 与本地模型目录；不直接支持任意 Hugging Face 模型或原始 PyTorch/Transformers 权重。

For API recognition, enter the base URL such as `https://api.example.com/v1` and a model that supports `POST /audio/transcriptions`. The app sends WAV speech segments, including provisional previews, to that service; preview requests can increase usage and fees. API recognition requires a connection and does not download model weights.
API 识别请填写 Base URL（如 `https://api.example.com/v1`）和支持 `POST /audio/transcriptions` 的模型。应用会将 WAV 语音片段（包括预览片段）发送给该服务；预览请求可能增加用量和费用。API 识别无需下载模型，但需要联网。

#### Qwen Audio 3.1 Realtime / 千问实时语音

在**设置 → 转写**选择 **API 服务 → 千问实时语音（Qwen Audio）**，地址和模型会自动填好：

| 配置 | 值 |
| --- | --- |
| 服务平台 | 选择签发 API Key 的平台，默认千问AI平台（qianwenai.com） |
| WebSocket 地址 | `wss://maas.qianwenaiapi.com/api-ws/v1/realtime` |
| 模型 ID | `qwen-audio-3.1-realtime-plus` |
| API Key | 填写千问平台中可访问该模型的密钥 |

点击**保存 / 启用**，可先用**测试连接**确认权限和会话配置，再回到主窗口开始转写。若已开启 LiveTranslate 独立模式，先在 LiveTranslate 页将它关闭。测试连接只建立会话，不采集或发送音频。

API Key 只能用于签发它的平台和区域：千问AI平台的密钥对应 `maas.qianwenaiapi.com`，阿里云百炼对应 `dashscope.aliyuncs.com`（新加坡为 `dashscope-intl.aliyuncs.com`），QwenCloud 对应 `maas.qwencloudapi.com`，工作空间专属密钥需填写对应的工作空间地址。地址栏也可以直接粘贴平台的 https Base URL（如 `https://maas.qianwenaiapi.com/compatible-mode/v1` 或 `…/api/v1`），应用会换成同一主机的 `wss://…/api-ws/v1/realtime`。

测试连接或转写失败时，提示会带上 HTTP 状态码或服务器返回的错误码与说明（密钥已隐藏），例如 HTTP 401/403 通常表示密钥无效或与地址不属于同一平台。选择具体语言时，应用把语言提示加到服务器默认的输入转写配置中。若服务拒绝会话配置（例如不支持语言参数），应用会只保留手动提交所需的 `turn_detection: null` 重试一次，之后该地址与模型改为自动识别语言。

应用在本机检测停顿后提交一次语音片段，显示输入音频的 ASR 转写增量和最终文本；采用手动提交，不发送 `response.create`，不生成对话回答或语音。默认停顿 1 秒，可在转写设置调整。长语音会按现有识别窗口分块处理，窗口不会强制定稿。千问密钥只在原生客户端使用，不发送给 Python 后端或写入配置文件。

协议依据：[模型页面](https://www.qianwenai.com/models/qwen-audio-3.1-realtime-plus)、[客户端事件](https://platform.qianwenai.com/docs/api-reference/qwen-audio-realtime/client-events)、[服务端事件](https://platform.qianwenai.com/docs/api-reference/qwen-audio-realtime/server-events)。

### Sentence translation / 逐句翻译

Translation runs only after a segment is finalized, never on transient preview text. Choose **Local model** or **API service** in **Settings → Translation**.
翻译只处理定稿文本，不会发送识别中的预览文字。在**设置 → 翻译**中选择**本地模型**或 **API 服务**。

| Local preset / 本地预设 | Model ID | Approx. download / 约下载大小 |
| --- | --- | --- |
| Qwen3 4B Instruct (default / 默认) | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 2.26 GB |
| Hunyuan-MT 7B | `mlx-community/Hunyuan-MT-7B-4bit` | 4.22 GB |

Targets are Simplified Chinese, Traditional Chinese, English, Japanese, Korean, French, German, Spanish, and Russian. API translation sends only finalized text to the saved service; fees are determined by that provider.

目标语言包括简体中文、繁體中文、英语、日语、韩语、法语、德语、西班牙语和俄语。API 翻译仅将定稿文本发送给已保存服务；费用由服务商决定。

### LiveTranslate 独立实时翻译

在**设置 → LiveTranslate**填写专用 API Key，选择目标语言，点击**保存**和**测试连接**，然后开启**使用 LiveTranslate 独立转写与翻译**。返回主窗口选择音源并开始转写，无需下载识别或翻译模型。

- 固定模型：`qwen3.8-livetranslate-flash-realtime`；默认地址为 `wss://maas.qianwenaiapi.com/api-ws/v1/realtime`。也可填写账户对应的工作空间 WSS 地址，例如 `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime`；密钥须与地址所属区域和工作空间匹配。
- 麦克风、系统声音和音频文件均支持；原文和译文边生成边显示，可使用悬浮字幕、复制和 TXT 导出。仅输出文字，不播放译音。
- 目标语言：中文、英语、日语、韩语、法语、德语、西班牙语、俄语。默认中文使用 `zh`，不进行简繁转换。
- 启用后关闭本地推理进程，停用其他识别、翻译及 AI 提问入口；下次启动直接进入 LiveTranslate 模式。关闭该模式可恢复原有服务配置。
- 停止采集后等待尾句处理，最长 30 秒；录音及处理尾句期间不能修改连接或目标语言。连接出错时保留收到的文字，未完成句子会标注，不自动切换其他模型。
- 服务地址、语言和开关保存在应用偏好设置；专用 API Key 按地址分别存入钥匙串，留空保存会保留已有密钥。音频持续上传至所选服务并可能产生费用；**测试连接只配置会话，不发送音频**。

协议依据：[模型页面](https://www.qianwenai.com/models/qwen3.8-livetranslate-flash-realtime)、[客户端事件](https://help.aliyun.com/en/model-studio/live-translator-client-events)、[服务端事件](https://help.aliyun.com/en/model-studio/live-translator-server-events)。模拟测试验证客户端行为；实际模型权限、翻译效果与延迟仍需使用有效 API Key 验证。

## Privacy / 隐私

| Activity / 操作 | Data location / 数据位置 |
| --- | --- |
| Local transcription & translation / 本地转写与翻译 | Runs locally; audio is not uploaded / 在本机运行，不上传音频 |
| API transcription / API 识别 | Sends speech segments; OpenAI mode also sends provisional previews / 将语音片段发送给所选服务；OpenAI 模式也发送临时预览 |
| Model download / 模型下载 | Downloads selected model weights / 下载所选模型权重 |
| API live translation / API 实时翻译 | Sends finalized text only—not audio or preview text / 仅发送定稿文本，不发送音频或预览文字 |
| LiveTranslate | Sends the selected audio stream for cloud transcription and translation; does not save recordings / 将所选音频流发送至云端转写翻译，不保存录音 |
| AI prompt / AI 提问 | Sends the text in the prompt panel and the requested task / 发送提问面板中的文字及任务 |
| Credentials / 凭据 | API keys are stored in macOS Keychain; LiveTranslate configuration lives in app preferences; other profile metadata lives in `~/Library/Application Support/LocalRecorder/` / 密钥保存在 macOS 钥匙串；LiveTranslate 配置保存在应用偏好设置，其他配置元数据位于上述目录 |

The app does not retain raw recordings or transcript history. System-audio capture uses macOS screen-and-system-audio permission but does not save screen images.
应用不保存原始录音或文字历史。系统声音采集需要 macOS 的屏幕与系统音频录制权限，但不会保存屏幕画面。

## Development / 开发与测试

After `./scripts/setup.sh`, run:

```bash
./scripts/test_ai.sh
./scripts/test_audio.sh
./scripts/test_livetranslate.sh
.venv/bin/python -m unittest discover -s tests -v
```

Model-dependent verification requires cached weights and Metal access:

```bash
.venv/bin/python scripts/verify_endpoints.py
.venv/bin/python scripts/verify_translation.py
```

Synthetic samples and local test servers are regression checks, not guarantees of recognition quality in every real-world environment. Read [docs/SMART-ENDPOINTS.md](docs/SMART-ENDPOINTS.md) and [docs/VALIDATION.md](docs/VALIDATION.md) for measurements and limitations.

合成样本和本地测试服务适合回归检查，但不代表所有真实环境下的识别质量。测试结果与限制请参阅 [docs/SMART-ENDPOINTS.md](docs/SMART-ENDPOINTS.md) 和 [docs/VALIDATION.md](docs/VALIDATION.md)。

## Contributing / 参与贡献

Issues and pull requests are welcome. Keep changes focused, include tests when practical, and do not commit model weights, virtual environments, or API credentials.
欢迎提交 Issue 和 Pull Request。请保持改动聚焦；尽可能附带测试；不要提交模型权重、虚拟环境或 API 凭据。

## License / 许可证

Licensed under the [Apache License 2.0](LICENSE).
本项目采用 [Apache License 2.0](LICENSE) 开源。
