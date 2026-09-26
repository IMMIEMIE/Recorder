import SwiftUI

@main
struct RecorderApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("声笺 · 实时转写", id: "main") {
            MainView(model: model)
                .frame(minWidth: 800, minHeight: 570)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .defaultSize(width: 1040, height: 700)
        Settings {
            TabView {
                ScrollView { SettingsView(model: model).padding(24) }.tabItem { Label("转写", systemImage: "waveform") }
                ScrollView { TranslationSettingsView(model: model).padding(24) }.tabItem { Label("翻译", systemImage: "character.bubble") }
                ScrollView { LiveTranslateSettingsView(model: model).padding(24) }.tabItem { Label("LiveTranslate", systemImage: "globe") }
                AISettingsView().tabItem { Label("AI 服务", systemImage: "sparkles") }
            }.frame(width: 640, height: 600)
        }
        MenuBarExtra("声笺", systemImage: model.recording ? "mic.fill" : "waveform") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.statusTitle)
        Button(model.canStop ? "停止转写" : "开始转写") { model.toggle() }
            .disabled(!model.canStop && !model.canStart)
        Button("显示转写窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("字幕模式", isOn: Binding(get: { model.subtitleMode }, set: { model.setSubtitleMode($0) }))
        Button("文本另存为…") { model.saveText() }.disabled(model.finalText.isEmpty)
        Button("复制文字") { model.copyText() }.disabled(model.finalText.isEmpty)
        Divider()
        Button("退出声笺") { model.shutdown(); NSApp.terminate(nil) }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var floating = false
    @State private var showAI = false
    @StateObject private var ai = AIWorkspace()
    private let accent = Color(red: 0.14, green: 0.43, blue: 0.38)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 27, weight: .medium)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("声笺").font(.system(size: 22, weight: .semibold))
                        
                    }
                }.padding(.bottom, 10)
                Label("实时转写", systemImage: "text.bubble.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(13).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    Text("音频输入").font(.caption).foregroundStyle(.secondary)
                    Picker("音源", selection: $model.audioSource) {
                        Text("麦克风").tag("microphone")
                        Text("音频文件").tag("file")
                        Text("系统声音").tag("system")
                    }.disabled(model.inputBusy)
                    if model.audioSource == "microphone" {
                    Picker("麦克风", selection: $model.device) {
                        Text("系统默认麦克风").tag(UInt32(0))
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    }.labelsHidden().disabled(model.inputBusy)
                    HStack { Circle().fill(model.permission == "已允许" ? accent : .orange).frame(width: 6, height: 6); Text("麦克风权限：\(model.permission)").font(.caption2).foregroundStyle(.secondary) }
                    } else if model.audioSource == "file" {
                        Button("选择音频文件…") { model.chooseAudioFile() }.disabled(model.inputBusy)
                        Text(model.audioFileURL?.lastPathComponent ?? "尚未选择文件").font(.caption).lineLimit(2)
                        Text("按原始语速转写，不播放声音；文件结束后自动处理尾句。").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("采集其他应用播放的声音，不使用麦克风。首次使用需允许屏幕与系统音频录制权限。").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<24) { i in Capsule().fill(Float(i)/24 < model.level ? accent : accent.opacity(0.12)).frame(height: 5 + CGFloat(i % 4) * 3) }
                    }.frame(height: 22)
                    if model.audioSource == "microphone" { Button("刷新设备") { model.refreshDevices() }.buttonStyle(.link).font(.caption) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("识别模型").font(.caption).foregroundStyle(.secondary)
                    Text(model.activeModelName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text("实时翻译").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    Text(model.translationSummary).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .foregroundStyle(model.translatorState == "error" ? Color.orange : Color.primary)
                    SettingsLink { Label("设置", systemImage: "slider.horizontal.3") }.buttonStyle(.link).font(.caption)
                }
                Spacer()

            }.padding(24).frame(width: 255).frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Spacer()
                    Button { model.setSubtitleMode(!model.subtitleMode) } label: { Image(systemName: model.subtitleMode ? "captions.bubble.fill" : "captions.bubble") }
                        .help(model.subtitleMode ? "关闭字幕模式" : "打开字幕模式").accessibilityLabel("字幕模式")
                    Button { floating.toggle(); NSApp.keyWindow?.level = floating ? .floating : .normal } label: { Image(systemName: floating ? "pin.fill" : "pin") }.help("窗口置顶")
                    Menu {
                        if model.liveEnabled {
                            Text("LiveTranslate → \(model.liveConfiguration.languageName)")
                        } else {
                        Toggle("实时翻译", isOn: Binding(get: { model.translationEnabled }, set: { model.setTranslation(enabled: $0) }))
                            .disabled(model.translatorBusy)
                        Picker("翻译为", selection: Binding(get: { model.translationTarget }, set: { model.setTranslationTarget($0) })) {
                            ForEach(AppModel.translationTargets, id: \.self) { Text($0).tag($0) }
                        }
                        }
                        Divider()
                        SettingsLink { Text("翻译设置…") }
                    } label: {
                        Label(model.liveEnabled ? "译为\(model.liveConfiguration.languageName)" : (model.translationEnabled ? "译为\(model.translationTarget)" : "翻译"), systemImage: "character.bubble")
                    }.fixedSize().help(model.translationSummary)
                    Button { ai.prepare(text: model.joinedText); showAI = true } label: { Label("AI 提问", systemImage: "sparkles") }
                        .disabled(model.finalText.isEmpty || model.liveEnabled)
                    Button { model.saveText() } label: { Label("另存为…", systemImage: "square.and.arrow.down") }
                        .disabled(model.finalText.isEmpty).help("将已确认文本保存为 TXT")
                    Button { model.copyText() } label: { Label("复制", systemImage: "doc.on.doc") }.disabled(model.finalText.isEmpty)
                    Button { model.clear() } label: { Image(systemName: "trash") }.disabled(model.busy || model.finalText.isEmpty).help("清空会话")
                }.padding(.horizontal, 24).padding(.vertical, 14)
                Divider().padding(.horizontal, 30)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if model.finalText.isEmpty && model.partial.isEmpty {
                                VStack(spacing: 18) {
                                    Image(systemName: "waveform.circle").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(accent.opacity(0.55))
                                    Text(model.recording ? "正在聆听…" : "点击开始转写").font(.system(size: 15)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 80)
                            }
                            ForEach(model.finalText) { item in
                                HStack(alignment: .top, spacing: 18) {
                                    Text(String(format:"%02d:%02d", Int(item.seconds) / 60, Int(item.seconds) % 60)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 38).padding(.top, 6)
                                    VStack(alignment: .leading, spacing: 6) {
                                        if item.incomplete { Text("连接结束，此句可能不完整").font(.caption2).foregroundStyle(.orange) }
                                        else if !item.sourceDone { Text("识别中…").font(.caption2).foregroundStyle(.secondary) }
                                        Text(item.text).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
                                        if !item.translation.isEmpty {
                                            Text(item.translation).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled)
                                        } else if item.translating {
                                            Text("翻译中…").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if !model.partial.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("识别中").font(.caption2).foregroundStyle(accent)
                                    Text(model.partial).font(.system(size: 17)).lineSpacing(7).foregroundStyle(.secondary)
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(30)
                    }.onChange(of: model.partial) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                     .onChange(of: model.finalText.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                     .onChange(of: model.translationTick) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                VStack(spacing: 14) {
                    if !model.error.isEmpty {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle")
                            Text(model.error).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { model.error = "" } label: { Image(systemName:"xmark") }.buttonStyle(.plain)
                        }.foregroundStyle(.orange).padding(12).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.state == "downloading" {
                        ProgressView(value: model.progress)
                        HStack { Text(model.progressLabel).lineLimit(1); Spacer(); Button("取消下载") { model.cancelDownload() } }.font(.caption)
                    }
                    HStack(spacing: 12) {
                        Circle().fill(model.recording ? .red : accent).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.statusTitle).font(.system(size: 13, weight: .medium))
                            if ["loading", "warming", "connecting"].contains(model.state) {
                                Text(model.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if model.liveEnabled {
                            Button { model.toggle() } label: {
                                Label(model.canStop ? "停止转写" : "开始转写", systemImage: model.canStop ? "stop.fill" : "mic.fill")
                            }.buttonStyle(.borderedProminent).tint(model.canStop ? .red : accent).disabled(!model.canStart && !model.canStop)
                        } else if ["idle", "error"].contains(model.state) {
                            Button("重新连接") { model.launch() }
                            Button(model.asrProvider == "api" ? "连接 API" : "加载模型") { model.load() }
                            if model.asrProvider == "local" {
                                Button("下载模型") { model.load(download: true) }.buttonStyle(.borderedProminent).tint(accent)
                            }
                        } else {
                            Button { model.toggle() } label: {
                                Label(model.canStop ? "停止转写" : "开始转写", systemImage: model.recording ? "stop.fill" : "mic.fill").padding(.horizontal, 14).padding(.vertical, 5)
                            }.buttonStyle(.borderedProminent).tint(model.recording ? .red : accent).disabled(!model.canStart && !model.canStop)
                        }
                    }
                    Text("⌃ ⌥ \(model.shortcutKey)  ·  \(model.holdToTalk ? "按住说话，松开停止" : "开始 / 停止")").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(24).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }.background(Color(nsColor: .textBackgroundColor))
        }.tint(accent).sheet(isPresented: $showAI) { AIWorkspaceView(ai: ai) }
            .onChange(of: model.liveEnabled) { _, enabled in if enabled { ai.cancel(); showAI = false } }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.liveEnabled { Text("当前由 LiveTranslate 同时完成转写与翻译。请前往 LiveTranslate 页管理；关闭该模式后恢复此处设置。").font(.callout).foregroundStyle(.secondary) }
            Group {
            Text("设置").font(.title2.bold())
            Picker("识别服务", selection: Binding(get: { model.asrProvider }, set: { model.setASRProvider($0) })) {
                Text("本地模型").tag("local")
                Text("API 服务").tag("api")
            }.disabled(model.inputBusy)
            if model.asrProvider == "local" {
                Picker("识别模型", selection: Binding(get: { model.preset }, set: { model.selectPreset($0) })) {
                    Text("Qwen3-ASR 1.7B").tag(AppModel.qwenID)
                    Text("Whisper Large v3 Turbo").tag(AppModel.whisperID)
                    Text("自定义模型…").tag("custom")
                }.disabled(model.busy)
                if model.preset == "custom" {
                    TextField("Hugging Face 模型 ID", text: Binding(get: { model.modelID }, set: { model.modelID = $0; model.revision = "" }))
                    HStack { TextField("本地目录（可选）", text: $model.localPath); Button("选择…") { model.chooseFolder() } }
                }
            } else {
                Group {
                Picker("API 类型", selection: Binding(get: { model.asrAPIProtocol }, set: { model.setASRAPIProtocol($0) })) {
                    Text("OpenAI 兼容音频转写").tag("openai")
                    Text("千问实时语音（Qwen Audio）").tag("qwen_realtime")
                }
                if model.qwenASR {
                    Picker("服务平台", selection: $model.qwenPlatform) {
                        ForEach(QwenRealtimeASRConfiguration.presets, id: \.1) { Text($0.0).tag($0.1) }
                        Text("自定义地址").tag("custom")
                    }
                }
                TextField(model.qwenASR ? "WebSocket 地址（wss://…/api-ws/v1/realtime）" : "Base URL，例如 https://api.openai.com/v1", text: $model.asrAPIBaseURL)
                    .textContentType(.URL)
                TextField(model.qwenASR ? "模型 ID，例如 qwen-audio-3.1-realtime-plus" : "音频转写模型 ID", text: $model.asrAPIModel)
                SecureField("API Key（留空使用已保存的密钥）", text: $model.asrAPIKeyInput)
                }.disabled(model.inputBusy)
                if model.qwenASR {
                    Text("选择签发 API Key 的平台（密钥只能用于同一平台和区域），也可粘贴平台的 https Base URL，会自动换成实时接口地址。填写 API Key 后点击「保存 / 启用」。停顿后提交语音片段，只显示输入语音的转写；不会请求模型回答或播放语音。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("测试连接") { model.testASRConnection() }.disabled(model.inputBusy)
                        if model.asrTesting { ProgressView().controlSize(.small) }
                    }
                    if !model.asrConnectionMessage.isEmpty { Text(model.asrConnectionMessage).font(.caption).textSelection(.enabled) }
                    Text("测试只建立并配置会话，不发送音频。转写时语音片段会发送到千问服务，可能产生费用；密钥存于钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Text("使用兼容 OpenAI /audio/transcriptions 的服务。加载后，语音片段会发送到此地址，可能产生费用；密钥保存在钥匙串，音频不存盘。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(model.qwenASR ? "保存 / 启用" : model.asrProvider == "api" ? "连接 / 切换" : "加载 / 切换") { model.load() }.buttonStyle(.borderedProminent)
                if model.asrProvider == "local" {
                    Button("下载模型") { model.load(download: true) }.disabled(!model.localPath.isEmpty)
                }
                Spacer()
                Text(model.statusTitle).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.asrTesting)
            if model.asrProvider == "local" {
                Text("首次使用先下载，之后可离线切换。").font(.caption).foregroundStyle(.secondary)
            }
            if model.state == "downloading" {
                ProgressView(value: model.progress)
                HStack { Text(model.progressLabel).font(.caption).lineLimit(1); Spacer(); Button("取消") { model.cancelDownload() } }
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Picker("语言", selection: $model.language) {
                Text("自动").tag("auto"); Text("中文").tag("Chinese"); Text("English").tag("English")
                Text("粤语").tag("Cantonese"); Text("日本語").tag("Japanese"); Text("한국어").tag("Korean")
            }.disabled(model.busy)
            Picker("快捷键：Control + Option +", selection: $model.shortcutKey) { Text("Space").tag("Space"); Text("R").tag("R"); Text("D").tag("D") }
            Toggle("按住说话", isOn: $model.holdToTalk)
            if !model.qwenASR {
            Picker("定稿方式", selection: $model.endpointMode) {
                Text("智能定稿（默认）").tag("smart")
                Text("固定停顿").tag("fixed")
            }.disabled(model.inputBusy)
            Text("智能模式结合停顿、句末标点和文字稳定性自动定稿；无需设置秒数。修改在下次转写时生效。").font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("停顿提交：\(Double(model.silence) / 1000, specifier: "%.2f") 秒", value: $model.silence, in: 300...2000, step: 20)
                    .disabled(model.inputBusy)
            }
            DisclosureGroup("高级", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.endpointMode == "fixed" && !model.qwenASR {
                        Stepper("停顿定稿：\(Double(model.silence) / 1000, specifier: "%.2f") 秒", value: $model.silence, in: 300...2000, step: 20)
                    }
                    if !model.qwenASR {
                    TextField("Revision（可选）", text: $model.revision)
                    Stepper("预览间隔：\(model.previewInterval) ms", value: $model.previewInterval, in: 800...10000, step: 200)
                    }
                    Text("语言和高级参数在加载后生效。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8).disabled(model.busy)
            }
            Button("麦克风权限…") { model.showPermissionSettings() }.buttonStyle(.link)
            }.disabled(model.liveEnabled)
        }
        .onChange(of: model.asrAPIBaseURL) { _, _ in
            model.asrAPIKeyInput = ""; model.asrConnectionMessage = ""
        }
        .onChange(of: model.asrAPIModel) { _, _ in model.asrConnectionMessage = "" }
    }
}

struct TranslationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profiles = AIProfiles.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.liveEnabled { Text("当前由 LiveTranslate 同时完成转写与翻译。请前往 LiveTranslate 页管理；关闭该模式后恢复此处设置。").font(.callout).foregroundStyle(.secondary) }
            Group {
            Text("实时翻译").font(.title2.bold())
            Picker("翻译服务", selection: Binding(get: { model.translationProvider }, set: { model.setTranslationProvider($0) })) {
                Text("本地模型").tag("local")
                Text("API 服务").tag("api")
            }.disabled(model.translatorBusy)
            Toggle("启用实时翻译", isOn: Binding(get: { model.translationEnabled }, set: { model.setTranslation(enabled: $0) }))
                .disabled(model.translatorBusy)
            Picker("目标语言", selection: Binding(get: { model.translationTarget }, set: { model.setTranslationTarget($0) })) {
                ForEach(AppModel.translationTargets, id: \.self) { Text($0).tag($0) }
            }
            Text("停顿定稿后逐句翻译，译文显示在原文下方；预览文字不翻译。服务、模型和目标语言的更改对之后定稿的句子生效。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.translationProvider == "api" {
                Picker("已保存 API 服务", selection: Binding(get: { model.translationAPIProfile }, set: { model.setTranslationAPIProfile($0) })) {
                    Text("请选择服务").tag("")
                    ForEach(profiles.profiles) { Text("\($0.baseURL) · \($0.modelID)").tag($0.id) }
                }
                if !profiles.profiles.contains(where: { $0.id == model.translationAPIProfile }) {
                    Text("请先在「AI 服务」页保存地址、模型和 API Key，再在这里选择。").font(.caption).foregroundStyle(.orange)
                }
                Text("开启后，定稿文本会发送到所选 API 服务并流式显示译文，可能产生服务商费用。录音和预览文字不会发送。选择与开关会自动保存。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("翻译模型", selection: Binding(get: { model.translatorPreset }, set: { model.selectTranslatorPreset($0) })) {
                    Text("Qwen3 4B Instruct（默认）").tag(AppModel.translatorQwenID)
                    Text("Hunyuan-MT 7B（翻译专用）").tag(AppModel.translatorHunyuanID)
                    Text("自定义模型…").tag("custom")
                }.disabled(model.translatorBusy)
                if model.translatorPreset == "custom" {
                    TextField("Hugging Face 模型 ID（MLX 格式）", text: Binding(get: { model.translatorModelID }, set: { model.translatorModelID = $0; model.translatorRevision = "" }))
                        .disabled(model.translatorBusy)
                }
                HStack {
                    Button("加载 / 切换") { model.loadTranslator() }.buttonStyle(.borderedProminent)
                    Button("下载翻译模型") { model.loadTranslator(download: true) }
                    Spacer()
                    Text(model.translatorStatusTitle).font(.caption).foregroundStyle(.secondary)
                }.disabled(model.translatorBusy)
                if model.translatorState == "downloading" {
                    ProgressView(value: model.translatorProgress)
                    HStack { Text(model.translatorProgressLabel).font(.caption).lineLimit(1); Spacer(); Button("取消") { model.cancelDownload() } }
                }
                if !model.translatorDetail.isEmpty {
                    Text(model.translatorDetail).font(.caption).foregroundStyle(model.translatorState == "error" ? Color.orange : Color.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("下载大小约：Qwen3 4B 2.3 GB，Hunyuan-MT 7B 4.2 GB。识别和翻译模型同时加载时，Qwen3 4B 需约 8 GB 以上可用内存，Hunyuan-MT 7B 需约 10 GB 以上。只有下载模型时联网。Hunyuan-MT 使用腾讯混元社区许可协议，使用前请确认其条款。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.disabled(model.liveEnabled)
        }
    }
}
