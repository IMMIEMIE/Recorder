import SwiftUI

@main
struct RecorderApp: App {
    @StateObject private var model = AppModel()
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
    var body: some Scene {
        WindowGroup(Text(verbatim: interface.string("声笺 · 实时转写")), id: "main") {
            MainView(model: model)
                .frame(minWidth: 1000, minHeight: 570)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .environment(\.locale, interface.locale)
        .defaultSize(width: 1280, height: 720)
        Settings {
            TabView {
                ScrollView { SettingsView(model: model).padding(24) }.tabItem { Label("转写", systemImage: "waveform") }
                ScrollView { TranslationSettingsView(model: model).padding(24) }.tabItem { Label("翻译", systemImage: "character.bubble") }
                ScrollView { LiveTranslateSettingsView(model: model).padding(24) }.tabItem { Label("LiveTranslate", systemImage: "globe") }
                AISettingsView().tabItem { Label("AI 服务", systemImage: "sparkles") }
                ScrollView { SessionSettingsView(model: model).padding(24) }.tabItem { Label("会话记录", systemImage: "clock.arrow.circlepath") }
            }.frame(minWidth: 640, idealWidth: 680, minHeight: 600).tint(DesignTokens.primary)
        }
        .environment(\.locale, interface.locale)
        MenuBarExtra(interface.string("声笺"), systemImage: model.recording ? (AudioInputSource(rawValue: model.audioSource) ?? .microphone).systemImage : "waveform") {
            MenuContent(model: model)
        }
        .environment(\.locale, interface.locale)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(LocalizedStringKey(model.statusTitle))
        Button(model.canStop ? "停止转写" : model.continuesSession ? "继续录制" : "开始转写") { model.toggle() }
            .disabled(!model.canStop && !model.canStart)
        Menu {
            ForEach(AudioInputSource.liveModes, id: \.rawValue) { mode in
                Toggle(LocalizedStringKey(mode.titleKey), isOn: Binding(
                    get: { model.audioSource == mode.rawValue },
                    set: { if $0 { model.setAudioSource(mode.rawValue) } }
                ))
            }
        } label: {
            Text("音频输入：\(interface.string(model.audioSourceTitle))")
        }
        .disabled(model.inputBusy)
        Button("显示转写窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("字幕模式", isOn: Binding(get: { model.subtitleMode }, set: { model.setSubtitleMode($0) }))
        Button("导出会话…") {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            model.exportRequest = SessionExportRequest(sessionID: nil)
        }.disabled(!model.displayedHasText)
        Button("复制文字") { model.copyText() }.disabled(!model.displayedHasText)
        Divider()
        Button("退出声笺") { model.shutdown(); NSApp.terminate(nil) }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
    @State private var floating = false
    @State private var showAI = false
    @StateObject private var ai = AIWorkspace()
    private let accent = DesignTokens.primary
    var body: some View {
        NavigationSplitView {
            SessionSidebar(model: model)
                .tint(accent)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            workspace
        }
        .sheet(item: $model.exportRequest) { request in SessionExportSheet(model: model, request: request) }
    }

    private var workspace: some View {
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
                    Picker("音源", selection: Binding(get: { model.audioSource }, set: { model.setAudioSource($0) })) {
                        Text("麦克风").tag(AudioInputSource.microphone.rawValue)
                        Text("系统声音").tag(AudioInputSource.system.rawValue)
                        Text("系统声音 + 麦克风").tag(AudioInputSource.systemMix.rawValue)
                        Text("音频文件").tag(AudioInputSource.file.rawValue)
                    }.disabled(model.inputBusy)
                    if model.audioSource == AudioInputSource.microphone.rawValue || model.audioSource == AudioInputSource.systemMix.rawValue {
                        Picker("麦克风", selection: $model.device) {
                            Text("系统默认麦克风").tag(UInt32(0))
                            ForEach(model.microphones) { Text($0.name).tag($0.id) }
                        }.labelsHidden().disabled(model.inputBusy)
                        HStack(spacing: 6) {
                            Circle().fill(model.permission == "已允许" ? accent : DesignTokens.slow).frame(width: 6, height: 6)
                            Text("麦克风权限：\(interface.string(model.permission))").font(.caption2).foregroundStyle(.secondary)
                            if model.permission == "未允许" {
                                Button("前往系统设置") { model.showPermissionSettings() }.buttonStyle(.link).font(.caption2)
                            }
                        }
                    }
                    if model.audioSource == AudioInputSource.system.rawValue || model.audioSource == AudioInputSource.systemMix.rawValue {
                        HStack(spacing: 6) {
                            Circle().fill(model.screenCaptureAuthorized ? accent : DesignTokens.slow).frame(width: 6, height: 6)
                            Text("屏幕与系统音频：\(interface.string(model.screenCapturePermission))").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !model.screenCaptureAuthorized {
                            Button("前往系统设置") { model.showScreenCapturePermissionSettings() }
                                .buttonStyle(.link).font(.caption2)
                        }
                        if model.audioSource == AudioInputSource.system.rawValue {
                            Text("采集其他应用播放的声音，不使用麦克风。首次使用需允许屏幕与系统音频录制权限。").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("同时采集系统声音与所选麦克风，适合线上会议；声笺自身译音不会被回环收录。").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if model.audioSource == AudioInputSource.file.rawValue {
                        Button("选择音频文件…") { model.chooseAudioFile() }.disabled(model.inputBusy)
                        Text(model.audioFileURL?.lastPathComponent ?? interface.string("尚未选择文件")).font(.caption).lineLimit(2)
                        Text("按原始语速转写，不播放声音；文件结束后自动处理尾句。").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<24) { i in Capsule().fill(Float(i)/24 < model.level ? accent : accent.opacity(0.12)).frame(height: 5 + CGFloat(i % 4) * 3) }
                    }.frame(height: 22)
                    if model.audioSource == AudioInputSource.microphone.rawValue || model.audioSource == AudioInputSource.systemMix.rawValue {
                        Button("刷新设备") { model.refreshDevices() }.buttonStyle(.link).font(.caption)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("识别模型").font(.caption).foregroundStyle(.secondary)
                    Text(model.activeModelName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text("实时翻译").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    Text(model.translationSummary).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .foregroundStyle(model.translatorState == "error" ? DesignTokens.error : DesignTokens.onSurface)
                    SettingsLink { Label("设置", systemImage: "slider.horizontal.3") }.buttonStyle(.link).font(.caption)
                }
                Spacer()

            }.padding(24).frame(width: 255).frame(maxHeight: .infinity).background(DesignTokens.surfaceContainerLow)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    displayedTitle.font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        .help(displayedTitle)
                    Spacer()
                    Button { model.setSubtitleMode(!model.subtitleMode) } label: { Image(systemName: model.subtitleMode ? "captions.bubble.fill" : "captions.bubble") }
                        .help(model.subtitleMode ? "关闭字幕模式" : "打开字幕模式").accessibilityLabel("字幕模式")
                    Button { floating.toggle(); NSApp.keyWindow?.level = floating ? .floating : .normal } label: { Image(systemName: floating ? "pin.fill" : "pin") }.help("窗口置顶").accessibilityLabel("窗口置顶")
                    TranslationMenu(model: model).equatable()
                        .help(Text(model.translationSummary))
                    Button { ai.prepare(text: model.joinedText, recordingID: model.viewedSession?.id ?? model.activeSessionID); showAI = true } label: { Label("AI 提问", systemImage: "sparkles") }
                        .disabled(!model.displayedHasText || model.liveEnabled)
                    if model.livePlaying { Button("停止译音", systemImage: "speaker.slash") { model.stopLivePlayback() } }
                    Button { model.exportRequest = SessionExportRequest(sessionID: nil) } label: { Label("导出会话…", systemImage: "square.and.arrow.up") }
                        .disabled(!model.displayedHasText).help("将此会话的已定稿文字导出为 TXT 或 Markdown")
                    Button { model.copyText() } label: { Label("复制", systemImage: "doc.on.doc") }.disabled(!model.displayedHasText)
                }.buttonStyle(ToolbarActionStyle()).menuStyle(.borderedButton)
                .padding(.horizontal, 24).padding(.vertical, 14)
                if let viewed = model.viewedSession, model.recordingSessionID != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle").foregroundStyle(DesignTokens.recording)
                        Text("正在查看「\(viewed.title)」；新内容仍写入正在录制的会话。").font(.caption).lineLimit(2)
                        Spacer()
                        Button("回到录制中的会话") { model.selectSession(model.activeSessionID) }.font(.caption)
                    }.padding(.horizontal, 24).padding(.vertical, 8).background(DesignTokens.recording.opacity(0.06))
                }
                Divider().padding(.horizontal, 30)
                TranscriptList(model: model, accent: accent)
                VStack(spacing: 14) {
                    if model.liveServiceSlow && model.recording { SlowLiveServiceView(model: model) }
                    if !model.error.isEmpty {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle")
                            Text(verbatim: interface.localizeMessage(model.error)).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { model.error = "" } label: { Image(systemName:"xmark") }.buttonStyle(.plain)
                        }.foregroundStyle(DesignTokens.onErrorContainer).padding(12).background(DesignTokens.errorContainer, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.state == "downloading" {
                        ProgressView(value: model.progress)
                        HStack { Text(model.progressLabel).lineLimit(1); Spacer(); Button("取消下载") { model.cancelDownload() } }.font(.caption)
                    }
                    AudioSourceModeBar(model: model, accent: accent)
                    HStack(spacing: 12) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey(model.statusTitle)).font(.system(size: 13, weight: .medium))
                            if ["loading", "warming", "connecting", "finalizing"].contains(model.state) || (model.liveEnabled && model.state == "idle") {
                                Text(verbatim: interface.localizeMessage(model.detail)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if model.liveEnabled {
                            if model.canLoadHyModel { Button("加载模型") { model.loadHyModel() } }
                            Button { model.toggle() } label: {
                                Label(model.canStop ? "停止实时翻译" : model.continuesSession ? "继续录制" : "开始实时翻译", systemImage: model.canStop ? "stop.fill" : "mic.fill")
                            }.buttonStyle(.borderedProminent).tint(model.canStop ? DesignTokens.recording : accent).disabled(!model.canStart && !model.canStop)
                        } else if ["idle", "error"].contains(model.state) {
                            Button("重新连接") { model.launch() }
                            Button(model.asrProvider == "api" ? "连接 API" : "加载模型") { model.load() }
                            if model.asrProvider == "local" {
                                Button("下载模型") { model.load(download: true) }.buttonStyle(.borderedProminent).tint(accent)
                            }
                        } else {
                            Button { model.toggle() } label: {
                                Label(model.canStop ? "停止转写" : model.continuesSession ? "继续录制" : "开始转写", systemImage: model.recording ? "stop.fill" : "mic.fill").padding(.horizontal, 14).padding(.vertical, 5)
                            }.buttonStyle(.borderedProminent).tint(model.recording ? DesignTokens.recording : accent).disabled(!model.canStart && !model.canStop)
                        }
                    }
                    Text("⌃ ⌥ \(model.shortcutKey)  ·  \(interface.string(model.holdToTalk ? "按住说话，松开停止" : "开始 / 停止"))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(24).background(DesignTokens.surfaceContainerLow.opacity(0.5))
            }.background(DesignTokens.surface)
        }.tint(accent).sheet(isPresented: $showAI) { AIWorkspaceView(ai: ai) }
            .onChange(of: model.liveEnabled) { _, enabled in if enabled { ai.cancel(); showAI = false } }
    }

    private var displayedTitle: Text {
        model.selectedSessionID == nil ? Text("新会话") : Text(verbatim: model.displayedTitle)
    }

    private var statusColor: Color {
        switch model.state {
        case "error": DesignTokens.error
        case "connecting", "reconnecting", "loading", "warming", "finalizing": DesignTokens.connecting
        default: model.recording ? DesignTokens.recording : DesignTokens.complete
        }
    }
}

private struct AudioSourceModeBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
    let accent: Color

    private var needsScreenPermission: Bool {
        !model.screenCaptureAuthorized
            && (model.audioSource == AudioInputSource.system.rawValue || model.audioSource == AudioInputSource.systemMix.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(AudioInputSource.liveModes, id: \.rawValue) { mode in
                        let selected = model.audioSource == mode.rawValue
                        Button {
                            model.setAudioSource(mode.rawValue)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: mode.systemImage).font(.system(size: 11, weight: .medium))
                                Text(LocalizedStringKey(mode.titleKey)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? DesignTokens.onPrimary : DesignTokens.onSurfaceVariant)
                            .background {
                                if selected {
                                    Capsule().fill(accent)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(DesignTokens.surfaceContainerHigh, in: Capsule())
                .disabled(model.inputBusy)
                .opacity(model.inputBusy ? 0.6 : 1)
                .help(model.inputBusy ? Text("录制中不可切换音频输入") : Text("切换音频输入模式"))

                if model.audioSource == AudioInputSource.file.rawValue {
                    HStack(spacing: 4) {
                        Image(systemName: AudioInputSource.file.systemImage).font(.caption2)
                        Text("音频文件").font(.caption2)
                    }
                    .foregroundStyle(DesignTokens.onSecondaryContainer)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DesignTokens.secondaryContainer, in: Capsule())
                }

                Spacer()

                if needsScreenPermission {
                    HStack(spacing: 6) {
                        Circle().fill(DesignTokens.slow).frame(width: 6, height: 6)
                        Text("屏幕与系统音频：\(interface.string(model.screenCapturePermission))")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.slow)
                        Button("前往系统设置") { model.showScreenCapturePermissionSettings() }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
            }

            if model.shouldShowEchoHint {
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.caption2)
                    Text("建议佩戴耳机，避免扬声器外放被麦克风重复收录。").font(.caption2)
                }
                .foregroundStyle(DesignTokens.onSurfaceVariant)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InterfaceLanguagePicker(settings: .shared)
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
                    Text("WebSocket 调用").tag("qwen_realtime")
                }
                if model.streamingASR {
                    LabeledContent("模型", value: StreamingASRConfiguration.model)
                } else {
                    TextField("Base URL，例如 https://api.openai.com/v1", text: $model.asrAPIBaseURL)
                        .textContentType(.URL)
                    TextField("音频转写模型 ID", text: $model.asrAPIModel)
                }
                SecureField("API Key（留空使用已保存的密钥）", text: $model.asrAPIKeyInput)
                }.disabled(model.inputBusy)
                if model.streamingASR {
                    Text("固定使用千问AI平台的流式识别模型，只需填写该平台的 API Key，然后点击「保存 / 启用」。录音时音频持续发送到服务端，边说边出字，停顿后由服务端定稿整句。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("测试连接") { model.testASRConnection() }.disabled(model.inputBusy)
                        if model.asrTesting { ProgressView().controlSize(.small) }
                    }
                    if !model.asrConnectionMessage.isEmpty { Text(verbatim: interface.localizeMessage(model.asrConnectionMessage)).font(.caption).textSelection(.enabled) }
                    Text("测试只启动识别任务，不发送音频。转写时全部音频会发送到该服务，按音频时长计费；密钥仅保存在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Text("使用兼容 OpenAI /audio/transcriptions 的服务。加载后，语音片段会发送到此地址，可能产生费用；密钥仅保存在本机，音频不存盘。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(model.streamingASR ? "保存 / 启用" : model.asrProvider == "api" ? "连接 / 切换" : "加载 / 切换") { model.load() }.buttonStyle(.borderedProminent)
                if model.asrProvider == "local" {
                    Button("下载模型") { model.load(download: true) }.disabled(!model.localPath.isEmpty)
                }
                Spacer()
                Text(LocalizedStringKey(model.statusTitle)).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.asrTesting)
            if model.asrProvider == "local" {
                Text("首次使用先下载，之后可离线切换。").font(.caption).foregroundStyle(.secondary)
            }
            if model.state == "downloading" {
                ProgressView(value: model.progress)
                HStack { Text(model.progressLabel).font(.caption).lineLimit(1); Spacer(); Button("取消") { model.cancelDownload() } }
            }
            if !model.error.isEmpty { Text(verbatim: interface.localizeMessage(model.error)).font(.caption).foregroundStyle(DesignTokens.error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Picker("识别语言", selection: $model.language) {
                Text("自动").tag("auto"); Text("中文").tag("Chinese"); Text("English").tag("English")
                Text("粤语").tag("Cantonese"); Text("日本語").tag("Japanese"); Text("한국어").tag("Korean")
            }.disabled(model.busy)
            Picker("快捷键：Control + Option +", selection: $model.shortcutKey) { Text("Space").tag("Space"); Text("R").tag("R"); Text("D").tag("D") }
            Toggle("按住说话", isOn: $model.holdToTalk)
            if !model.streamingASR {
            Picker("定稿方式", selection: $model.endpointMode) {
                Text("智能定稿（默认）").tag("smart")
                Text("固定停顿").tag("fixed")
            }.disabled(model.inputBusy)
            Text("智能模式结合停顿、句末标点和文字稳定性自动定稿；无需设置秒数。修改在下次转写时生效。").font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("停顿定稿：\(Double(model.silence) / 1000, specifier: "%.2f") 秒", value: $model.silence, in: 300...2000, step: 20)
                    .disabled(model.inputBusy)
            }
            DisclosureGroup("高级", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.endpointMode == "fixed" && !model.streamingASR {
                        Stepper("停顿定稿：\(Double(model.silence) / 1000, specifier: "%.2f") 秒", value: $model.silence, in: 300...2000, step: 20)
                    }
                    if !model.streamingASR {
                    TextField("Revision（可选）", text: $model.revision)
                    Stepper("预览间隔：\(model.previewInterval) ms", value: $model.previewInterval, in: 800...10000, step: 200)
                    }
                    Text("语言和高级参数在加载后生效。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8).disabled(model.busy)
            }
            HStack(spacing: 16) {
                Button("麦克风权限…") { model.showPermissionSettings() }.buttonStyle(.link)
                Button("屏幕与系统音频权限…") { model.showScreenCapturePermissionSettings() }.buttonStyle(.link)
            }
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
    @ObservedObject private var interface = InterfaceLanguageSettings.shared
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
                    Text("请先在「AI 服务」页保存地址、模型和 API Key，再在这里选择。").font(.caption).foregroundStyle(DesignTokens.slow)
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
                    Text(LocalizedStringKey(model.translatorStatusTitle)).font(.caption).foregroundStyle(.secondary)
                }.disabled(model.translatorBusy)
                if model.translatorState == "downloading" {
                    ProgressView(value: model.translatorProgress)
                    HStack { Text(model.translatorProgressLabel).font(.caption).lineLimit(1); Spacer(); Button("取消") { model.cancelDownload() } }
                }
                if !model.translatorDetail.isEmpty {
                    Text(verbatim: interface.localizeMessage(model.translatorDetail)).font(.caption).foregroundStyle(model.translatorState == "error" ? DesignTokens.error : DesignTokens.onSurfaceVariant)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("下载大小约：Qwen3 4B 2.3 GB，Hunyuan-MT 7B 4.2 GB。识别和翻译模型同时加载时，Qwen3 4B 需约 8 GB 以上可用内存，Hunyuan-MT 7B 需约 10 GB 以上。只有下载模型时联网。Hunyuan-MT 使用腾讯混元社区许可协议，使用前请确认其条款。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.error.isEmpty { Text(verbatim: interface.localizeMessage(model.error)).font(.caption).foregroundStyle(DesignTokens.error).textSelection(.enabled) }
            }.disabled(model.liveEnabled)
        }
    }
}
