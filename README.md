# 声笺 · Local Recorder 0.3.1

Apple Silicon macOS 本地语音转写。SwiftUI 界面、AVAudioEngine 采集、独立 Python / MLX 推理进程。

## 安装

打开 `dist/声笺-0.3.1-arm64.dmg`，先退出旧版，再将「声笺.app」拖到 Applications。应用内置 Python 和推理依赖，无需另装环境；**不包含模型权重**。当前是本机临时签名试用版，尚未公证。

旧版模型缓存和配置继续复用，不需要重新下载已有模型。

## 使用

1. 打开「设置」，选择识别模型。
2. 首次使用点击「下载模型」；下载完成后自动加载。已有缓存时点击「加载 / 切换」。
3. 回到主窗口点击「开始转写」，按系统提示允许麦克风。
4. 临时文字会更新，最终文字逐段追加。停止后会处理尾句，再恢复就绪。
5. 点击「另存为…」将已定稿文本保存为 UTF-8 TXT，也可复制到剪贴板。退出应用会丢弃当前会话文字。
6. 点击「AI 提问」，在主窗口「设置 → AI 服务」填写 Base URL、模型 ID 和 API Key，点击「保存并使用」。支持 DeepSeek、OpenAI 及兼容接口。选择摘要、翻译或自定义提问，再点击发送。翻译默认简体中文，可自由修改目标语言。原文发送前可编辑，结果流式显示，可停止、复制或另存为。
7. 实时翻译：打开「设置 → 翻译」，首次使用点击「下载翻译模型」，下载完成后自动加载并开启；也可在主窗口工具栏的「翻译」菜单开关或切换目标语言（默认简体中文）。每句话定稿后在本机逐句翻译，译文流式显示在原文下方；原文已是目标语言时不显示译文。开启状态会保存，之后点击「加载模型」会一并加载翻译模型。「另存为…」和复制会附带译文，「AI 提问」仍只使用原文。

默认快捷键为 **Control + Option + Space**；设置里可改为 R / D，并启用「按住说话」。菜单栏支持录音控制和重新打开窗口。图钉可将窗口置顶。

## 模型切换

| 预设 | 模型 ID | 下载大小（约） |
| --- | --- | --- |
| Qwen3-ASR 1.7B（默认） | `mlx-community/Qwen3-ASR-1.7B-bf16` | 4.08 GB |
| Whisper Large v3 Turbo | `mlx-community/whisper-large-v3-turbo` | 1.61 GB |

在设置中选择另一项，点击「加载 / 切换」即可。录音时不能切换。下载可以取消和重试，成功的缓存会保留。切换失败不会覆盖已保存配置；重新连接可恢复上次成功配置。

「自定义模型…」支持兼容的 MLX Qwen3-ASR 或 MLX Whisper ID、本地模型目录。本地目录优先，需包含对应架构的配置和权重；不支持任意 Hugging Face 模型或直接使用 PyTorch/Transformers 格式权重。上面两个预设已经实测，其余模型需要单独验证。

版本、预览频率和分段参数位于「高级」。语言和高级参数点击加载后生效。模型配置仅在加载及预热成功后原子保存。

## 实时翻译

| 预设 | 模型 ID | 下载大小（约） |
| --- | --- | --- |
| Qwen3 4B Instruct（默认） | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 2.26 GB |
| Hunyuan-MT 7B（翻译专用） | `mlx-community/Hunyuan-MT-7B-4bit` | 4.22 GB |

目标语言：简体中文、繁體中文、English、日本語、한국어、Français、Deutsch、Español、Русский。更换目标语言无需重新加载，对之后的句子生效。关闭翻译会卸载翻译模型并释放内存。

