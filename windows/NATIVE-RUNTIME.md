# 原生推理运行库

llama.cpp 固定 `f74e2fa6a31cc33ab4ee4ae516641cfe62df3924`；whisper.cpp 固定 `a8d002cfd879315632a579e73f0148d06959de36`。不跟随浮动分支构建。`models.lock.json` 记录模型来源、不可变 revision、文件大小与 SHA256。

## 开发验证

安装 .NET 10 SDK、VS 2022 C++、CMake；CUDA 构建需 NVIDIA CUDA Toolkit 12.8 或更新版本。用户运行安装包不需要这些开发组件。

```powershell
.\scripts\download_windows_models.ps1
.\scripts\build_windows_native.ps1 -Device cpu
dotnet run --project windows/Recorder.NativeVerify -c Release -- .bootstrap/runtime-x64/cpu/recorder-native.exe .bootstrap/verification-models . cpu
```

CUDA 使用 `-Device cuda`，验证器的设备参数也改为 `cuda`。完整报告写入 `.bootstrap/native-verification-*.json`；验证记录不能以编译成功替代。

也可运行 `scripts/verify_windows_native.ps1 -Device cpu|cuda`，它会先测试真实原生进程的握手、串行化、错误恢复、载荷校验及取消，再逐模型保存测试结果。x64 CPU 内核使用 AVX2；兼容版 x86 保持禁用 AVX/AVX2 的原构建参数。

## RPC v1

本机当前用户命名管道；帧为 4 字节小端 JSON 长度、UTF-8 JSON、可选 PCM16 载荷。JSON 最大 1 MiB，音频载荷最大 800000 字节，须为偶数。所有请求含 `rpc_version:1`、递增 `id`、`command`、`payload_bytes`；响应包含相同版本与请求 ID，以及 `result` 或 `error`。

命令：`hello`、`memory`、`load`、`unload`、`asr`、`begin`、`next`、`end`。`memory` 返回 GPU 可用/总内存，用于检查卸载后的资源恢复。`cancel` 控制消息携带 `target_id`，不进入工作队列。`asr` 使用 16 kHz 单声道 PCM16，单次不超过 25 秒，业务长句由识别缓存分块。`next` 返回原始 `token_bytes` 和 `done`，客户端用有状态 UTF-8 解码器处理跨 token 字符。

一个客户端最多一个工作请求；取消期间读取响应以恢复帧边界。10 秒内无法取消则终止进程，调用方须重新创建引擎。断管道终止推理；异常不写入音频或文本文件。模型载入失败卸载所有半初始化对象。

## 发布要求

CPU 与 CUDA 产物放在分开的目录，避免 DLL 搜索路径混用。每个目录包含 `recorder-native.exe`、匹配的 `recorder-whisper.dll` 和 `recorder-vad.dll`；CUDA 目录还需合法可分发的 CUDA/cuBLAS 依赖及其许可证。安装包不包含模型权重。

`native/prepare_whisper.ps1` 为 x64 生成一份构建目录内的 Whisper 源文件，将已有取消回调接入 CPU 调度后端。它检查固定版本的源码边界，不修改依赖仓库；x86 继续编译原文件。取消回调必须在每次图计算时更新，防止后续请求使用已经释放的调用上下文。
# 系统声音采集

`recorder-audio.dll` 使用 [微软进程级 loopback 接口](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)，以 `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE` 排除声笺和子进程；16kHz/mono/PCM16 直接送入有界邮箱。只在 x64 使用，x86 路径保留。创建、采样和释放在独立 MTA 线程执行，回调不保存音频文件。
