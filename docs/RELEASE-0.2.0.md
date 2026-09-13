# 声笺 0.2.0

2026-09-06

## 界面

删除主窗口顶部宣传标题、副标题、左下隐私说明和重复的就绪详情。空白提示缩短为「点击开始转写」。设置中保留模型、语言和快捷键，版本与分段参数折叠到「高级」。

## 模型

新增两个可选择的预设：

- `mlx-community/Qwen3-ASR-1.7B-bf16`（仍为默认）
- `mlx-community/whisper-large-v3-turbo`

**安装包不含模型权重。** 用户选择模型后首次点击「下载模型」，完成后会自动加载并保存配置。已有缓存时直接点击「加载 / 切换」。两个模型的下载分别复用缓存；按 commit 下载但没有 main 引用的缓存也能离线找到。录音期间不能切换。

Whisper 使用固定 `mlx-whisper==0.4.3`，Qwen 继续使用 `mlx-audio==0.5.1`。Whisper tokenizer 和 mel filter 等必要辅助资源来自已打包的后端库，不需要额外联网。输入始终是内存中的 16 kHz PCM，不需要 ffmpeg 读文件。

Whisper 的进程级 ModelHolder 缓存会在切换时清理，避免切回 Qwen 后仍驻留 Whisper 权重。参数采用自动语言或明确语言映射、转写任务、无跨段文本提示；输出是同段可替换快照，与原有最终段机制一致。

## 验证

在 Apple Silicon / macOS 26.6.2 实测：

- 18 项自动化测试通过，包括新架构校验、缺失权重、错误格式、全局缓存清理、无 main 引用的离线缓存以及精确版本不回退。
- Whisper revision `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` 成功离线识别中文、英文和中英混合合成样本，耗时约 0.42–0.47 秒/段；数字自然转成阿拉伯数字，重复的「谢谢」保留。
- 同一进程完成 Qwen → Whisper → Qwen，每次都完成预热和真实中文转写；确认切回 Qwen 后 Whisper 的全局权重引用已释放。
- 使用 App 内置 Python 和实际打包的服务脚本，以真实速度通过 socket 输入三个 Whisper 会话；预览 14 次、最终段 3 次，尾句完成、最终结果不重复、进程正常退出。
- Whisper 停止至就绪耗时约 0.53–1.18 秒（小型合成样本，非 P95 或真人录音结论）。
- 实际打开新主窗口和设置，确认删去的文字不再显示，两个模型预设可选；未下载 Whisper 时显示下载提示。

机器可读报告：`whisper-verification.json`、`whisper-pipeline-verification.json`、`switching-verification.json`。

模型下载用于开发验证，保存在开发目录，不放入 DMG，也不预先替用户安装 Whisper 缓存。0.1.0 的长时间录音/外设手工验收限制继续适用。仍使用本机临时签名，未做开发者签名与公证。

参考：[模型卡](https://huggingface.co/mlx-community/whisper-large-v3-turbo)。适配接口同时依据已安装 0.4.3 源码逐项核对。
