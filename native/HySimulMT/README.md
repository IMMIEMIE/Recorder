# Hy-SimulMT 本地组件

`scripts/build_hy_runtime.sh` 校验并构建固定的 llama.cpp HyV3 分支：
`d38e66aac7bb18101f417338b795e4546a5a1a59`。源码归档的 SHA256 为
`b98417108e06f5d70dbc5e9f3dc72cb145efecfaef5c7e602c1edff328bb3e24`。

组件使用同一文件内的语言模型和音频编码器，Metal 内核与依赖静态打包；
语音活动检测复用 `Sources/Cwebrtcvad` 的 WebRTC VAD 源码。
正式 App 仅需 `HySimulMTHelper`；`HySimulMTReferenceCLI` 仅用于验证。
运行时不下载模型、不联网，不把音频或字幕写入磁盘。

模型文件固定为 `tencent/Hy-SimulMT-30B-A3B-Interleave-GGUF` 的
`Hy-SimulMT-30B-A3B-Interleave-Q4_K_M.gguf`，由 App 独立下载和校验。

## 管道接口

启动参数：`--model FILE [--ctx 16384]`。stdin/stdout 为 UTF-8 JSONL，
每个消息都带 `protocol_version: 1`，日志写 stderr。

- 加载完成后输出 `hello`，含 `runtime_commit`、`context_size` 和 capabilities。
- `start`：`session_id` 和目标 `language` (`zh`/`en`)，就绪后输出 `ready`。
- `audio`：相同 `session_id`，`pcm` 为 16kHz、单声道、PCM16LE 的 Base64。
- `finish` 等待尾句处理并输出 `done`；`cancel` 停止当前会话但保留权重。
- `shutdown` 结束进程。EOF/管道断开也会结束进程。
- `update` 是一个字幕段的完整快照；按 `segment_id`、`revision` 覆盖。
  仅 `committed: true` 的译文可送语音合成。
- `warning` 标明未完整翻译的采样区间；`done.complete` 只表示没有检测到
  截断或未恢复区间，不保证机器翻译在语义上完全正确。

每次新的模型上下文首轮处理 1600ms，其后 800ms；按固定分支实现每轮
独立 mel、音频编码及 token 生成。普通轮最多128 token，窗口保留512 token。
待处理音频队列上限10秒、尚未提交的原始音频上限30秒。
上下文清理保留模型权重，重置 KV 与 sampler；清理前先尝试恢复未译音频。
EOF 尾块补零，真实采样数独立计时。

麦克风没有数字静音，所以静音判断用 WebRTC VAD（与后端分段相同的模式 2），不用固定能量阈值。
没有未译音频在等待时，静音块不进推理、不占上下文预算，只推进时间轴。
有未译语音时才在 2.4 秒静音后恢复；模型没听出文字且人声不足 300ms 的音频直接丢弃，
不恢复也不报告，否则恢复会对咳嗽或关门声编造文字。
流式和整段都没听出文字的音频视为噪声，不计入未译区间。

上下文用到 3/4 后，在下一个句末或停顿处主动切换（`early_rollovers`），不必等到预算耗尽时
打断语音并依赖恢复。预算耗尽的强制切换（`context_resets`）仍作为兜底。

模型偶尔破坏原文/译文格式，多见于长上下文末端（约 1500 轮中 1 轮只输出原文）。官方
SimulInfer 遇到这种输出直接报错；实时会话不能因一轮异常结束，因此这一轮按只有原文处理，
由下一轮或恢复补上译文，并计入 `malformed_turns`。恢复时已没有下一轮，模型在译文前结束
就补上分隔符继续生成，与官方 ST 从 source + TGT 前缀续写的做法一致。

恢复策略来自官方 SimulInfer `7efcb18c521a7025b37d4bc2230a1df8ade83950`
的 `VLLMSession.flush`：使用单独上下文和 ST 指令处理尚未提交的音频。
失败或生成上限截断会报告未译区间。恢复后的原文替换同一个字幕段，
避免重复追加此前已显示的临时原文。

## 验证

`--self-test` 不加载模型，检查 PCM/Base64 边界。
`scripts/verify_hy_runtime.py` 使用真实权重和实时节奏输入，检查空会话、
推理中取消、连续会话、窗口切换、EOF、底噪、两方向字幕，以及已知内容锚点。
正式通过要求两方向各至少600秒，并且处理实时系数不大于1。
短测或跳过完整验证会生成 `passed: false` 报告。

验证用的 `--reference-mode --trace-tokens` 关闭恢复/尾部补零等产品调度策略，
让同一个 `Model.turn` 与固定原 CLI 的逐轮 token 精确对照。参考 CLI 只增加
stderr token trace。比较仅在内存进行；报告不保存字幕或生成 token。