只翻译定稿文字，不翻译识别中的临时文字。静音定稿的一段为一个翻译单元；强制分段时，被切断的最后一句并入下一段再翻译，避免半句话单独翻译。翻译与识别共用一个推理线程：识别定稿始终优先，翻译在逐个 token 之间让出；积压超过 4 句时跳过最早的译文并提示，不影响原文和录音。中文、日文、韩文、俄文原文已是目标语言时直接跳过，不占用 GPU；拉丁字母语言在生成后比对，结果与原文相同则不显示。

Qwen3 4B 预设已用合成样本实测，见 `docs/translation-verification.json`。Hunyuan-MT 7B 和「自定义模型…」（MLX 格式的 Qwen、Hunyuan、Llama、Mistral 文本模型）未经实测。Hunyuan-MT 使用腾讯混元社区许可协议，使用前请确认条款。4B 模型译文质量有限，专有名词和部分语种可能译得不准确。

## 离线和隐私

「下载模型」「下载翻译模型」及主动发送 AI 提问会联网。实时翻译在本机运行，不上传文字；翻译设置保存在 `LocalRecorder/translation.json`。AI 提问仅发送面板中的原文和任务，可能产生服务商费用；每个 Base URL 对应一份独立 JSON 配置，位于 LocalRecorder/AIProfiles；密钥按 Base URL 保存在系统钥匙串，当前配置选择保存在 UserDefaults。普通加载和转写强制使用 Hugging Face / Transformers 离线模式，不上传音频，没有云端回退。不保存原始录音或文字历史，复制操作会替换剪贴板。

配置和模型缓存位于 `~/Library/Application Support/LocalRecorder/`。快捷键存储在 macOS UserDefaults。模型与 App 分开，不影响更新安装。使用外部模型目录时，通过「选择…」选取目录，按系统要求授予该目录访问。

后台只监听 0600 权限的 Unix socket。音频实际重采样为 16 kHz 单声道 PCM16；20 ms WebRTC VAD，无辅助 VAD 下载。默认 240 ms 前置缓冲、760 ms 静音定稿、1200 ms 预览间隔和 18 秒强制分段。

这是连续采集、分段重复识别的近实时方案，不是原生跨块增量解码。单个推理任务执行，最终段优先，只保留一个待执行预览。最终队列过载时会停止采集并完成已接收音频；传输过载的未发送块可能丢失，会明确提示。停止时排空重采样器并处理尾句。

## 构建和打包

需要 Apple Silicon macOS 和 Xcode Command Line Tools：

```bash
./scripts/setup.sh
./scripts/build.sh
./scripts/package.sh
```

固定 Python 3.12.14，依赖全量锁定在 `requirements.lock`，启动时不安装或升级。脚本只操作项目构建；同名 DMG 已存在时会停止，避免覆盖旧安装包。打包验证签名与磁盘映像，并输出 SHA-256。

图标：`assets/AppIcon.png` 和 `assets/AppIcon.icns`。更换原图后运行 `python3 scripts/make_icon.py` 再构建。

## 测试与限制

```bash
./scripts/test_ai.sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/verify_model.py --model /absolute/model/snapshot --audio tests/fixtures/chinese.aiff
.venv/bin/python scripts/verify_switching.py --qwen /absolute/qwen/snapshot --whisper /absolute/whisper/snapshot
.venv/bin/python scripts/verify_translation.py   # 需要 models/ 中已缓存默认识别模型和翻译模型
```

真实推理需要可访问 Metal GPU 的本机环境。验证脚本只使用明确指定的测试文件，不录制麦克风。

参见 `docs/RELEASE-0.3.1.md`；0.1.0 历史验证保存在 `docs/VALIDATION.md`。当前未完成 30 分钟连续真人录音、干净机器安装、全部外设拔插/睡眠唤醒/快捷键冲突等验收。合成样本不能代表真人或噪声下识别质量。

强制分段使用相邻不重叠音频，避免文本去重误删真实重复词，跨切点词语仍可能受影响。未实现系统输入、文字历史、说话人分离或精确字级时间戳。
