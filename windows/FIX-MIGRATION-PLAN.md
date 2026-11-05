# 声笺 Windows x64 修复与迁移计划

日期：2026-10-17。基线：`codex/windows-x86` 分支 `8bf353f`（x64 0.6.0 预览版）。本轮产物：x64 0.6.1 预览版源码。

目标：一比一复刻 Mac 版功能，本地模型使用 CUDA 生态（llama.cpp / whisper.cpp + CUDA 12.8）。本轮先解决两个阻断问题：**切换语言崩溃**和**安装包巨大**，再继续功能对齐。

## 阶段总览

| 阶段 | 内容 | 状态 | 验证方式 |
|---|---|---|---|
| 0 诊断基线 | 全局崩溃日志、原生进程退出码与 stderr、无模型跨平台测试 | **完成** | `scripts/test_windows_portable.*`（Linux 已通过） |
| 1 切换语言修复 | 9 个根因修复（见下） | **代码完成** | 便携测试 + 原有后端测试 97 项（Linux）；Windows 实机回归待做 |
| 2 安装包瘦身 | CUDA 运行库按需下载、CUDA 架构收敛、资源裁剪、体积预算 | **代码完成** | 发布规则已在 Linux 验证；最终安装包体积需在 Windows 构建机测量 |
| 3 Mac 功能对齐 | 对照表复核、偏差登记、验收清单 | 进行中 | 见 `PARITY.md` |
| 4 共享 ggml 动态后端 | llama/whisper 共用一份 ggml-cuda；CPU 多指令集变体 | 设计 | 需 Windows + CUDA 构建机 |

## 阶段 0：诊断基线（完成）

原问题：x64 应用没有任何全局异常处理；后台线程上的未处理异常直接终止进程，不留记录；原生推理进程崩溃只显示“异常退出”。

- `Recorder.Backend/Diagnostics.cs`：本地日志 `%LOCALAPPDATA%\Shengjian-x64\logs\shengjian-日期.log`，保留 14 天，单文件 4 MiB 上限。只记录异常和退出信息，**不记录音频、原文、译文或密钥**。
- `Recorder.Full/Program.cs`：界面线程异常改为记录日志并提示“可以继续使用”，不再直接退出；`AppDomain` 致命异常和未观察的 Task 异常同样写入日志。
- `NativeClient`：采集原生进程 stderr 末尾 40 行（GGML 断言会打印在这里）。错误信息带退出码并翻译成中文，例如 0xC0000005 内存访问冲突、0xC0000409 GGML 断言、0xC000001D CPU 不支持 AVX2、0xC0000135 缺少 DLL。
- 原生进程启动即退出（缺 DLL、CPU 不支持）时立即报告原因，不再等 20 秒超时。
- 新增 `Recorder.FakeNative`：与 `native-host/main.cpp` 协议一致的假推理进程，用环境变量注入延迟和崩溃。
- 新增 `Recorder.PortableTests`：用真实的 `BackendCore` + `NativeEngine` + `NativeClient` 对接 FakeNative，在 Windows 和 Linux 上都能跑，不需要模型或 GPU。

## 阶段 1：切换语言崩溃修复（代码完成）

本环境没有 Windows/GPU，**无法直接复现原始崩溃**。修复依据是对切换路径的逐项审查，加上并发压测中实际复现的问题。修复后若仍崩溃，请把上面的日志目录发回来：日志包含退出码和 stderr，可直接定位。

