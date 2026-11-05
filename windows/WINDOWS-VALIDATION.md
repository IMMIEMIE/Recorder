# Windows x64 预览版验证

## 0.6.1 增量（2026-10-17）

本轮改动的根因与范围见 `FIX-MIGRATION-PLAN.md`。验证环境是 Linux 云容器（.NET SDK 10.0.112），**没有 Windows、GPU 或模型**：

- `Recorder.PortableTests`：40 项检查，连续 5 轮通过。真实 `BackendCore`、`NativeEngine`、`NativeClient` 对接协议一致的 `Recorder.FakeNative`，覆盖：
  - 目标语言切换风暴（每轮 30 次，期间定稿持续进入、逐 token 生成进行中），每个翻译单元恰好以 done 结束，最后的选择生效并已保存；
  - 翻译模型加载中切换目标语言并在提交时采用；加载中关闭翻译会取消加载，不报错；
  - 识别语言切换 10 次，原生进程 0 次重启，新的语言提示传到推理进程；更换模型仍会重载；
  - 翻译进程崩溃后切换语言、重新加载，不会收到旧错误；ASR 进程崩溃后错误带退出码，重新加载可恢复；
  - 未安装 GPU 组件时，“自动”静默走 CPU，显式 CUDA 给出安装提示；
  - GPU 组件下载器：镜像 404 与内容损坏时回退下一个镜像、中断后用 Range 续传、损坏的已安装文件能被识别、卸载、离线包自带的库直接可用。
- 原有 `Recorder.BackendTests` 在 Linux 上运行，97 项通过。跳过的部分依赖 Windows：DPAPI、硬链接、原生 VAD DLL、文件共享冲突。
- `Recorder.Full` 发布规则：默认包不含 `cublas*/cudart*`；`-p:BundleCudaRuntime=true` 时包含；`cuda-runtime.lock.json` 随包提供；只保留 zh-Hans 资源目录，.NET 部分 111 MiB。
- 尚需 Windows 执行：`test_windows_backend.ps1`、`Recorder.FullTests`、`test_windows_portable.ps1`、原生构建（CUDA 4 架构）、安装包实际体积、GPU 组件真实下载（约 542 MiB）及 CUDA 推理、界面上的切换回归。

## 0.6.0

本报告区分代码实现、当前机器实测及外部验收。尚未标记整个移植正式完成。Mac 执行按用户选择保留待办。

## 已实现并验证

- Windows 11 x64 / .NET 10 自包含 WinForms；独立命名管道 C++ 推理进程，退出随主程序回收。
- Qwen3-ASR 1.7B BF16（含音频编码 GGUF）、Whisper Turbo、Qwen3 4B Q4_K_M、Hunyuan-MT 7B Q4_K_M：CPU/CUDA 均完成真实推理、取消恢复及三轮加载释放。
- Whisper Tiny/Base/Small：固定 revision、大小与 SHA256；CPU 真实三语种推理、取消恢复和反复加载通过。
- 配置严格校验、原子提交、按角色提交运行选项、旧 x86 配置只读迁移、DPAPI 密钥隔离。
- WebRTC VAD、240ms 预录、智能/固定停顿、预览修订及失效、分块缓存、EOF/停止排空和积压停止；不按25秒强制定稿、不做重叠识别和文本去重。
- 本地翻译逐 token 拉取、ASR 优先、四个等待单元、九目标语言、同语种跳过、两组上下文、旧会话译文回原行。
- HTTP/WS/SSE 模拟服务、连接失败/截断/限流/取消/重定向拒绝；AI 总结/翻译/提问窗口和多服务管理。
- LiveTranslate text/audio 协商，24kHz PCM16，重复过滤、样本拼接、先音频后关联、按原文顺序定稿播放；30秒单段、128MiB内存重播，清空释放。
- Windows 进程级 loopback 实测排除自身播放：自身峰值0.0000305，独立外部进程峰值0.06088，无采集错误。
- 原生工作进程被主动结束时及时报告错误，保留已完成文字；重新加载后继续转录。真实 Whisper Turbo CPU 预热取消后恢复 Tiny，继续识别通过。
- 主窗口、设置窗口冒烟绘制和偏好保存；x86 原有28项回归通过。

Windows 后端150项、桌面协议13项、x86兼容版28项检查通过。

## 本机和数据

Windows 11 x64，Ryzen 7 7800X3D，约32GB RAM，RTX 5060 Ti 16GB，驱动610.88；原生依赖、模型版本与构建参数在 `NATIVE-RUNTIME.md`、`models.lock.json`、`native-verification.json` 中固定。

`quality-verification.json` 对三段固定合成音频计算去标点/大小写后的 CER，以及英文 WER。Qwen 的三个样本 CER 为0、英文 WER为0；CUDA 实时系数约0.04–0.06。该小样本不代表真人、噪声或各口音准确率。Whisper 的繁简和数字写法差异会计入字面错误率，未用语义或数字归一化隐藏差异。

CPU 验证正确性和过载保护，不承诺实时：本机 Qwen 部分样本实时系数约1.15–1.25，Whisper Turbo约2.15–3.19。自动设备回退已通过真实 CPU 推理；明确选择 CUDA 不会静默切换 CPU。

连续识别＋本地翻译运行49分钟，完成293次定稿及293次翻译，无报告错误；按用户要求提前停止，不标记一小时验收通过。记录见 `soak-verification.json`。定稿 `elapsed_ms=0` 可表示复用预览缓存，不能解释为模型推理耗时为0。

## 发布前待办

- 无开发环境的独立 Windows 11 机器：安装、首次模型下载、物理断网后转录与翻译、卸载保留数据和回退。
- 真实云测试账号：HTTP、千问流式及 LiveTranslate 的正式握手、额度、尾句和译音质量。当前只用了虚构密钥和本机模拟服务。
- 实体麦克风、外设拔插、睡眠唤醒、不同输出设备及实际房间中的回录行为。
- Mac：执行共享样例和原有回归，确认协议字段、修订号、队列和配置行为；零起点流式句子 ID 的兼容修正也需同步确认。
- 发布签名与最终人工试听；不把未执行项目标记为通过。

## 复现

- `scripts/test_windows_backend.ps1`
- `.bootstrap/dotnet10/dotnet.exe run --project windows/Recorder.FullTests -c Release`
- `scripts/verify_windows_native.ps1 -Device cpu` / `-Device cuda`
- `Recorder.FullTests.exe --cpu-fallback`、`--native-crash`、`--soak 3600`
- `scripts/build_windows_full.ps1`；x86 使用 `scripts/build_windows.ps1`

测试录音与输出仅由验证入口显式保存；正常转录不会自动保存音频、原文、译文或译音。

当前随包 CUDA 组件针对 RTX 50 系列，在 RTX 5060 Ti 上实测；其他代际 GPU 尚未验证，请使用 CPU 模式。完整一小时会话保留待办。
