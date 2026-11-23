# 双人对话与录制中切换译文语言（#22）

## 当前可运行的部分

macOS 本地翻译和逐句 API 翻译沿用主界面的目标语言菜单。句子开始翻译时绑定目标语言，切换后首条使用新语言的字幕上方显示「译文语言已切换为 English」等提示，保存和导出时保留。Android 和 macOS 目前均可读写逐行语言、说话方和切换标记。[会话文件和导出规范](SESSIONS.md)

云端会话更新、双路音频上传目前在独立探针运行。应用内的云端切换入口、双路连接管理、分屏、译音回授控制和 macOS Hy 方向切换仍待接入。UI 依赖 #21，协议能力和结束原因依赖 #23。

## Qwen 3.8 能力探针

离线验证使用回环模拟服务、固定 PCM 和 mock 密钥，覆盖两路并发、同一连接上再次更新、语言不匹配、错误、超时、说话人字段和 1007。macOS 用系统语言识别器运行路由测试。

```sh
android/gradlew -p android -PcoreOnly=true :core:test
scripts/test_dialogue.sh
scripts/test_sessions.sh
```

真实服务需另行授权。准备一条公开测试短句的 16 kHz 单声道 PCM16 WAV，在环境中为测试地址设置 `LIVETRANSLATE_API_KEY`。以下命令会建立两条计费连接，两路都发送这条音频。输出含测试句的译文。可通过 `LIVETRANSLATE_ENDPOINT` 指定兼容端点，`PROBE_TARGET`、`PROBE_PEER` 和 `PROBE_NEXT` 可覆盖三个不同的语言代码。

```sh
android/gradlew -p android -q -PcoreOnly=true :core:dialogueProbe --args='/absolute/path/test.wav'
```

默认 A 译为 en，B 译为 zh。两路确认后按实时节奏发送同一份音频，加两秒静音，再在 A 上请求 ja。仅语言和输出方式都匹配才记录 `confirmed`，随后再播一次。报告提供切换时的送音位置、两路独立的 `audio_start_ms`、`item_id`、`speaker_id` 和定稿译文。用开始时间与关联 ID 找到切换后的句子，检查 A 的译文实际为日语、B 仍为中文。服务可能确认配置却保持原语言、合并两句或省略字段，应如实记录观察结果。探针只观察自然发生的限流，无自动重试。负载、积压和延迟仍用现有 `scripts/probe_livetranslate.sh`。

## 对话路由和连接接入

- 每对语言使用两条目标不同的文本会话，源语音 PCM 相同。进入模式时一次性提示音频输入约为两倍。双路探针固定请求 `speaker_detection`。两个连接中的 item ID 和 speaker ID 只在各自连接内使用。
- 在原文定稿后识别语种。macOS 使用 NLLanguageRecognizer，Android API 29 起使用 TextClassifier，低版本根据文字脚本判断。罗马字母不能区分英法，只有汉字时也难以区分中日。证据不足或两路结果冲突时，保留原文供两侧标为「未识别」。[Android TextClassifier](https://developer.android.com/reference/android/view/textclassifier/TextClassifier#detectLanguage(android.view.textclassifier.TextLanguage.Request))
- `DialogueTurns.align` 接收一对固定目标语言下已定稿的片段。输入是同一采集时间轴上的毫秒数。接入独立重连与丢帧时，调用方须按实际发送的 PCM 片段将每路服务时间映射回采集时间。在语言对变更处结束当前窗口。排序后按起点一对一匹配，暂定容差 250 ms，若同路下一句离另一侧更近则留给下一句。说 A 语时采用目标 B 的译文，反向亦然。缺失一路时保留有依据的原文与可用的对侧译文。容差、系统识别置信度 0.6 和快语速效果仍需真机校准。
- 主动切换的接入顺序为合并约 1 秒内的选择、等当前句结束、请求更新，并验证返回的新目标语言。服务拒绝、确认不符或超时才更换连接。主动切换缓冲最多保存最近 **5 秒** PCM。新连接就绪后，`LiveHandoffAudio` 每次最多取 100 ms，按 1.25 倍实时速度追赶。过期的定时器不会累积一次突发补发的额度。接入时须让实时音频排在缓冲之后，沿用传输层积压保护。
- 首次建连和意外断线恢复遵循 #25，只补发最近 **1 秒**。Android 已在该路径使用同一缓冲实现。一路断开时应由另一路继续。限流等待沿用 20/40/80/160 秒，持续限流结束，识别「60 秒无结果」优先于 1007。双路与主动换线需共用同一账号的滚动 60 秒 8 次建连预算，为服务的 RPM 10 留余量。应用内双路共享预算和五秒主动换线还需在 #23 接口上验证。
