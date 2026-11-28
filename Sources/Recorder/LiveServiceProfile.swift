import Foundation

struct LiveServiceProfile: Codable, Equatable, Identifiable {
    static let qwenProtocolID = "qwen-livetranslate"
    static let qwenVersion = "3.8"
    static let qwenDefaultEndpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    static let qwenDefaultModelID = "qwen3.8-livetranslate-flash-realtime"

    static let geminiProtocolID = GeminiLiveProtocol.protocolID
    static let geminiVersion = GeminiLiveProtocol.version
    static let geminiDefaultEndpoint = GeminiLiveProtocol.defaultEndpoint
    static let geminiDefaultModelID = GeminiLiveProtocol.defaultModelID

    var id = "qwen-default"
    var name = "Qwen LiveTranslate"
    var endpoint = LiveServiceProfile.qwenDefaultEndpoint
    var modelID = LiveServiceProfile.qwenDefaultModelID
    var protocolID = LiveServiceProfile.qwenProtocolID
    var version = LiveServiceProfile.qwenVersion
    var turnDetection = "server_vad"
    var threshold = 0.5
    var silenceMS = 1000
    var inputFormat = "pcm"

    var isGeminiLive: Bool { protocolID == Self.geminiProtocolID }

    init(id: String = "qwen-default",
         name: String = "Qwen LiveTranslate",
         endpoint: String = LiveServiceProfile.qwenDefaultEndpoint,
         modelID: String = LiveServiceProfile.qwenDefaultModelID,
         protocolID: String = LiveServiceProfile.qwenProtocolID,
         version: String = LiveServiceProfile.qwenVersion,
         turnDetection: String = "server_vad",
         threshold: Double = 0.5,
         silenceMS: Int = 1000,
         inputFormat: String = "pcm") {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.modelID = modelID
        self.protocolID = protocolID
        self.version = version
        self.turnDetection = turnDetection
        self.threshold = threshold
        self.silenceMS = silenceMS
        self.inputFormat = inputFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        modelID = try c.decode(String.self, forKey: .modelID)
        protocolID = try c.decode(String.self, forKey: .protocolID)
        version = try c.decode(String.self, forKey: .version)
        turnDetection = try c.decodeIfPresent(String.self, forKey: .turnDetection) ?? "server_vad"
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.5
        silenceMS = try c.decodeIfPresent(Int.self, forKey: .silenceMS) ?? 1000
        inputFormat = try c.decodeIfPresent(String.self, forKey: .inputFormat) ?? "pcm"
    }

    func switchingProtocol(to targetProtocolID: String) -> LiveServiceProfile {
        var next = self
        let targetIsGemini = targetProtocolID == Self.geminiProtocolID
        let targetVersion = targetIsGemini ? Self.geminiVersion : Self.qwenVersion
        let targetEndpoint = targetIsGemini ? Self.geminiDefaultEndpoint : Self.qwenDefaultEndpoint
        let targetModel = targetIsGemini ? Self.geminiDefaultModelID : Self.qwenDefaultModelID
        let otherEndpoint = targetIsGemini ? Self.qwenDefaultEndpoint : Self.geminiDefaultEndpoint
        let otherModel = targetIsGemini ? Self.qwenDefaultModelID : Self.geminiDefaultModelID

        next.protocolID = targetIsGemini ? Self.geminiProtocolID : Self.qwenProtocolID
        next.version = targetVersion
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpoint.isEmpty || trimmedEndpoint == otherEndpoint {
            next.endpoint = targetEndpoint
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty || trimmedModel == otherModel {
            next.modelID = targetModel
        }
        return next
    }

    func makeSession(clientFactory: () -> LiveTranslateClient, allowLocalhost: Bool = false) throws -> any LiveTranslationSession {
        try validate()
        if isGeminiLive {
            return GeminiLiveSession(allowLocalhost: allowLocalhost)
        }
        return QwenLiveTranslationSession(client: clientFactory())
    }

    func validate() throws {
        let supportedProtocol = (protocolID == Self.qwenProtocolID && version == Self.qwenVersion)
            || (protocolID == Self.geminiProtocolID && version == Self.geminiVersion)
        guard supportedProtocol, inputFormat == "pcm" else {
            throw AIError.message("此协议版本或上行音频格式尚不受支持")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AIError.message("请填写配置名称和有效的模型 ID")
        }
        if !isGeminiLive {
            guard ["server_vad", "speaker_detection"].contains(turnDetection),
                  (0...1).contains(threshold), (1...60000).contains(silenceMS) else {
                throw AIError.message("请检查断句方式、阈值及静音时长")
            }
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
