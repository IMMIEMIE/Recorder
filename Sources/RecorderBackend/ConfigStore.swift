import Foundation

enum ConfigIO {
    /// Atomic save: write .tmp, chmod 0600, rename over the target.
    static func save(_ path: URL, _ value: [String: Any]) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
        let tmp = path.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }
}

func validModelID(_ modelID: String) -> Bool {
    let parts = modelID.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !modelID.contains("..")
}

public struct ModelConfig: Equatable {
    public init() {}

    public var schemaVersion = 1
    public var modelID = Backend.defaultModel
    public var localModelPath = ""
    public var revision = ""
    public var language = "auto"
    // max_segment_seconds bounds inference chunks, never finalization.
    public var previewIntervalMS = 1200
    public var endpointMode = "smart"
    public var endpointSilenceMS = 1000
    public var maxSegmentSeconds = 18
    public var provider = "local"
    public var apiBaseURL = ""
    public var apiModel = ""
    public var apiProtocol = "openai"

    public static let fields = ["schema_version", "model_id", "local_model_path", "revision", "language",
                         "preview_interval_ms", "endpoint_mode", "endpoint_silence_ms", "max_segment_seconds",
                         "provider", "api_base_url", "api_model", "api_protocol"]

    public var asDict: [String: Any] {
        ["schema_version": schemaVersion, "model_id": modelID, "local_model_path": localModelPath,
         "revision": revision, "language": language, "preview_interval_ms": previewIntervalMS,
         "endpoint_mode": endpointMode, "endpoint_silence_ms": endpointSilenceMS,
         "max_segment_seconds": maxSegmentSeconds, "provider": provider, "api_base_url": apiBaseURL,
         "api_model": apiModel, "api_protocol": apiProtocol]
    }

    public func save(_ path: URL) throws { try ConfigIO.save(path, asDict) }

    public static func parse(_ values: [String: Any]) throws -> ModelConfig {
        let unknown = Set(values.keys).subtracting(fields).sorted()
        if !unknown.isEmpty {
            throw BackendError.value("未知配置字段: \(unknown.map { "'\($0)'" }.joined(separator: ", "))")
        }
        var c = ModelConfig()
        if values["schema_version"] != nil, strictJSONInt(values["schema_version"]!) != 1 {
            throw BackendError.value("不支持的配置版本")
        }
        for (key, low, high) in [("preview_interval_ms", 800, 10000), ("endpoint_silence_ms", 300, 2000),
                                 ("max_segment_seconds", 5, 25)] {
            if let raw = values[key] {
                guard let v = strictJSONInt(raw), v >= low, v <= high else {
                    throw BackendError.value("\(key) 必须在 \(low)–\(high) 范围内")
                }
                switch key {
                case "preview_interval_ms": c.previewIntervalMS = v
                case "endpoint_silence_ms": c.endpointSilenceMS = v
                default: c.maxSegmentSeconds = v
                }
            }
        }
        if let v = values["endpoint_mode"] {
            guard let mode = v as? String, ["smart", "fixed"].contains(mode) else { throw BackendError.value("不支持的定稿模式") }
            c.endpointMode = mode
        }
        if let v = values["language"] {
            guard let language = v as? String,
                  ["auto", "Chinese", "English", "Cantonese", "Japanese", "Korean"].contains(language) else {
                throw BackendError.value("不支持的语言选项")
            }
            c.language = language
        }
        if let v = values["provider"] {
            guard let provider = v as? String, ["local", "api"].contains(provider) else { throw BackendError.value("不支持的识别服务") }
            c.provider = provider
        }
        if let v = values["api_protocol"] {
            guard let protocolName = v as? String, ["openai", "qwen_realtime"].contains(protocolName) else { throw BackendError.value("不支持的识别 API 类型") }
            c.apiProtocol = protocolName
        }
        for key in ["model_id", "local_model_path", "revision", "api_base_url", "api_model"] {
            if let v = values[key], !(v is String) { throw BackendError.value("\(key) 必须为字符串") }
        }
        if let v = values["model_id"] as? String { c.modelID = v }
        if let v = values["local_model_path"] as? String { c.localModelPath = v }
        if let v = values["revision"] as? String { c.revision = v }
        if let v = values["api_base_url"] as? String { c.apiBaseURL = v }
        if let v = values["api_model"] as? String { c.apiModel = v }
        if c.provider == "api" {
            try validateAPIAddress(c)
        } else if c.localModelPath.isEmpty && !validModelID(c.modelID) {
            throw BackendError.value("请输入 owner/model 格式的模型 ID")
        }
        return c
    }

