import Foundation

struct LiveServiceProfile: Codable, Equatable, Identifiable {
    static let qwenProtocolID = "qwen-livetranslate"
    static let qwenVersion = "3.8"
    static let qwenDefaultEndpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    static let qwenDefaultModelID = "qwen3.8-livetranslate-flash-realtime"

    static let volcAstProtocolID = "volc-ast"
    static let volcAstVersion = "2.0"
    static let volcAstDefaultEndpoint = "wss://openspeech.bytedance.com/api/v4/ast/v2/translate"
    static let volcAstDefaultResourceID = "volc.service_type.10053"

    static let supportedSourceLanguages: [(String, String)] = [
        ("", "自动"),
        ("zhen", "中英双语 (zhen)"),
    ] + LiveTranslateConfiguration.languages

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
    /// Optional source language for protocols that require/support it (e.g. volc-ast). Empty means automatic.
    var sourceLanguage = ""
    /// Optional legacy App Key (App ID) for volc-ast dual-credential auth (`X-Api-App-Key` + `X-Api-Access-Key`).
    /// Leave blank to authenticate with the single `X-Api-Key` header. Never stores the secret API/Access Key.
    var appKey = ""

    var isVolcAst: Bool { protocolID == Self.volcAstProtocolID }

    var protocolDisplayName: String {
        isVolcAst ? "Seed-LiveInterpret 2.0" : "Qwen LiveTranslate 3.8"
    }

    static func seedLiveInterpret(
        id: String = "volc-ast-default",
        name: String = "Seed-LiveInterpret 2.0",
        endpoint: String = volcAstDefaultEndpoint,
        resourceID: String = volcAstDefaultResourceID,
        sourceLanguage: String = "",
        appKey: String = ""
    ) -> LiveServiceProfile {
        LiveServiceProfile(
            id: id,
            name: name,
            endpoint: endpoint,
            modelID: resourceID,
            protocolID: volcAstProtocolID,
            version: volcAstVersion,
            sourceLanguage: sourceLanguage,
            appKey: appKey
        )
    }

    func switchingProtocol(to nextProtocolID: String) -> LiveServiceProfile {
        guard nextProtocolID != protocolID else { return self }
        var copy = self
        let trimmedEndpoint = copy.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = copy.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if nextProtocolID == Self.volcAstProtocolID {
            copy.protocolID = Self.volcAstProtocolID
            copy.version = Self.volcAstVersion
            if trimmedEndpoint.isEmpty || trimmedEndpoint == Self.qwenDefaultEndpoint {
                copy.endpoint = Self.volcAstDefaultEndpoint
            }
            if trimmedModel.isEmpty || trimmedModel == Self.qwenDefaultModelID {
                copy.modelID = Self.volcAstDefaultResourceID
            }
            if copy.name == "Qwen LiveTranslate" {
                copy.name = "Seed-LiveInterpret 2.0"
            }
        } else {
            copy.protocolID = Self.qwenProtocolID
            copy.version = Self.qwenVersion
            if trimmedEndpoint.isEmpty || trimmedEndpoint == Self.volcAstDefaultEndpoint {
                copy.endpoint = Self.qwenDefaultEndpoint
            }
            if trimmedModel.isEmpty || trimmedModel == Self.volcAstDefaultResourceID {
                copy.modelID = Self.qwenDefaultModelID
            }
            if copy.name == "Seed-LiveInterpret 2.0" {
                copy.name = "Qwen LiveTranslate"
            }
        }
        return copy
    }

    func resolvedSourceLanguage(targetLanguage: String) -> String {
        let trimmed = sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return targetLanguage == "zh" ? "en" : "zh"
    }

    func makeSession(clientFactory: () -> LiveTranslateClient, allowLocalhost: Bool = false) throws -> any LiveTranslationSession {
        try validate()
        if isVolcAst {
            return SeedLiveInterpretSession(client: SeedLiveInterpretClient(allowLocalhost: allowLocalhost))
        }
        return QwenLiveTranslationSession(client: clientFactory())
    }

    func validate() throws {
        let supportedProtocol = (protocolID == Self.qwenProtocolID && version == Self.qwenVersion)
            || (protocolID == Self.volcAstProtocolID && version == Self.volcAstVersion)
        guard supportedProtocol, inputFormat == "pcm" else {
            throw AIError.message("此协议版本或上行音频格式尚不受支持")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AIError.message(isVolcAst ? "请填写配置名称和有效的资源 ID" : "请填写配置名称和有效的模型 ID")
        }
        if isVolcAst {
            guard Self.supportedSourceLanguages.contains(where: { $0.0 == sourceLanguage }) else {
                throw AIError.message("请选择支持的源语言")
            }
            let trimmedAppKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedAppKey.isEmpty || trimmedAppKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw AIError.message("App Key 格式无效，请重新填写")
            }
        } else {
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

    enum CodingKeys: String, CodingKey {
        case id, name, endpoint, modelID, protocolID, version, turnDetection, threshold, silenceMS, inputFormat, sourceLanguage, appKey
    }

    init(
        id: String = "qwen-default",
        name: String = "Qwen LiveTranslate",
        endpoint: String = LiveServiceProfile.qwenDefaultEndpoint,
        modelID: String = LiveServiceProfile.qwenDefaultModelID,
        protocolID: String = LiveServiceProfile.qwenProtocolID,
        version: String = LiveServiceProfile.qwenVersion,
        turnDetection: String = "server_vad",
        threshold: Double = 0.5,
        silenceMS: Int = 1000,
        inputFormat: String = "pcm",
        sourceLanguage: String = "",
        appKey: String = ""
    ) {
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
        self.sourceLanguage = sourceLanguage
        self.appKey = appKey
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
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? ""
        appKey = try c.decodeIfPresent(String.self, forKey: .appKey) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(protocolID, forKey: .protocolID)
        try c.encode(version, forKey: .version)
        try c.encode(turnDetection, forKey: .turnDetection)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(silenceMS, forKey: .silenceMS)
        try c.encode(inputFormat, forKey: .inputFormat)
        if !sourceLanguage.isEmpty { try c.encode(sourceLanguage, forKey: .sourceLanguage) }
        if !appKey.isEmpty { try c.encode(appKey, forKey: .appKey) }
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
