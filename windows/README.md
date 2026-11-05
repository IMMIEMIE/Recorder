# 声笺 Windows

## x64 0.6.12 预览版

0.6.12 增加“设置 → 外观”：跟随系统（默认）、浅色、深色。点击“应用外观”立即保存并更新窗口，不加载模型；常规和 LiveTranslate 均可使用。跟随 Windows 的应用颜色设置并响应运行中的变化；主窗口、正文、设置、AI 提问、服务管理及应用菜单使用统一配色。切换时保留正文选择和阅读位置，悬浮字幕保持独立的字幕样式。仅编译打包，未运行测试或界面验证。

0.6.11 统一正文时间戳与原文的字体和字号，修正悬挂缩进方向；时间戳位于独立左列，原文换行、显式分段及译文都从正文列开始。列宽按字号、DPI 和分钟位数计算，避免长时间戳挤占正文。仅编译打包，未运行测试或界面验证。

0.6.10 本地转录新增可配置智能定句：设置 → 常规模式 → 识别 → 本地识别 → 停顿策略“智能定句”。完整句停顿默认 600 ms（300–1200），兜底停顿默认 1500 ms（800–3000），兜底至少比完整句长 200 ms。停顿 300 ms 后，若已有预览未覆盖最新语音尾部，补做一次句尾识别；完整句标点加短停顿触发定稿，长停顿独立兜底。恢复说话使旧候选失效，连续讲话不单凭标点切音频。固定模式保留原参数，旧配置自动使用新字段默认值；下一次会话生效。停顿时间从最后语音帧计算，最终文字还需等待模型；模型输入分块长度不作为断句阈值。此次仅调整本地智能模式，云端断句保持原逻辑。按要求仅编译打包，未运行测试、模型或界面验证。

0.6.9 本地翻译新增实时译文预览：常规模式下开启翻译并选择“本地模型”，原文尚未定稿时即可在预览区域和悬浮字幕中看到持续生成的译文。支持本地转录以及千问流式识别配合本地翻译。识别预览和翻译可并行处理；未处理的预览仅保留最新一份，同一句正在生成的译文允许完成，避免较慢设备不断重启而无法输出。定稿翻译优先，预览不写入历史或导出，也不作为后续翻译上下文。实际更新速度取决于模型和设备；API 翻译仍按定稿触发。按用户要求仅编译打包，未运行测试、界面验证或性能基准。

0.6.8 修正“重播译音”和翻译下拉菜单在 Closed 回调中立即释放导致的 ContextMenuStrip 已释放异常。菜单改由主窗口组件容器持有，打开时重新生成项目，窗口释放时统一清理；同时覆盖共享 x86 翻译菜单代码。仅编译打包 x64，未运行测试或界面验证。

0.6.7 将正文滚动改为明确的自由浏览 / 跟随最新两种状态：向上滚动、拖动滚动条向上或使用向上导航键解除跟随；自由浏览期间新文本和译文保留阅读位置。点击“回到最新”或 Ctrl + ↓ 后锁定最新位置，后续文本与窗口布局变化继续跟随。自行向下滚到底部不会重新开启跟随。通过滚动显示区域实现，不再移动光标后恢复旧选区来跳转。仅编译打包，未运行测试或界面验证。

0.6.6 移除左侧顶部 Logo 和静态“实时转写”栏，侧栏直接从工作模式开始，减少纵向占用。仅编译打包，未运行测试或界面验证。

0.6.5 针对断句时的系统提示音，调整正文控件的只读更新流程，并关闭控件自身的编辑蜂鸣；不修改系统声音设置或 LiveTranslate 译音。仅编译打包，实际效果待用户使用确认。

0.6.4 在主界面侧栏和设置顶部增加“常规转录 + 翻译 / LiveTranslate”模式切换。常规模式显示识别、在线服务和翻译设置；LiveTranslate 单独显示专用 Key、目标语言、译音和播放选项。两种模式独立记住目标语言，返回常规模式保留上次识别方式。录音期间不可切换模式。LiveTranslate 保存不加载常规识别或翻译模型，只在开始会话时连接服务。

0.6.3 统一 Windows 与 Mac 图标来源：`assets/AppIcon.png`。构建脚本自动生成 16/20/24/32/40/48/64/128/256 像素、32 位透明图标，应用、安装器和快捷方式共用，修正旧 ICO 丢失主体颜色、只剩轮廓线的问题。本次只编译打包，未运行测试或界面验证。

基于 GitHub 主分支 `20fe08d`，同步 Mac `62987f9` 的界面新增：

- 视频式字幕：原文 / 译文各显示最新 1–3 行，默认 2 行；每行独立半透明底色，或仅文字带阴影。窗口随文字大小调整，底部中心保持锚定。
- 字幕获得焦点后，方向键移动 10 逻辑像素，Shift 加速到 40，Alt 微调到 1；支持拖动、位置记忆和显示器断开后的回退。右键调整字号、行数、底色、透明度、译文及位置。
- 翻看历史时保留滚动位置和选区；“回到底部 / 有新内容”按钮或 Ctrl + ↓ 恢复自动跟随。
- 正文只替换变化的行，复用字体；字幕换行结果缓存，内容未变时不重复绘制。字幕偏好独立保存在数据目录的 `subtitle-style.json`，切换识别 / 翻译设置不会覆盖字幕样式。

