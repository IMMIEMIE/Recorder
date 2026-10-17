# Windows x64 后端移植记录

基线：Mac/Windows 提交 `4d69912`。开始时已有 Windows 界面修改，差异与新增字幕源码已备份至 `.bootstrap/port-baseline`；不得覆盖或提交这些既有改动。

## 固定决策

Windows 11 x64；WinForms/.NET 10；C++ 原生推理；CPU 与 NVIDIA CUDA；命名管道；Mac 保留 Swift/MLX，以共享行为用例同步。x86 兼容版保留现有能力。

## 阶段与验收

| 阶段 | 状态 | 必要证据 |
|---|---|---|
| 1 基线与原生可行性 | 已通过 | 四类真实模型 CPU/CUDA、取消/恢复、三轮加载/释放；见 native-verification.json |
| 2 核心与配置 | 已通过 | 28项配置/迁移/状态/回滚检查，原生客户端由阶段1覆盖 |
| 3 音频/断句/预览 | Windows验收通过，Mac待验 | 60项Windows检查；共享样例与Swift入口已提供 |
| 4 识别与模型管理 | Windows 核心通过，桌面接通 | 80项检查、真实中文文件经桌面会话转录；UI 冒烟图已检查；全套故障和切换长测留最终验收 |
| 5 本地翻译 | 待开始 | 优先级、同语言跳过、跨会话归属 |
| 6 网络与 AI | 待开始 | HTTP/SSE/WS 模拟服务及真实账号验证 |
| 7 译音 | 待开始 | 配对/播放/重播/排除自身音频 |
| 8 发布 | 待开始 | 无开发环境安装、一小时会话、x86 回归 |

所有未通过的验收保留为未完成。模型与构建产物不进入 Git。不得使用云端替代本地模型验收。

## 阶段 1 当前证据

- 原有 x86 测试：28 项通过（`.bootstrap/x86-baseline-tests.log`）。
- CPU：四类模型均通过真实推理、取消后恢复和三轮加载/卸载。报告位于 `.bootstrap/native-verification-cpu*.json`。
- 原生命名管道握手、请求串行化、错误恢复、PCM 载荷校验和预取消通过。
- 修复命名管道同步句柄读写阻塞；使用 overlapped I/O。
- 为 x64 Whisper 接入 CPU 图计算取消回调，修复 Turbo 编码期间无法及时取消的问题；只生成构建目录中的适配源码，依赖 checkout 保持干净。
- CUDA：四类模型真实推理、取消/恢复、三轮加载/卸载通过；每轮卸载后的 GPU 可用显存恢复，无持续增长。
- 完整结果存档于 `native-verification.json`。Qwen ASR CUDA 三个样本耗时 461/306/252 ms；Whisper Turbo CUDA 为 508/430/455 ms。
- 开始阶段 2。真实模型功能尚未接入桌面界面，不能将阶段 1 通过视为整个移植完成。

## 阶段 2 证据

`scripts/test_windows_backend.ps1`：28 项检查通过。覆盖严格字段/类型/边界校验、旧配置与 DPAPI 迁移且不改原目录、加载期间控制响应、预热后提交、失败恢复旧模型、文件锁造成提交失败时回滚运行配置、取消下载后忽略迟到成功、流式定稿去重、退出释放。后端已与窗体分离；音频/识别缓存和逐 token 翻译的后续阶段接口目前尚未接入桌面。

## 阶段 3 证据

Windows 后端测试累计 60 项通过：真实 WebRTC VAD 静音检测；19个共享句末/分段样例；识别块与预览缓存；重复词保留；停止排空；序号断裂尾句；过期预览；积压停止且所有已接收定稿只处理一次；320KB捕获缓冲保护。共享样例为 `tests/shared/backend-cases.json`，Mac 测试入口为 `scripts/test_backend_shared.sh`。本机没有 Swift/Mac 环境，尚未标记双端同步通过；Mac 执行列入最终验收待办。继续实现独立的 Windows 模型管理。

## 阶段 4 证据

80项检查通过，新增固定 revision、SHA256、GGUF 架构、音频编码文件、HF blob/snapshot/ref、Range 续传、取消恢复、损坏修复、忽略 Range 的服务器、离线缓存及路径校验测试。四个真实模型的格式头通过校验。独立 `Recorder.Full` 项目自包含 .NET 10，接入现有 WinForms 窗口、设置页、后端音频邮箱和文件 EOF 排空。真实中文 AIFF 经采样转换、WebRTC VAD、Qwen CUDA 识别后返回完整文字（`.bootstrap/full-transcript.txt`）；主窗口和设置页冒烟启动通过。原有界面改动保持在工作区，未混入阶段提交。Mac 实机测试根据用户选择保留待办。
