# 会话记录与导出（macOS + 安卓共用规范）

issue #13 的会话管理与对话导出在两端分别实现，但**存储格式、默认标题、导出内容和文件名必须一致**。导出格式的权威实现是 `scripts/make_session_export_fixtures.py`，它生成 `tests/fixtures/session_export/`；两端的测试都要逐字节对比这些夹具。改格式时先改脚本并重新生成，再改两端。

## 隐私（不变量调整）

- 录音、译音音频、未定稿的 partial **从不**保存。
- 定稿的原文和译文默认保存在本机（「保存会话记录」开关，默认开启）；关闭后不再写盘，已有会话仍可查看、导出、删除，新会话只在本次运行内有效。
- 会话内容从不上传、不参与系统备份/设备迁移。
- 位置：
  - macOS：`~/Library/Application Support/LocalRecorder/sessions/<id>.json`，目录 0700、文件 0600，原子写入；不改变 `config.json` / `translation.json` / `models/`。
  - 安卓：`filesDir/sessions/<id>.json`，原子写入（临时文件 + rename）；`data_extraction_rules.xml` 在 cloud-backup 与 device-transfer 中排除 `sessions/`。
- 开关键：macOS `UserDefaults` 的 `sessions.persist.enabled`；安卓 `android.options.v1` 中的 `saveSessions`。

## 会话文件 v1

一会话一个 UTF-8 JSON 文件。示例见 `tests/fixtures/session_export/session.json`。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schema_version` | int | 固定 `1`。读到更大的版本：跳过该文件（不删除、不报错崩溃） |
| `id` | string | 小写 UUID，同时是文件名 |
| `title` | string | 显示标题 |
| `title_edited` | bool | 用户改过标题后为 `true`，此后不再自动生成 |
| `created_at_ms` / `updated_at_ms` | int | Unix 毫秒 |
| `segments` | array | 每次录制（含「继续录制」）一段：`started_at_ms`、`ended_at_ms`（录制中为 `null`）、`target_language`（无翻译时 `null`）、`mode` |
| `rows` | array | 只含定稿内容：`segment`（段下标）、`kind`（`text` / `break`）、`offset_ms`（相对所属段开始）、`source`、`translation` |

- `mode` 取值：`live_translate`、`hy_local`、`local_asr`、`api_asr`、`streaming_asr`（安卓只有 `live_translate`）。
- `break` 行是断线重连的断点（「连接中断，此处内容可能有缺失」），`source`/`translation` 为空。
- 读取时忽略未知字段；损坏的文件跳过并在列表中不显示，不删除。
- 写入时机：定稿行变化后防抖约 1 秒写一次；停止录制、应用进入后台/退出时立即写。崩溃最多丢最后约 1 秒的定稿。
- 译文可能在原文定稿之后才到（macOS 本地/API 翻译）：同一行就地更新后再写。

### 逐句语言和说话方（v1 可选字段）

`text` 行可增加以下字符串字段。保留原有 `kind` 和 `schema_version`。旧文件没有这些字段时沿用原行为，单语翻译的初始目标仍在所属段的 `target_language`。旧版读取方可直接忽略扩展字段。

| 字段 | 含义 |
| --- | --- |
| `target_language` | 该句实际使用的目标语言代码，例如 `en`。已定稿的行保留当时的目标 |
| `source_language` | 有可靠识别结果时记录原文语言代码 |
| `speaker` | 对话中的说话方 `A`、`B` 或 `unknown`，均为会话内的逻辑方，与服务返回的 speaker ID 无关 |
| `language_switch` | 用户主动切换后，首条新语言行保存所选语言的显示名，例如 `English`。对话中双方轮流发言不产生切换标记 |

导出时，先输出「继续录制」等段标记，再在有 `language_switch` 的行前输出「译文语言已切换为 English」。三种导出内容均保留切换标记。对话行在所选模式第一个非空文本前加 `A：`、`B：` 或 `未识别：`，双语模式每句标注一次。TXT 与 Markdown 沿用原有清理、转义和加粗规则，Markdown 标记文字也要转义。夹具见 `tests/fixtures/session_export/dialogue/`，旧夹具继续覆盖旧文件。[双路路由与探针](DIALOGUE.md)

## 默认标题

`title_edited` 为 `false` 时：`MM-dd HH:mm` + 空格 + 第一条非空原文（`text` 行，按下文「清理」后）的前 20 个 Unicode **码点**；没有原文时为 `MM-dd HH:mm 新会话`。时间用会话创建时间、设备时区。夹具：`expected/meta.json` 的 `default_titles`。

## 导出

格式：TXT、Markdown；内容：`bilingual`（双语）/ `source`（仅原文）/ `translation`（仅译文）。统一 LF 换行，UTF-8 无 BOM，文件以一个 `\n` 结尾。

**清理**：文本中的 `\r\n`、`\r`、`\n` 各替换为一个空格，再去掉首尾空白。

**条目顺序**（两种格式相同）：按 `rows` 顺序；相邻两行 `segment` 不同时，在后者之前插入标记「继续录制 `yyyy-MM-dd HH:mm`」（该段 `started_at_ms`）；`break` 行输出标记「连接中断，此处内容可能有缺失」；`text` 行按模式取清理后非空的部分（双语为原文、译文依次），一个都没有就跳过该行（但不影响段切换标记的判断）。

**TXT**：第一行清理后的标题，第二行创建时间 `yyyy-MM-dd HH:mm`；有条目时空一行，条目之间空一行。标记写作 `【…】`，文本行的各部分各占一行。

**Markdown**：`# 标题`、空行、创建时间；有条目时空一行，条目之间空一行。标记写作 `*【…】*`。双语模式下原文与译文之间用「两个空格 + 换行」硬换行，译文加粗 `**…**`；单语模式不加粗。转义（对标题和每段文字）：字符 ``\ ` * _ [ ] < > # | ~`` 前加 `\`；之后若以 `-` 或 `+` 开头，再在开头加 `\`；若以「数字 + `.`」开头，把该 `.` 改为 `\.`。

**文件名**：`声笺 yyyy-MM-dd HH-mm 标题.txt|md`（创建时间）。标题中 `/ \ : * ? " < > |` 与控制字符（< 0x20、0x7F）替换为 `_`，清理后取前 50 个码点再去首尾空白；为空时省略标题和它前面的空格。

时间均按设备时区格式化；夹具使用 `Asia/Shanghai`，测试时把时区作为参数传入。

## 界面（两端一致的行为）

- 侧栏：「新建会话」在顶部；按最后更新时间倒序，分组「今天 / 昨天 / 7 天内 / 更早」；每项显示标题与时间；录制中的会话有标记。macOS 用 `NavigationSplitView` 侧栏，安卓手机用抽屉、宽屏（≥ 840dp）用常驻侧栏。
- 点击会话查看内容；在历史会话上「继续录制」：追加新段，导出中出现「继续录制」标记。
- 录制中可以浏览其他会话，新内容仍写入正在录制的会话；录制中的会话不能删除。
- 重命名（设置 `title_edited`）、删除单个会话（需确认）、设置中「清空全部会话」（需确认）。
- 导出入口在会话视图（及侧栏右键/长按菜单）：选择格式和内容后，macOS 用 `NSSavePanel`，安卓用系统分享（`ACTION_SEND`）或「保存到文件」（`ACTION_CREATE_DOCUMENT`），不申请存储权限。导出只包含定稿文字，不含服务地址、API Key 等配置。
