# 声笺的界面设计

声笺把说过的话整理成可继续录制、阅读和导出的会话。两端共用纸笺声波标志、翠绿主色和文字层级。Android 使用 Material 3，macOS 使用 SwiftUI、系统菜单和 SF Symbols。

## 令牌与检查

颜色、字号、字重、间距、圆角和宽屏分界值在 [tokens.json](../design/tokens.json)。改动后执行以下命令，提交生成的 Swift、Kotlin 和 Android 窗口颜色资源。

```sh
python3 scripts/design_tokens.py
python3 scripts/design_tokens.py --check
python3 scripts/make_icon.py --check-android
```

Android 使用 `ShengjianTheme`，由系统外观选择浅色或深色。保留品牌色，Android 12+ 同样从令牌读取色板。SwiftUI 由当前窗口外观解析 `DesignTokens` 的动态 NSColor。悬浮字幕采用深色外观的浅翠绿译文，保持用户选定的字号、透明度和行数。

| 用途 | Material 3 / SwiftUI 角色 | 应用方式 |
| --- | --- | --- |
| 主操作 | primary / onPrimary | 开始或停止实时翻译，实心按钮加动词与图标 |
| 选中项 | secondaryContainer / onSecondaryContainer | 会话列表的当前位置 |
| 阅读底色 | surface / onSurface | 会话标题、译文 |
| 表面层次 | surfaceContainerLow、surfaceContainer、surfaceContainerHigh | 侧栏、控制区、底部面板；outlineVariant 作为分隔线 |
| 辅助信息 | onSurfaceVariant | 原文、时间、权限说明 |
| 强反馈 | errorContainer / onErrorContainer | 错误原因和可执行的下一步 |

所有正文配色按 WCAG 相对亮度计算，门槛为 4.5:1，大字至少 3:1。生成器按更高的 4.5:1 检查正文、状态文字、语义容器和未定稿文字的实际混色。启用按钮的实线描边、选中图形和文字提供额外线索。禁用按钮保留可读的标签，使用中性色和虚线边框。

## 状态与节奏

| 状态 | 令牌 | 图形 / 文案 | 展示位置 |
| --- | --- | --- | --- |
| 录制中 | recording | 声波或录制圆环 · 录制中 | 顶栏下方、列表活动会话 |
| 初次连接 / 重连 | connecting | 进度环 · 连接中 / 正在重新连接 | 顶栏下方，保留停止或取消操作 |
| 处理较慢 | slow | 网络警示图标和具体影响 | 单条状态栏，详情说明未翻译区段 |
| 错误 | error | 感叹号、原因、下一步 | 可关闭横幅或 Snackbar |
| 已完成 | complete | 勾号 · 已完成 | 停止并完成收尾后 |

同屏保留一个持续状态。一次性提示进 Snackbar，错误可关闭。优先展示影响录制的错误，其次是连接状态。录制动效装饰声波，静止图标和文字也应能表达状态。暂停译音或停止播放时字幕继续更新。

## 字体与布局

| 角色 | Android 字号 / 行高 | macOS | 使用 |
| --- | --- | --- | --- |
| 标题 | 22 / 28 sp，Semibold | 22 pt 起，按 title2 缩放 | 当前会话、页面标题 |
| 译文 | 20 / 28 sp，Medium | 20 pt 起，按 title3 缩放 | 双语字幕主行；仅有原文时原文可提升 |
| 原文 | 16 / 24 sp，Regular | 16 pt 起，按 body 缩放 | 双语字幕次行 |
| 说明 | 12 / 16 sp，Medium | 12 pt 起，按 caption 缩放 | 状态、分组、时间 |

系统字体，跟随系统缩放。未定稿附「识别中…」并使用 84% 前景不透明度。4、8、16、24、32 dp/pt 为常用间距。输入框、按钮、卡片和底部面板的圆角依次为 8、12、16、24。Android 图标可见尺寸 24 dp，触控区至少 48 dp。状态和正文允许换行，列表与设置在大字号下可滚动。

