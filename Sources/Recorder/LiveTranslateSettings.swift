import SwiftUI

struct LiveTranslateSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("LiveTranslate").font(.title2.bold())
            Toggle("使用 LiveTranslate 独立转写与翻译", isOn: Binding(get: { model.liveEnabled }, set: { model.setLiveEnabled($0) }))
                .disabled(model.liveSettingsBusy)
            Text("启用后，由 Qwen3.8 LiveTranslate 同时生成原文和译文，无需加载其他识别或翻译模型。")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("模型") { Text(LiveTranslateConfiguration.model).font(.caption).textSelection(.enabled) }
            Group {
                LabeledContent("服务地址") { TextField("wss://…/api-ws/v1/realtime", text: $model.liveEndpoint) }
                LabeledContent("专用 API Key") { SecureField("留空保留此地址已保存的密钥", text: $model.liveKeyInput) }
                Picker("目标语言", selection: $model.liveLanguage) {
                    ForEach(LiveTranslateConfiguration.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("播放译音", isOn: $model.liveAudioOutput)
                if model.liveAudioOutput {
                    Picker("播放时机", selection: $model.livePlaybackTiming) {
                        ForEach(LiveTranslatePlaybackTiming.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(model.livePlaybackTiming == .streaming
                         ? "译音生成后立即播放，可一边说话一边听翻译。"
                         : "按句等待原文和译文定稿、该句译音生成完整后再播放；不必等整场录音结束。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("译音音量")
                        Slider(value: $model.liveVolume, in: 0...1)
                        Text("\(Int(model.liveVolume * 100))%").monospacedDigit().frame(width: 42)
                    }
                    Text("通过系统当前的扬声器或耳机播放，保存后在下次会话生效。麦克风模式建议戴耳机，避免译音被再次收录。音频输出可能增加服务费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存") { model.saveLiveSettings() }.buttonStyle(.borderedProminent)
                    Button("测试连接") { model.testLiveConnection() }.disabled(model.inputBusy)
                    if model.liveTesting { ProgressView().controlSize(.small) }
                }
            }.disabled(model.liveSettingsBusy)
            if model.livePlaying { Button("停止本次译音播放") { model.stopLivePlayback() } }
            Text("地址、目标语言、音频输出设置和开关会保存到本机。密钥独立存于系统钥匙串；切换地址时需配置该地址对应的密钥。修改后点击保存生效。")
                .font(.caption).foregroundStyle(.secondary)
            Text("开始转写后，所选音源的音频会发送到该云端服务，可能产生费用；应用不保存录音。测试连接只建立会话，不采集或发送音频。")
                .font(.caption).foregroundStyle(.secondary)
            Text("始终显示原文＋译文字幕，可选播放译音。中文使用服务的 zh 选项，不进行简繁转换。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.liveMessage.isEmpty { Text(model.liveMessage).font(.caption).textSelection(.enabled) }
            Divider()
            Picker("快捷键：Control + Option +", selection: $model.shortcutKey) {
                Text("Space").tag("Space"); Text("R").tag("R"); Text("D").tag("D")
            }
            Toggle("按住说话", isOn: $model.holdToTalk)
        }.textFieldStyle(.roundedBorder)
            .onChange(of: model.liveEndpoint) { _, _ in model.liveKeyInput = "" }
    }
}
