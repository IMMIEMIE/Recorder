# Windows x86 验证记录

日期：2026-10-17。基础提交：`6040391`。本地分支：`codex/windows-x86`。

环境：Windows 11 build 26200，x64 主机；应用及测试在真实 x86 / 32 位进程中运行。没有在独立 32 位 Windows 系统上验证。

- Release 构建：0 个警告、0 个错误。
- `Recorder.Tests.exe --model ...\ggml-tiny.bin`：**30 项检查通过**。包括 DPAPI、44.1 kHz 双声道浮点到 16 kHz PCM 的连续/分块等价、WAV、分句/静音/尾句、REST 与翻译、拒绝 HTTP 重定向与远程明文、两套 WebSocket 握手和停止尾句、乱序译文合并、TXT/SRT、文件 EOF 与取消会话、中英文真实 Whisper CPU 推理及完整本地文件会话。
- 英文 AIFF 离线结果：`This is a local speech recognition test. Please remember the number 1-2-345.`
- 中文 AIFF 离线结果：`你好,这是一个本地语音时别测试,今天下午3点开会,请记住数字12345`。Tiny 存在同音错字，此结果仅证明实际推理工作，不能当作准确率保证。
- 安装器在 `.bootstrap/install-smoke` 临时目录静默安装，退出码 0；安装后正常启动。卸载器退出码 0。最终应用 exe 与已验证安装副本的 SHA256 相同。
- 实际 UI 验证：设置页、模型已就绪的主窗口、文件选择、英文文件按原速处理、尾句文字显示、状态恢复。修复了空白页遮挡及完成会话时丢失待显示文字的问题。
- 主 exe、推理 DLL、安装器的 PE Machine 均为 `0x014c`（I386）。Whisper 静态链接 C++ 运行库，发布包含 .NET 8.0.32。安装器和 portable ZIP 旁提供 SHA256。

未实测：麦克风实际录音、扬声器实际回环、真实云服务密钥/权限/余额、不同 DPI/多显示器、独立 32 位 Windows。云服务使用本地模拟服务校验协议；没有发送真实用户音频到云端。