| # | 根因 | 现象 | 修复 |
|---|---|---|---|
| R1 | 后端所有异步事件都带“最近一条命令”的 `request_id` | 重新加载或切换后，新操作收到旧操作的错误而失败（压测复现） | 用 `AsyncLocal` 记录事件来源，排入队列的任务沿用发起命令的 id；无关事件不带 id |
| R2 | 翻译模型加载期间拒绝 `translation_settings` | 开启翻译后首次加载 4B 模型需十几秒，这期间点任何目标语言都报“请等待翻译模型操作结束”（压测复现） | 加载中可以切换目标语言，加载提交时采用最新选择；加载中关闭翻译或改用 API 会取消加载，且不报错 |
| R3 | 偏好请求把 translator 的 `error` 状态当作请求失败 | 翻译进程崩溃后，切换语言显示空白错误（压测复现） | 请求匹配逻辑抽成共享的 `BackendRequests`，桌面端和测试使用同一份规则 |
| R4 | 只改识别语言也会完整重载 | 杀掉并重启原生进程、重新加载 4.7 GB 权重；保存设置时还无条件重载翻译模型，CUDA 显存反复申请和释放 | 语言、停顿、预览参数改为就地生效（`IAsrEngine.SetLanguage`），不重启进程；翻译模型只在模型、引擎或设备变化时重载 |
| R5 | 翻译任务的 `CancellationTokenSource` 在锁外 Dispose，可能同时在锁内被 Cancel | 偶发 `ObjectDisposedException`；如果发生在进程退出回调线程上，会直接终止应用 | Dispose 移到锁内，Cancel 的回调异常写入日志 |
| R6 | 原生进程退出回调和事件订阅者中的异常没有隔离 | 线程池线程上的异常直接终止应用；订阅者异常会让事件循环停止，之后所有等待都挂起，表现为“卡死” | 回调与每个订阅者都用 try/catch 隔离并写日志；界面更新改为非阻塞的 `BeginInvoke` |
| R7 | 没有全局异常处理 | 异常直接退出，没有任何记录 | 阶段 0 |
| R8 | UTF-8 解码器遇到不完整字符就抛异常 | 生成在多字节字符中间停在 max_tokens（日、韩、俄目标语言更常见）时，翻译失败并清空队列 | 改为替换字符，不抛异常 |
| R9 | CUDA 进程缺 DLL 时要等 20 秒连接超时 | “自动”设备每次加载都卡 20 秒再回退 CPU | 进程退出即刻报告并回退 |

## 阶段 2：安装包瘦身（代码完成）

体积来源（实测或按清单计算）：

| 组成 | 原 0.6.0 | 0.6.1 |
|---|---|---|
| NVIDIA `cublasLt64_12.dll` | 643 MiB | 不进安装包，首次使用 CUDA 时下载 |
| NVIDIA `cublas64_12.dll` + `cudart64_12.dll` | 109 MiB | 同上 |
| CUDA 内核 | 两份 ggml-cuda（`recorder-native.exe`、`recorder-whisper.dll`），各 5 个架构 × SASS+PTX = 10 份镜像 | 每份 4 个架构的 SASS（75/86/89/120），镜像数减少 60% |
| .NET 10 自包含 | 120 MiB（实测，含 13 种界面语言资源） | 111 MiB（实测；只保留简中和英文资源） |
| 安装器压缩 | `lzma2/fast` | `lzma2/ultra64` |

改动：

- `windows/cuda-runtime.lock.json` 固定 NVIDIA 官方 PyPI wheel：`nvidia-cublas-cu12 12.8.4.1`、`nvidia-cuda-runtime-cu12 12.8.90`。清单记录每个 wheel 和每个解出 DLL 的 SHA256 与大小，许可证随 wheel 一并解出。
- `Recorder.Backend/CudaRuntime.cs`：下载器支持断点续传、多镜像（官方源→清华→阿里，可用 `SHENGJIAN_PYPI_MIRROR` 指定首选），校验通过后解压到 `%LOCALAPPDATA%\Shengjian-x64\runtime\<id>`，并删除下载的 wheel。下载前检查磁盘空间。镜像返回的文件大小不符时，在写入前拒绝。
- 设置 → 识别 → 运行设备下新增“GPU 加速组件”一栏，提供下载和移除。未安装时，“自动”静默使用 CPU；选择“NVIDIA CUDA”会提示先下载。
- `NativeEngine` 把运行库目录放进 CUDA 进程的 `PATH` 和 `SHENGJIAN_DLL_DIRS`；`main.cpp` 调用 `AddDllDirectory`，使 whisper DLL 也能找到 cuBLAS。
- `build_windows_native.ps1`：新增 `-CudaArchitectures`（默认 `75-real;86-real;89-real;120-real`）；校验 CUDA Toolkit 版本与清单一致；默认不复制 cuBLAS，并删除旧构建残留。
- `build_windows_full.ps1`：版本改为 0.6.1。新增 `-BundleCudaRuntime`，用于制作离线完整包（产物名带 `offline`）。默认包里出现 NVIDIA 库时构建失败。发布后打印体积报告，超过 `-MaxPackageMiB`（默认 700）时失败。
- `Recorder.Full.csproj`：默认排除 `cublas*/cudart*/nvblas*`；`SatelliteResourceLanguages=zh-Hans;en`。