手机顶栏提供会话记录和更多操作，字幕贴近底部控制区。宽度达到 840 dp 时，左侧呈现独立的会话列表，右侧显示所选会话。滚动阅读时保留位置，用「回到最新」恢复跟随。macOS 保留已有栏目与键盘操作，工具栏次要按钮悬停时出现浅翠绿底与强调边框，按住时反色；禁用操作全程维持中性样式。

## 原生图标与术语

| 操作（推荐文案） | Android · Material Symbols Rounded | macOS · SF Symbols |
| --- | --- | --- |
| 开始实时翻译 / 开始转写 | mic | mic.fill |
| 停止实时翻译 / 停止转写 | stop | stop.fill |
| 设置 | settings | slider.horizontal.3 |
| 导出会话 | upload_file | square.and.arrow.up |
| 分享 | share | square.and.arrow.up |
| 删除会话 | delete | trash |
| 重命名会话 | edit | pencil |
| 继续录制 | resume | record.circle |
| 译音 / 停止译音 | volume_up / volume_off | speaker.wave.2 / speaker.slash |
| 网络状态 | network_check | wifi |
| 会话记录 | menu | sidebar.left |
| 回到最新 | arrow_downward | arrow.down |

仅按实际画面添加 Android 矢量资源。图标源与授权见 [Google Material Symbols](https://github.com/google/material-design-icons) 和 [Apache 2.0](../design/material-symbols-LICENSE.txt)。装饰性图标由相邻文字命名，独立图标按钮提供动作描述。

会话列表分组沿用两端现有日期规则。导出面板使用「TXT / Markdown」和「双语 / 仅原文 / 仅译文」，接「保存到文件」「分享」「复制」。首次使用先说明麦克风与后台通知的用途，录制时再申请相应权限。服务设置的目标是校验后即时保存，并明确显示连接测试的进行中、成功和失败。

## Android 样稿确认

[Compose 样稿](../android/app/src/screenshotTest/kotlin/com/localrecorder/shengjian/DesignPreviews.kt) 使用示例会话和原生组件。手机为 393 × 780 dp，平板为 960 × 660 dp，另有 200% 字体、会话记录、设置、导出和首次引导。真实渲染的 [九张 PNG](../android/app/src/screenshotTestDebug/reference/com/localrecorder/shengjian/DesignPreviewsKt) 可在 GitHub 打开。在 Android Studio 的 Preview 打开上述文件；命令行使用以下步骤。

```sh
cd android
./gradlew :app:updateDebugScreenshotTest
./gradlew :app:validateDebugScreenshotTest
```

确认点为手机字幕密度、译文与原文的层级、平板列表宽度和底部控制区。上述布局已经确认并接入现有控制器。正式入口支持长按菜单、录制保护、双栏、底部锚定、即时设置以及导出面板，开始录制时请求权限。样稿与应用共用字幕行、状态条、设置分组、导出选项和引导组件。

[运行截图](design-review/)展示 Android 应用连接本地测试服务后继续录制的手机和平板界面、200% 字号、引导、设置、导出，以及 macOS 深色工具栏的禁用、可用和按下状态。

服务区保留独立分组。#23 提供配置选择、协议与模型字段、凭据隔离及连接测试结果；其数据模型和迁移由该议题负责。服务编辑器挂在独立的布局插槽中。普通偏好即时保存，服务地址和密钥作为一组草稿，在离开设置或切到后台时校验保存。测试连接直接使用草稿；尝试连接期间以及失败后保留上次保存的服务和密钥。地址变化时清除尚未保存的密钥草稿。#1 的 macOS 语言菜单和 #4 的滚动策略各沿用对应实现。#7 的 AI 工作区视觉和 #13 的正式版设备验收另行跟踪。
