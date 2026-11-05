# Hy-SimulMT 本地同传：开发与验证

本地模式使用直接接收音频的 Hy-SimulMT Interleave 模型，输出原文和译文。
普通 MLX 识别/文本翻译管线继续使用原有实现；Hy 使用 App 管理的原生 Metal 辅助进程。
这个适配仍是实验性的。入口是否可用取决于打包程序对应的真实验证记录，不能通过手动修改偏好设置跳过。

2026-11-05 的 M5 Pro / 48 GB 真机验收已通过，具体数据和已知限制见[实测记录](HY-SIMULMT-VALIDATION.md)。

## 固定依赖

| 内容 | 固定值 |
| --- | --- |
| llama.cpp 适配 | `lihy715/llama.cpp.Hyv3Speech`，`d38e66aac7bb18101f417338b795e4546a5a1a59` |
| 调度行为参考 | `Tencent-Hunyuan/Hy-SimulMT`，`7efcb18c521a7025b37d4bc2230a1df8ade83950` |
| 模型仓库 | `tencent/Hy-SimulMT-30B-A3B-Interleave-GGUF` |
| 模型版本 | `2aae4719eb91c1e6990c9386f70b2610f106b97e` |
| 文件 | `Hy-SimulMT-30B-A3B-Interleave-Q4_K_M.gguf` |
| 字节数 | `19746809728` |
| SHA-256 | `26c87f0a5f6409f3a57f8c4d2a49d58ad0f5c0753141643789e73564339cedbc` |