## 阶段 3：Mac 功能对齐（进行中）

`PARITY.md` 中各子系统的入口均已接通。本轮登记一项有意偏差：Windows 切换识别语言就地生效，Mac 会重载模型。两者结果一致，Windows 避免了重启 CUDA 进程。

剩余对齐与验收清单（需实机）：

1. Windows 实机：切换识别语言和目标语言 50 次以上，包括翻译加载中、会话结束后译文仍在生成时、翻译进程崩溃后；跑 `--soak 3600`。
2. 无开发环境的干净 Windows 11：安装 0.6.1 → 下载 GPU 加速组件 → 断网后 CUDA 转录与翻译。
3. RTX 20/30/40 各一张卡验证 4 架构 SASS；无 NVIDIA 显卡的机器验证“自动”直接走 CPU。
4. Mac 端：零起点流式句子 ID 的兼容修正（`PARITY.md` 已登记），在 Mac 上执行共享样例。
5. 真实云账号：HTTP 转写、千问流式、LiveTranslate 译音。

下一阶段要做的界面对齐（Mac 已于 2026-10-30 完成）：
- 字幕改为 YouTube 式：只显示最新几行文字，每行一条半透明底色，或仅文字带阴影；窗口大小随文字变化，以底部中点为锚点。字幕获得焦点时可用方向键移动（Shift 加速、Option 微调）；字号、行数、背景、底色不透明度和译文开关放在右键菜单里。Windows 端计划用 `UpdateLayeredWindow` 实现逐像素透明。
- 主窗口：只在已经停在底部时才跟随新文字。向上翻看历史时保持位置，并显示「回到底部 / 有新内容」按钮（⌘↓）。Windows 端还需在重绘时保留滚动位置和选区。

## 阶段 4：共享 ggml 动态后端（设计）

- llama.cpp 与 whisper.cpp 各自静态链接一份 ggml，CUDA 内核因此重复。计划改为 `BUILD_SHARED_LIBS=ON` + `GGML_BACKEND_DL=ON`，由 whisper 使用 llama 的 ggml（`WHISPER_USE_SYSTEM_GGML`）。这样只有一份 `ggml-cuda.dll`，CUDA 内核体积再减半；`ggml-cuda.dll` 还可以并入按需下载的 GPU 组件。
- 同时启用 `GGML_CPU_ALL_VARIANTS`，运行时按 CPU 选择 `ggml-cpu-*.dll`，去掉“CPU 必须支持 AVX2”的硬性要求。
- 可行性检查（2026-10-17，Linux CPU）：llama.cpp `f74e2fa` 的 ggml 可以按 `BUILD_SHARED_LIBS` + `GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS` 构建（生成 `ggml-cpu-haswell/icelake/...` 等变体）。但固定的 whisper.cpp `a8d002c` 不能链接这份 ggml：`whisper.cpp` 用到的 `GGML_KQ_MASK_PAD` 在新版 ggml 中已删除。因此阶段 4 需要先把 whisper.cpp 升级到与该 ggml 同步的提交，重新适配 `prepare_whisper.ps1` 的取消补丁，并重新做 Whisper 的数值与取消验证，最后在 Windows + CUDA 构建机上验收。

## 如何验证本轮改动

```powershell
.\scripts\test_windows_portable.ps1          # 无模型：切换压测 + GPU 组件下载器（Windows/Linux 均可）
.\scripts\test_windows_backend.ps1           # 原有后端检查
.\scripts\build_windows_full.ps1             # 默认小包；末尾打印体积报告
.\scripts\build_windows_full.ps1 -BundleCudaRuntime   # 离线完整包
```

```bash
./scripts/test_windows_portable.sh           # Linux/macOS，需 .NET 10 SDK
```
