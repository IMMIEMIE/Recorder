# 声笺 Windows x86 0.5.0

Windows 原生桌面移植，代码保存在 `windows/`，原有 Swift/macOS 源码保持独立。
这是首个 Windows 测试版，不代表与 macOS 的模型、准确率或功能完全一致。

## 安装与开始

支持 Windows 10 1809 及以上。应用、Whisper DLL 和安装器均为 **PE32 / I386**；可运行于 32 位 Windows 及支持 x86 的 64 位 Windows。包含 .NET 8.0.32，无需另外安装 .NET、Python、Visual C++ 或 GPU 驱动。

运行 `dist/Shengjian-0.5.0-windows-x86-setup.exe`，安装到当前用户，无需管理员权限。也可完整解压 portable ZIP，运行其中的 `Shengjian.exe`，请保留旁边的 `recorder-whisper.dll`。

1. 打开设置 → 本地模型 → 下载 Whisper Tiny，完成后保存。模型约 74 MiB，下载地址为 ggerganov/whisper.cpp；SHA256 固定校验。亦可选择 GGML 格式的 Tiny / Base / Small，32 位环境推荐 Tiny / Base。下载需要联网，本地识别不联网。
2. 选择麦克风、系统声音或音频文件，开始转写。音频文件按原速处理；停止会处理已收到的尾句，再次点击可取消等待。
3. 打开置顶字幕、复制，或导出双语 TXT/SRT。Ctrl+Alt+空格控制开始/停止（快捷键未被其他应用占用时生效）。托盘菜单可重新显示主窗口。

支持 WAV、PCM AIFF/AIFC（含 macOS `twos` / `sowt`）、MP3、M4A 及 Windows Media Foundation 可解码的其他格式。压缩 AIFC 等不支持的编码请先转换成 WAV。

## 功能与差异

| 功能 | Windows x86 |
| --- | --- |
| 麦克风 | 可选择输入设备，16 kHz 单声道 PCM |
| 系统声音 | WASAPI 当前默认输出设备的所有声音；不排除声笺或其他应用自身播放 |
| 本地转写 | whisper.cpp 1.7.6，CPU；不支持 Apple MLX / Qwen 权重 |
| 分句 | 能量阈值及可调停顿，保留预录；最多 25 秒连续音频一段；不同于 macOS WebRTC VAD / 智能定稿 |
| 本地识别预览 | 分句完成后显示结果，尚无流式临时识别；需边说边出字可用千问流式模式 |
| HTTP 转写 | OpenAI 兼容 `/audio/transcriptions`；只发送分句，无预览请求 |
| 千问流式 | 原仓库固定端点与模型，二进制 PCM，停止后等待 `task-finished` |
| LiveTranslate | 原仓库协议；原文和译文按 ID 配对；仅文字，不播放译音 |
| 逐句翻译 | OpenAI 兼容 `/chat/completions`；独立队列，失败保留原文 |
| 导出与字幕 | TXT/SRT、复制、可移动和调整大小的置顶字幕、托盘、全局快捷键 |
| 未移植 | MLX 本地翻译、AI 提问/多服务配置管理、译音播放/重播 |

Tiny 中文效果有限，实际转写中可能出现同音错字。长时间纯讲话可能在 25 秒边界截断词句。CPU 速度不足时会提示积压并停止，保留已完成文字。翻译最多排队 4 句，超限的句子只保留原文。没有真实 API Key 时，云端服务仅能通过本地模拟协议测试，模型权限、额度、实际延迟仍需用户验证。

## 数据

- 设置及单独下载的模型：`%LOCALAPPDATA%\Shengjian`。卸载保留此目录。
- API Key 使用 Windows DPAPI `CurrentUser` 加密；不能直接拷贝到其他 Windows 用户。留空保存保留密钥；更改服务地址需要重新填对应密钥。
- 录音、原文、译文不会自动保存；退出后清空。用户主动导出的文本写入所选位置。
- 本地识别不上传数据；HTTP/千问/LiveTranslate 上传所选音频；API 翻译上传定稿文字。远程 HTTP 明文与重定向被拒绝；本机推理可用 `http://127.0.0.1` 且无需密钥。

## 从源码构建

需要 .NET SDK 8/9、Visual Studio 2022 C++ x86/x64 工具及 Windows SDK、CMake、Git。安装器编译需要 Inno Setup 6.5.4（语言文件已纳入仓库）。

```powershell
.\scripts\build_windows.ps1
# 编译器不在默认路径：
.\scripts\build_windows.ps1 -InnoCompiler 'C:\path\ISCC.exe'
# 只要免安装包：
.\scripts\build_windows.ps1 -SkipInstaller
```

脚本获取固定提交的 whisper.cpp，禁用 AVX / AVX2 / FMA / F16C / SSE4.2 依赖，静态链接 C++ 运行库，构建 Win32 DLL；锁定 NuGet 包并运行测试，然后 self-contained 发布，校验三个 PE 文件的机器类型，生成安装包/ZIP 及 SHA256。

输出在 `dist/`。模型不进入安装包；产物与构建缓存不纳入 Git。Apache 许可证、Whisper/NAudio/.NET 第三方声明随包提供。

```powershell
# 模型无关测试：
dotnet build windows/Recorder.Tests -c Release
.\windows\Recorder.Tests\bin\Release\net8.0-windows\win-x86\Recorder.Tests.exe
# 真实 CPU 推理；模型不存在时单独下载并校验：
.\windows\Recorder.Tests\bin\Release\net8.0-windows\win-x86\Recorder.Tests.exe --model "$PWD\.bootstrap\models\ggml-tiny.bin"
```

测试覆盖真实 32 位进程、DPAPI、重采样边界、分句及尾句、静音过滤、REST multipart、翻译、拒绝重定向/明文、两种 WebSocket 握手和尾句、译文乱序合并、导出及中英文 AIFF 实际离线推理。硬件录音权限及真实云服务账号需在目标机器测试。