上游 [PR #31198](https://github.com/ggml-org/llama.cpp/pull/31198) 提供音频塔和逐轮推理。
官方 [SimulInfer 状态机](https://github.com/Tencent-Hunyuan/Hy-SimulMT/blob/7efcb18c521a7025b37d4bc2230a1df8ade83950/SimulInfer/simulinfer/translation.py) 是上下文切换和待译音频恢复的行为参考。
现有云端 Qwen 配置与密钥不用于本地模式。

## 构建与验证

在 Apple Silicon Mac 上使用完整 Xcode。辅助进程的构建脚本下载并校验固定源码归档，在 `.build/hy-tools` 中准备固定 CMake；这些是开发依赖，运行 App 不会安装它们。

```bash
./scripts/build_hy_runtime.sh
./scripts/test_hy_gate.sh
python3 scripts/test_hy_session.py
./scripts/test_local_speech.sh
./scripts/test_download.sh
./scripts/test_livetranslate.sh
./scripts/test_hy_livetranslate.sh
python3 scripts/make_hy_validation_audio.py
```

模型使用声笺的 HF 布局缓存，也可在开发机用 `hf download` 获取固定文件：

```bash
hf download tencent/Hy-SimulMT-30B-A3B-Interleave-GGUF \
  Hy-SimulMT-30B-A3B-Interleave-Q4_K_M.gguf \
  --revision 2aae4719eb91c1e6990c9386f70b2610f106b97e \
  --cache-dir "$HOME/Library/Application Support/LocalRecorder/models"
```

真实验证使用 16 kHz、单声道、PCM16 WAV：

```bash
python3 scripts/verify_hy_runtime.py \
  --model "$HOME/Library/Application Support/LocalRecorder/models/models--tencent--Hy-SimulMT-30B-A3B-Interleave-GGUF/snapshots/2aae4719eb91c1e6990c9386f70b2610f106b97e/Hy-SimulMT-30B-A3B-Interleave-Q4_K_M.gguf" \
  --en-zh .build/hy-verification/english-long.wav \
  --zh-en .build/hy-verification/chinese-long.wav \
  --anchors tests/hy_validation_anchors.json \
  --synthetic-fixtures \
  --tail-fixture .build/hy-verification/english.wav \
  --output docs/hy-runtime-verification.json
./scripts/build.sh
```

合成音频只用于性能和回归验证，不代表真实会议中的翻译质量。生成器将测试音频保存到 `.build`，不会录制用户音频。完整验证在双向长测后还运行带底噪的语音和纯底噪测试、独立尾句恢复探针、CLI 对照，以及两个方向各 240 秒的小上下文测试，每个方向覆盖至少两次预算切换，全程约 35 分钟。短样本运行保留报告，但不能让发布门槛通过。

系统语音的停顿是采样值严格为 0 的数字静音，真实麦克风不会产生这种音频。只用这些音频验证，会漏掉整类静音处理问题，所以底噪测试是必选项。

## 发布门槛

`bundle_hy_runtime.py` 与 App 内 `HyRuntimeAvailability` 都检查以下证据：

- 模型 SHA-256、固定运行时提交与当前辅助进程匹配。
- 两个翻译方向各至少 600 秒，完整处理、平均推理耗时不超过音频时长、最大排队不超过 10 秒。
- 结束输入前产生译文、CLI 对照、双向上下文切换、尾句恢复和推理中取消后重启均通过。
- 底噪：纯底噪不产生文字、警告或恢复；带底噪的双向语音完整处理，没有警告和上下文重置。
- 译文必须包含固定测试内容及仅在音频末尾出现的编号。原文遗漏只记录到 `source_anchor_misses`，不拦截：模型的原文行会丢掉它已正确翻译的词（`decreased by 5` → “减少了5%”），这是模型特性，不是集成问题。
- 没有失败的验证项。辅助进程重新编译后，旧报告不能用于不同的二进制文件。

构建时先验证原始程序哈希，再复制和签名辅助进程，并记录签名后文件的哈希供 App 检查。验证失败时仍能构建原有功能；本地入口保持禁用，不复制未经验证的辅助进程。需要让这种情况阻止构建时，可直接调用 `bundle_hy_runtime.py --require`。

## 会话与资源

App 与辅助进程通过本地标准输入/输出管道通信，不监听端口。输入采用带 `protocol_version: 1` 的 JSONL 控制消息及 Base64 PCM16；输出只包含结构化事件，诊断走标准错误。

事件包含会话 ID、段 ID、音频采样范围、原文、译文、修订号及完成状态。模型的分支与结束标记按 token ID 解析，不按可见字符猜测。临时文字可更新字幕；系统译音只接收已确认文字。

模型每隔两三秒提交几个词。App 用 `LiveSentenceRows` 把这些片段按句合并成一行：译文到句末、停顿超过 3 秒或累计超过 400 字才换行，转写窗口、字幕和导出因此都按句显示。

默认上下文为 16384 token，普通轮次最多 128 token，预留 512 token。输入排队和未译音频分别有 10 秒、30 秒上限。尾部补零不增加真实时间轴。音频仅在内存保留，完成后释放。

三条规则保证长时间运行稳定，修改时需要加对应的 `scripts/test_hy_session.py` 用例：

- **静音由 WebRTC VAD 判断。** 没有未译音频等待时，静音块不进推理、不占上下文预算。只有模型听出过文字或人声累计至少 300ms，才在 2.4 秒静音后恢复；流式和恢复都没听出文字的音频视为噪声，不报告未译。真正未译的区间才发出警告。
- **一轮异常输出不结束会话。** 模型输出只有原文、缺少译文分隔符时（官方 SimulInfer 在这里报错），这一轮按只有原文处理，由下一轮或恢复补上译文，并计入 `malformed_turns`。恢复时模型在译文前结束，就补上分隔符继续生成。
- **上下文提前切换。** 用到 3/4 预算后，在下一个句末或停顿处切换（`early_rollovers`）。这时不需要恢复，也避开了长上下文末端的不稳定和变慢（每轮耗时从约 120ms 增长到约 220ms）。预算耗尽的强制切换（`context_resets`）只作兜底。

译音使用安装在本机的系统语音。已提交的模型片段会先合并：边说边播放模式按逗号、分号或句末朗读短句，定稿后播放模式等待完整句末；正常结束会补读剩余尾句。系统语音默认语速几乎没有余量（60 秒连续讲话的译文要读 58–71 秒），所以积压超过 3 秒时加快到 0.55，超过 8 秒时加快到 0.6；排队 30 秒仍是停止译音的最后防线。缺少目标语言语音时提示用户在系统设置中添加；不会自动下载语音模型。关闭或停止播放会清理队列，旧会话回调不能恢复播放。逐段重播保留原目标语言。

打开两个开关会加载已下载的模型；普通启动不加载，和其他本地模型一样在主窗口点击「加载模型」。内存小于 32 GB 时打开开关也不自动加载。每次加载先做完整 SHA-256 校验，约 10 秒。

普通回归测试不依赖 19.75 GB 权重，使用可注入会话、假辅助进程、本地下载服务及语音队列替身。真实模型验证单独运行，结果以报告中的实际执行项目为准。
