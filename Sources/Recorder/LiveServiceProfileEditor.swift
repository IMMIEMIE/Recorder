import AppKit
import SwiftUI

struct LiveServiceProfileEditor: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let profiles = model.liveConfiguration.catalog.profiles
        HStack {
            Picker("服务配置", selection: Binding(get: { model.liveProfile.id }, set: model.selectLiveProfile)) {
                ForEach(profiles) { Text($0.name).tag($0.id) }
                if !profiles.contains(where: { $0.id == model.liveProfile.id }) { Text("新配置").tag(model.liveProfile.id) }
            }
            Button("新建") {
                model.liveProfile = LiveServiceProfile(id: UUID().uuidString, name: InterfaceLanguageSettings.shared.string("新配置"))
                model.liveMessage = ""
            }
        }
        LabeledContent("配置名称") { TextField("名称", text: $model.liveProfile.name) }
        Picker("协议", selection: Binding(
            get: { model.liveProfile.protocolID },
            set: { model.liveProfile = model.liveProfile.switchingProtocol(to: $0) }
        )) {
            Text(verbatim: "Qwen LiveTranslate 3.8").tag(LiveServiceProfile.qwenProtocolID)
            Text(verbatim: "Gemini Live 1.0").tag(LiveServiceProfile.geminiProtocolID)
            if ![LiveServiceProfile.qwenProtocolID, LiveServiceProfile.geminiProtocolID].contains(model.liveProfile.protocolID) {
                Text(verbatim: model.liveProfile.protocolID + " · " + model.liveProfile.version).tag(model.liveProfile.protocolID)
            }
        }
        LabeledContent("服务地址") {
            TextField(
                model.liveProfile.isGeminiLive ? "wss://generativelanguage.googleapis.com/ws/…" : "wss://…/api-ws/v1/realtime",
                text: $model.liveProfile.endpoint
            )
        }
        LabeledContent("模型 ID") { TextField("模型 ID", text: $model.liveProfile.modelID) }
        DisclosureGroup("断句和上行音频") {
            if !model.liveProfile.isGeminiLive {
                Picker("断句方式", selection: $model.liveProfile.turnDetection) {
                    Text("静音检测").tag("server_vad")
                    Text("说话人检测").tag("speaker_detection")
                }
                if model.liveProfile.turnDetection == "server_vad" {
                    LabeledContent("阈值") { TextField("0.5", value: $model.liveProfile.threshold, format: .number) }
                    LabeledContent("静音时长（毫秒）") { TextField("1000", value: $model.liveProfile.silenceMS, format: .number) }
                }
            }
            LabeledContent("上行音频") { Text("PCM16 · 16 kHz · 单声道") }
            Button("复制已保存的探针配置") {
                guard let data = try? JSONEncoder().encode(model.liveConfiguration),
                      let text = String(data: data, encoding: .utf8) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

struct SlowLiveServiceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("「\(model.liveConfiguration.profile.name)」服务处理较慢，字幕可能延迟。")
            ForEach(model.liveConfiguration.catalog.profiles.filter { $0.id != model.liveConfiguration.profile.id }) { profile in
                Button("切换到「\(profile.name)」") { model.switchRecordingProfile(profile) }
            }
        }
    }
}
