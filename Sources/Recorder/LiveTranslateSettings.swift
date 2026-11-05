import SwiftUI

struct LiveTranslateSettingsView: View {
    @ObservedObject var model: AppModel
    /// Local mode has no address or key to draft, so its choices apply as they change.
    private struct LocalChoices: Equatable {
        var language: String
        var audioOutput: Bool
        var volume: Float
        var timing: LiveTranslatePlaybackTiming
    }
    private var local: Bool { model.liveProvider == .hyLocal }
    private var languages: [(String, String)] { local ? [("zh", "中文"), ("en", "English")] : LiveTranslateConfiguration.languages }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("LiveTranslate").font(.title2.bold())
            Toggle("使用 LiveTranslate 独立转写与翻译", isOn: Binding(get: { model.liveEnabled }, set: { model.setLiveEnabled($0) }))
                .toggleStyle(.switch).disabled(model.liveSettingsBusy)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("使用本地模型 Hy-SimulMT", isOn: Binding(get: { local }, set: { model.setLiveProvider($0 ? .hyLocal : .qwenCloud) }))
                    .toggleStyle(.switch)
                    // An unverified build can still leave local mode, but cannot enter it.
                    .disabled(model.liveSettingsBusy || (!local && !model.hyRuntimeVerified))
                Text(model.hyRuntimeVerified ? (local ? "音频和文字都留在本机，不访问云端。" : "关闭时使用云端 Qwen LiveTranslate。") : model.hyRuntimeUnavailableReason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if local {
                    Text("由本机 Hy-SimulMT Interleave 同时生成原文和译文，支持中英互译。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("模型") { Text("Hy-SimulMT Interleave Q4_K_M").font(.caption) }
                    Text(model.hyModelStore.detail).font(.caption).textSelection(.enabled)
                    if model.hyModelStore.isBusy { ProgressView(value: model.hyModelStore.progress) }
                    HStack {
                        Button("下载本地模型") { model.downloadHyModel() }
                            .disabled(!model.hyRuntimeVerified || model.hyModelStore.isBusy || model.hyRuntimeState == "loading" || model.hyRuntimeState == "ready"
                                      || (model.hyModelStore.hasCachedFile && model.hyModelStore.state != "error"))
                        if model.hyModelStore.isBusy { Button("取消") { model.hyModelStore.cancel() } }
                        Button("加载模型") { model.loadHyModel() }.buttonStyle(.borderedProminent)
                            .disabled(!model.canLoadHyModel)
                        Button("卸载模型") { model.unloadHyModel() }
                            .disabled(!["loading", "ready", "error"].contains(model.hyRuntimeState))
                    }
                    Text(model.hyRuntimeDetail).font(.caption).foregroundStyle(.secondary)
                    if model.hyRuntimeState == "loading" { ProgressView().controlSize(.small) }
                    Text("首次需下载约 19.75 GB 模型，运行时约占用 23 GB 内存。打开上方两个开关会加载已下载的模型；重新打开应用后，在主窗口点击「加载模型」。卸载会释放内存。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.hyMemoryIsLow {
                        Text("本机内存较小，打开开关时不会自动加载；手动加载可能严重变慢。").font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("启用后，由 Qwen3.8 LiveTranslate 同时生成原文和译文，无需加载其他识别或翻译模型。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("模型") { Text(LiveTranslateConfiguration.model).font(.caption).textSelection(.enabled) }
                    LabeledContent("服务地址") { TextField("wss://…/api-ws/v1/realtime", text: $model.liveEndpoint) }
                    LabeledContent("专用 API Key") { SecureField("留空保留此地址已保存的密钥", text: $model.liveKeyInput) }
                }
                Picker("目标语言", selection: $model.liveLanguage) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                if local {
                    Text(model.liveLanguage == "zh" ? "英语语音 → 中文译文" : "中文语音 → 英文译文")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("播放译音", isOn: $model.liveAudioOutput).toggleStyle(.switch)
                if model.liveAudioOutput {
                    Picker("播放时机", selection: $model.livePlaybackTiming) {
                        ForEach(LiveTranslatePlaybackTiming.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(local
                         ? (model.livePlaybackTiming == .streaming ? "使用 macOS 系统语音，已确认的译文短句生成后立即朗读。" : "使用 macOS 系统语音，等待每句译文定稿后朗读。")
                         : (model.livePlaybackTiming == .streaming ? "译音生成后立即播放，可一边说话一边听翻译。" : "按句等待原文和译文定稿、该句译音生成完整后再播放；不必等整场录音结束。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("译音音量")
                        Slider(value: $model.liveVolume, in: 0...1)
                        Text("\(Int(model.liveVolume * 100))%").monospacedDigit().frame(width: 42)
                    }
                    Text(local ? "通过系统当前的扬声器或耳机播放。需要对应语言的系统语音；麦克风模式建议戴耳机，避免译音被再次收录。"
                         : "通过系统当前的扬声器或耳机播放，保存后在下次会话生效。麦克风模式建议戴耳机，避免译音被再次收录。音频输出可能增加服务费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !local { Button("保存") { model.saveLiveSettings() }.buttonStyle(.borderedProminent) }
                    Button(local ? "测试本地会话" : "测试连接") { model.testLiveConnection() }
                        .disabled(model.inputBusy || (local && model.hyRuntimeState != "ready"))
                    if model.liveTesting { ProgressView().controlSize(.small) }
                }
            }.disabled(model.liveSettingsBusy)
            if model.livePlaying { Button("停止本次译音播放") { model.stopLivePlayback() } }
            Text(local ? "目标语言和音频输出修改后立即保存到本机，下次会话生效。模型单独缓存，不随应用打包；测试本地会话不采集音频。"
                 : "地址、目标语言、音频输出设置和开关会保存到本机。密钥独立存于系统钥匙串；切换地址时需配置该地址对应的密钥。修改后点击保存生效。")
                .font(.caption).foregroundStyle(.secondary)
            if !local {
                Text("开始转写后，所选音源的音频会发送到该云端服务，可能产生费用；应用不保存录音。测试连接只建立会话，不采集或发送音频。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("始终显示原文＋译文字幕，可选播放译音。中文使用服务的 zh 选项，不进行简繁转换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.liveMessage.isEmpty { Text(model.liveMessage).font(.caption).textSelection(.enabled) }
            Divider()
            Picker("快捷键：Control + Option +", selection: $model.shortcutKey) {
                Text("Space").tag("Space"); Text("R").tag("R"); Text("D").tag("D")
            }
            Toggle("按住说话", isOn: $model.holdToTalk)
        }.textFieldStyle(.roundedBorder)
            .onChange(of: model.liveEndpoint) { _, _ in model.liveKeyInput = "" }
            .onChange(of: LocalChoices(language: model.liveLanguage, audioOutput: model.liveAudioOutput,
                                       volume: model.liveVolume, timing: model.livePlaybackTiming)) { _, _ in
                if local { model.saveLiveSettings() }
            }
            .task(id: model.liveProvider) { if local { model.hyModelStore.inspectCache() } }
    }
}