本轮按用户要求只编译和打包，未运行自动测试、界面验证或性能基准。翻译目标语言切换闪退保留待排查，不宣称已修复。旧版验证记录不代表 0.6.2 已验收。

Windows 11 x64，.NET 10 自包含；支持 Qwen3-ASR-1.7B、Whisper、本地 Qwen3/Hunyuan 翻译、AI 提问及 LiveTranslate 译音。安装包含 CPU 推理组件和 CUDA 推理内核。NVIDIA CUDA 运行库和 cuBLAS（约 540 MiB 下载）不随包提供，首次使用 CUDA 时在 设置 → 识别 → 运行设备 中下载，并经过 SHA256 校验。模型同样首次使用时单独下载。运行无需 Python、开发工具或 CUDA Toolkit。

标准安装包：`dist/Shengjian-0.6.12-windows-x64-preview-setup.exe`；便携包：`dist/Shengjian-0.6.12-windows-x64-preview-portable.zip`，完整解压后运行 `Shengjian.exe`。需要离线安装时，用 `-BundleCudaRuntime` 构建 `*-preview-offline-*` 完整包。x64 与 x86 的安装目录和配置目录分离，可以并存。

仅用 CPU 或云端服务可选 `dist/Shengjian-0.6.12-windows-x64-preview-cpu-portable.zip`，省去 CUDA 推理内核，仍自带 .NET。此包不提供 NVIDIA 加速；“自动”直接使用 CPU。`build_windows_full.ps1 -CpuOnly` 可构建此版本。ZIP 使用更高压缩级别，默认包解压体积预算收紧至 300 MiB。共享 ggml 后端的大幅瘦身仍属后续工作，本轮没有更换原生推理依赖。

CUDA 内核包含 RTX 20/30/40/50 系列（sm_75/86/89/120）的 SASS；RTX 50 已在 RTX 5060 Ti 实测，其余代际待验收。“自动”设备在没有 GPU 组件或驱动时直接使用 CPU。CPU 需要 AVX2/FMA/F16C/BMI2。Windows 模型使用 GGUF/GGML，不能直接加载 MLX 权重。

0.6.1 曾加入语言切换路径的保护及本地诊断日志 `%LOCALAPPDATA%\Shengjian-x64\logs`；用户仍反馈翻译目标语言切换闪退，需后续继续排查。日志只记录异常和退出码，不记录音频或文字。计划与根因见 [FIX-MIGRATION-PLAN.md](FIX-MIGRATION-PLAN.md)。

验证范围和待办见 [WINDOWS-VALIDATION.md](WINDOWS-VALIDATION.md)，安装、迁移和回退见 [INSTALL-NOTES-x64.txt](INSTALL-NOTES-x64.txt)。Mac、真实云账号、无开发环境机器验收保留待办。构建入口：`scripts/build_windows_full.ps1`。无模型的跨平台检查：`scripts/test_windows_portable.ps1`，Linux/macOS 上为 `scripts/test_windows_portable.sh`。

以下为 x86 兼容版说明。
# 声笺 Windows x86 0.5.0

Windows 原生桌面移植，代码保存在 `windows/`，原有 Swift/macOS 源码保持独立。
这是首个 Windows 测试版，不代表与 macOS 的模型、准确率或功能完全一致。

## 安装与开始

支持 Windows 10 1809 及以上。应用、Whisper DLL 和安装器均为 **PE32 / I386**；可运行于 32 位 Windows 及支持 x86 的 64 位 Windows。包含 .NET 8.0.32，无需另外安装 .NET、Python、Visual C++ 或 GPU 驱动。

运行 `dist/Shengjian-0.5.0-windows-x86-setup.exe`，安装到当前用户，无需管理员权限。也可完整解压 portable ZIP，运行其中的 `Shengjian.exe`，请保留旁边的 `recorder-whisper.dll`。

1. 打开设置 → 转写 → Whisper 本地识别 → 下载 Whisper Tiny，完成后保存。模型约 74 MiB，下载地址为 ggerganov/whisper.cpp；SHA256 固定校验。亦可选择 GGML 格式的 Tiny / Base / Small，32 位环境推荐 Tiny / Base。下载需要联网，本地识别不联网。
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

## 界面对齐（2026-10-17）

以当前 `Sources/Recorder/RecorderApp.swift` 的 MainView 为布局基准：1040 × 700 默认内容区、255 逻辑像素左侧栏、绿色强调色、顶部操作、时间戳与双语正文、底部状态与转写按钮。音源提示、设备刷新、翻译菜单与置顶入口统一收纳；设置按转写、翻译、LiveTranslate 分页，识别参数随服务切换显示。字幕改为深色浮窗，顶部可拖动、边缘可调整大小，支持字号和译文显示切换。

Windows 仍采用原生 WinForms，系统标题栏、字体和下拉菜单由 Windows 绘制，并非逐像素复刻 macOS。AI 提问入口暂不可用；AI 服务设置、译音播放、字幕背景透明度及样式自动保存尚未移植。本次不改动录音和识别引擎。