    private static let apiAddressMessage = "请填写有效的 API Base URL 和模型 ID（远程服务须使用 HTTPS）"

    private static func validateAPIAddress(_ c: ModelConfig) throws {
        let secureScheme = c.apiProtocol == "qwen_realtime" ? "wss" : "https"
        guard let url = URL(string: c.apiBaseURL), let host = url.host, !host.isEmpty else {
            throw BackendError.value(apiAddressMessage)
        }
        let localhostHTTP = c.apiProtocol == "openai" && url.scheme == "http" &&
            (host == "localhost" || host == "127.0.0.1" || host == "::1")
        let invalid = url.user != nil || url.password != nil || url.query != nil || url.fragment != nil ||
            (url.scheme != secureScheme && !localhostHTTP) ||
            c.apiBaseURL.hasSuffix("/") ||
            c.apiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            c.apiModel.contains("\n") || c.apiModel.contains("\r")
        if invalid { throw BackendError.value(apiAddressMessage) }
    }
}

public struct TranslationConfig: Equatable {
    public init() {}

    /// Saved separately from the ASR config so each model role commits atomically on its own.
    public var schemaVersion = 1
    public var enabled = false
    public var provider = "local"
    public var apiProfile = ""
    public var targetLanguage = "简体中文"
    public var modelID = Backend.defaultTranslator
    public var revision = ""

    public static let fields = ["schema_version", "enabled", "provider", "api_profile", "target_language", "model_id", "revision"]

    public var asDict: [String: Any] {
        ["schema_version": schemaVersion, "enabled": enabled, "provider": provider,
         "api_profile": apiProfile, "target_language": targetLanguage, "model_id": modelID, "revision": revision]
    }

    public func save(_ path: URL) throws { try ConfigIO.save(path, asDict) }

    public static func parse(_ values: [String: Any]) throws -> TranslationConfig {
        let unknown = Set(values.keys).subtracting(fields).sorted()
        if !unknown.isEmpty {
            throw BackendError.value("未知翻译配置字段: \(unknown.map { "'\($0)'" }.joined(separator: ", "))")
        }
        var c = TranslationConfig()
        if values["schema_version"] != nil, strictJSONInt(values["schema_version"]!) != 1 {
            throw BackendError.value("不支持的翻译配置版本")
        }
        if let v = values["provider"] as? String {
            guard ["local", "api"].contains(v) else { throw BackendError.value("不支持的翻译服务") }
            c.provider = v
        }
        if let v = values["api_profile"], !(v is String) { throw BackendError.value("API 配置标识必须为字符串") }
        if let v = values["enabled"] {
            guard let bool = strictJSONBool(v) else { throw BackendError.value("enabled 必须为布尔值") }
            c.enabled = bool
        }
        if let v = values["target_language"] as? String {
            guard Backend.translationTargets[v] != nil else { throw BackendError.value("不支持的翻译目标语言") }
            c.targetLanguage = v
        }
        for key in ["model_id", "revision"] {
            if let v = values[key], !(v is String) { throw BackendError.value("\(key) 必须为字符串") }
        }
        if let v = values["api_profile"] as? String { c.apiProfile = v }
        if let v = values["model_id"] as? String { c.modelID = v }
        if let v = values["revision"] as? String { c.revision = v }
        if !validModelID(c.modelID) { throw BackendError.value("请输入 owner/model 格式的翻译模型 ID") }
        return c
    }
}
