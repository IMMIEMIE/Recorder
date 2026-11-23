import Foundation

struct LiveServiceProfile: Codable, Equatable, Identifiable {
    var id = "qwen-default"
    var name = "Qwen LiveTranslate"
    var endpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    var modelID = "qwen3.8-livetranslate-flash-realtime"
    var protocolID = "qwen-livetranslate"
    var version = "3.8"
    var turnDetection = "server_vad"
    var threshold = 0.5
    var silenceMS = 1000
    var inputFormat = "pcm"

    func makeSession(clientFactory: () -> LiveTranslateClient) throws -> any LiveTranslationSession {
        try validate()
        return QwenLiveTranslationSession(client: clientFactory())
    }

    func validate() throws {
        guard protocolID == "qwen-livetranslate", version == "3.8", inputFormat == "pcm" else {
            throw AIError.message("此协议版本或上行音频格式尚不受支持")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AIError.message("请填写配置名称和有效的模型 ID")
        }
        guard ["server_vad", "speaker_detection"].contains(turnDetection),
              (0...1).contains(threshold), (1...60000).contains(silenceMS) else {
            throw AIError.message("请检查断句方式、阈值及静音时长")
        }
    }
    var detectionParameters: [String: Any] {
        if turnDetection == "speaker_detection" { return ["type": turnDetection] }
        return ["type": turnDetection, "threshold": threshold, "silence_duration_ms": silenceMS]
    }
}

struct LiveServiceCatalog: Codable, Equatable {
    private(set) var selectedID: String
    private(set) var profiles: [LiveServiceProfile]
    init(_ profile: LiveServiceProfile = .init()) {
        selectedID = profile.id
        profiles = [profile]
    }
    var selected: LiveServiceProfile { profiles.first { $0.id == selectedID }! }

    mutating func use(_ profile: LiveServiceProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        selectedID = profile.id
    }
    enum CodingKeys: String, CodingKey { case selectedID, profiles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedID = try c.decode(String.self, forKey: .selectedID)
        profiles = try c.decode([LiveServiceProfile].self, forKey: .profiles)
        let ids = Set(profiles.map(\.id))
        guard ids.contains(selectedID), ids.count == profiles.count else {
            throw DecodingError.dataCorruptedError(forKey: .selectedID, in: c, debugDescription: "Invalid profile selection")
        }
    }
}
