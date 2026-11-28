import Foundation

enum LiveTranslatePlaybackTiming: String, Codable, CaseIterable {
    case streaming
    case afterFinal
    var title: String { self == .streaming ? "边说边播放" : "定稿后播放" }
}

enum LiveTranslateProvider: String, Codable, CaseIterable {
    case qwenCloud, hyLocal
}

struct LiveTranslatePreferences: Codable, Equatable {
    var language = "zh"
    var audioOutput = false
    var volume: Float = 0.8
    var playbackTiming: LiveTranslatePlaybackTiming = .streaming
}

struct LiveTranslateConfiguration: Codable, Equatable {
    static let languages = [("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
                            ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский")]
    var enabled = false
    var provider: LiveTranslateProvider = .qwenCloud
    var catalog = LiveServiceCatalog()
    var profile: LiveServiceProfile { catalog.selected }
    var endpoint: String {
        get { profile.endpoint }
        set { var edited = profile; edited.endpoint = newValue; catalog.use(edited) }
    }
    var language = "zh"
    var audioOutput = false
    var volume: Float = 0.8
    var playbackTiming: LiveTranslatePlaybackTiming = .streaming
    var cloudPreferences = LiveTranslatePreferences()
    var localPreferences = LiveTranslatePreferences()
    var outputModalities: [String] { audioOutput ? ["text", "audio"] : ["text"] }
    var supportedLanguages: [(String, String)] { provider == .hyLocal ? [("zh", "中文"), ("en", "English")] : Self.languages }
    var modelName: String { provider == .hyLocal ? "Hy-SimulMT Interleave Q4_K_M" : profile.name }
    enum CodingKeys: String, CodingKey { case enabled, provider, catalog, language, audioOutput, volume, playbackTiming, cloudPreferences, localPreferences }
    init(enabled: Bool = false, endpoint: String = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime", language: String = "zh",
         audioOutput: Bool = false, volume: Float = 0.8, playbackTiming: LiveTranslatePlaybackTiming = .streaming,
         provider: LiveTranslateProvider = .qwenCloud) {
        self.enabled = enabled; self.endpoint = endpoint; self.language = language
        self.provider = provider
        self.audioOutput = audioOutput; self.volume = volume; self.playbackTiming = playbackTiming
        rememberActivePreferences()
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        provider = try c.decodeIfPresent(LiveTranslateProvider.self, forKey: .provider) ?? .qwenCloud
        if let saved = try c.decodeIfPresent(LiveServiceCatalog.self, forKey: .catalog) {
            catalog = saved
        } else {
            enum LegacyKeys: CodingKey { case endpoint }
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            endpoint = try legacy.decode(String.self, forKey: .endpoint)
        }
        language = try c.decode(String.self, forKey: .language)
        audioOutput = try c.decodeIfPresent(Bool.self, forKey: .audioOutput) ?? false
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8
        playbackTiming = try c.decodeIfPresent(LiveTranslatePlaybackTiming.self, forKey: .playbackTiming) ?? .streaming
        cloudPreferences = try c.decodeIfPresent(LiveTranslatePreferences.self, forKey: .cloudPreferences) ?? LiveTranslatePreferences()
        localPreferences = try c.decodeIfPresent(LiveTranslatePreferences.self, forKey: .localPreferences) ?? LiveTranslatePreferences()
        rememberActivePreferences()
    }
    var languageName: String { Self.languages.first { $0.0 == language }?.1 ?? language }
    // Separate namespace from both ASR credentials and Chat Completions profiles.
    var keyAccount: String { "livetranslate:" + endpoint }

    func url(allowLocalhost: Bool = false) throws -> URL {
        guard provider == .qwenCloud else { throw AIError.message("本地 Hy-SimulMT 不使用云端服务地址") }
        try profile.validate()
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AIError.message("请填写有效的 WSS 实时服务地址，并选择支持的目标语言")
        }
        let queryValid = profile.isVolcAst
            ? (parts.queryItems ?? []).isEmpty
            : (parts.queryItems ?? []).allSatisfy({ $0.name == "model" })
        guard let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "wss" || (allowLocalhost && parts.scheme == "ws" && host == "127.0.0.1"),
              (parts.port.map { (1...65535).contains($0) } ?? true),
              !parts.path.isEmpty, parts.path != "/",
              queryValid,
              volume.isFinite, (0...1).contains(volume),
              Self.languages.contains(where: { $0.0 == language }) else {
            throw AIError.message("请填写有效的 WSS 实时服务地址，并选择支持的目标语言")
        }
        if profile.isVolcAst {
            parts.queryItems = nil
        } else {
            parts.queryItems = [URLQueryItem(name: "model", value: profile.modelID)]
            // Common server query decoders treat a literal plus as a space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw AIError.message("LiveTranslate 地址无效") }
        return url
    }
    func normalized(allowLocalhost: Bool = false) throws -> Self {
        var result = self
        if provider == .hyLocal {
            guard supportedLanguages.contains(where: { $0.0 == language }), volume.isFinite, (0...1).contains(volume) else {
                throw AIError.message("Hy-SimulMT 仅支持中英互译，请选择有效的目标语言和音量")
            }
            result.rememberActivePreferences()
            return result
        }
        var parts = URLComponents(url: try url(allowLocalhost: allowLocalhost), resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        result.endpoint = parts.url!.absoluteString
        result.rememberActivePreferences()
        return result
    }
    private mutating func rememberActivePreferences() {
        let settings = LiveTranslatePreferences(language: language, audioOutput: audioOutput, volume: volume, playbackTiming: playbackTiming)
        if provider == .qwenCloud { cloudPreferences = settings } else { localPreferences = settings }
    }
    func selecting(_ provider: LiveTranslateProvider) -> Self {
        var result = self
        result.rememberActivePreferences(); result.provider = provider
        let settings = provider == .qwenCloud ? result.cloudPreferences : result.localPreferences
        result.language = settings.language; result.audioOutput = settings.audioOutput
        result.volume = settings.volume; result.playbackTiming = settings.playbackTiming
        return result
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "livetranslate.configuration.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard, allowLocalhost: Bool = false) throws {
        defaults.set(try JSONEncoder().encode(try normalized(allowLocalhost: allowLocalhost)), forKey: "livetranslate.configuration.v1")
    }
    var sessionUpdate: [String: Any] {
        var audio: [String: Any] = ["input": ["format": ["type": profile.inputFormat, "sample_rate": 16000],
            "turn_detection": profile.detectionParameters]]
        if audioOutput { audio["output"] = ["format": ["type": "pcm", "sample_rate": 24000]] }
        return ["type": "session.update", "session": [
            "output_modalities": outputModalities, "translation": ["language": language], "audio": audio]]
    }

}

/// Source and translation arrive independently. Join by IDs, never by text or arrival order.
struct LiveTranslateEvents {
    struct Part {
        var text = ""
        var done = false
    }
    struct Row {
        var id: String
        var source = Part()
        var seconds: Double = 0
        var outputs: [String] = []
    }
    private(set) var rows: [String: Row] = [:]
    private(set) var order: [String] = []
    private(set) var outputs: [String: Part] = [:]
    private var events = Set<String>()

    private mutating func ensure(_ id: String) {
        if rows[id] == nil { rows[id] = Row(id: id); order.append(id) }
    }
    mutating func apply(_ event: [String: Any]) {
        if let id = event["event_id"] as? String, !events.insert(id).inserted { return }
        let type = event["type"] as? String ?? ""
        if type == "conversation.item.created", let item = event["item"] as? [String: Any],
           item["role"] as? String == "assistant", let output = item["id"] as? String,
           let source = event["previous_item_id"] as? String {
            ensure(source)
            if !rows[source]!.outputs.contains(output) { rows[source]!.outputs.append(output) }
        }
        guard let id = event["item_id"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            ensure(id); rows[id]!.seconds = Double(event["audio_start_ms"] as? Int ?? 0) / 1000
        case "conversation.item.input_audio_transcription.delta":
            ensure(id)
            if !rows[id]!.source.done { rows[id]!.source.text += event["delta"] as? String ?? "" }
        case "conversation.item.input_audio_transcription.completed":
            ensure(id); rows[id]!.source = Part(text: event["transcript"] as? String ?? "", done: true)
        case "response.text.delta", "response.audio_transcript.delta":
            var part = outputs[id] ?? Part()
            if !part.done { part.text += event["delta"] as? String ?? "" }
            outputs[id] = part
        case "response.text.done", "response.audio_transcript.done":
            outputs[id] = Part(text: (event["text"] ?? event["transcript"]) as? String ?? "", done: true)
        default: break
        }
    }
    func translation(for row: Row) -> Part {
        Part(text: row.outputs.compactMap { outputs[$0]?.text }.joined(separator: " "),
             done: !row.outputs.isEmpty && row.outputs.allSatisfy { outputs[$0]?.done == true })
    }
    var unmatchedOutputs: [(String, Part)] {
        let matched = Set(rows.values.flatMap(\.outputs))
        return outputs.filter { !matched.contains($0.key) && !$0.value.text.isEmpty }.sorted { $0.key < $1.key }
    }
    var hasUnmatchedOutput: Bool { !unmatchedOutputs.isEmpty }
}

enum LiveCloudEndKind {
    case other, rateLimited, noResult

    static func classify(code: Int? = nil, detail: String) -> Self {
        let value = detail.lowercased()
        if value.contains("no semantic result") { return .noResult }
        if code == 1007 || code == 429 || ["rate limit", "rate_limit", "ratelimit", "throttl"].contains(where: value.contains) {
            return .rateLimited
        }
        return .other
    }
    var message: String? {
        switch self {
        case .rateLimited: return "LiveTranslate 服务限流，请稍后重试；已有文字已保留"
        case .noResult: return "LiveTranslate 长时间没有识别结果，服务已结束会话；已有文字已保留"
        case .other: return nil
        }
    }
}

/// All transport state lives on one serial queue; audio producers only enqueue bounded data.
final class LiveTranslateClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var endKind = LiveCloudEndKind.other
    var onSlowService: ((Bool) -> Void)?
    private var windowStart: TimeInterval = 0
    private var windowQueue = 0
    private var windowBytes = 0
    private var slow = false
    private var uplinkSlow = false
    private var serviceSlow = false
    private var progressAnchor: (time: TimeInterval, offsetMS: Int)?
    var onReady: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onEnd: ((String?) -> Void)?
    private let queue = DispatchQueue(label: "recorder.livetranslate")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var pending: [(String, Int)] = []
    private var buffered = 0
    private var sending = false
    private var ready = false
    private var finishing = false
    private var closed = false
    private var configured = false
    private var deadline: DispatchWorkItem?
    private let finishTimeout: TimeInterval
    private let allowLocalhost: Bool
    private let uptime: () -> TimeInterval

    init(finishTimeout: TimeInterval = 30, allowLocalhost: Bool = false,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        self.finishTimeout = finishTimeout; self.allowLocalhost = allowLocalhost
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func connect(configuration: LiveTranslateConfiguration, key: String, allowLocalhost: Bool = false) throws {
        guard !key.isEmpty else { throw AIError.message("请在 LiveTranslate 设置中保存专用 API Key") }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AIError.message("API Key 格式无效，请重新填写") }
        var request = URLRequest(url: try configuration.url(allowLocalhost: allowLocalhost || self.allowLocalhost))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 20
        queue.sync {
            let session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 2_000_000
            self.socket = socket
            socket.resume()
            armTimeout(20, message: "LiveTranslate 连接或会话配置超时，请检查网络和服务地址")
            receive(configuration)
        }
    }
    func append(_ data: Data) -> Bool {
        queue.sync {
            guard ready, !finishing, !closed else { return false }
            let now = uptime()
            var nextSlow = uplinkSlow
            if now - windowStart >= 15, windowBytes > 0 {
                nextSlow = Double(windowQueue + windowBytes - buffered) < 0.8 * Double(windowBytes)
                windowStart = now; windowQueue = buffered; windowBytes = 0
            }
            if buffered > 48_000 { nextSlow = true }
            uplinkSlow = nextSlow
            publishServiceSpeed()
            guard buffered + data.count <= 320_000 else { return false }
            windowBytes += data.count
            enqueue(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], bytes: data.count)
            return true
        }
    }
    // VAD timestamps also show a slow reader when the OS has already drained its local send queue.
    private func observeProgress(_ offsetMS: Int) {
        let now = uptime()
        guard let anchor = progressAnchor else { progressAnchor = (now, offsetMS); return }
        let elapsed = now - anchor.time
        guard elapsed >= 15, offsetMS > anchor.offsetMS else { return }
        serviceSlow = Double(offsetMS - anchor.offsetMS) < 800 * elapsed
        progressAnchor = (now, offsetMS)
        publishServiceSpeed()
    }
    private func publishServiceSpeed() {
        let value = uplinkSlow || serviceSlow
        guard slow != value else { return }
        slow = value
        let callback = onSlowService
        DispatchQueue.main.async { callback?(value) }
    }
    func finish() {
        queue.async {
            guard self.ready, !self.closed, !self.finishing else { return }
            self.finishing = true
            self.armTimeout(self.finishTimeout, message: "LiveTranslate 尾句处理超时，已保留收到的文字，末句可能不完整")
            self.enqueue(["type": "session.finish"])
        }
    }
    func cancel() { queue.sync { end(nil, notify: false) } }
    private func armTimeout(_ seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end(message) }
        deadline = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func enqueue(_ event: [String: Any], bytes: Int = 0) {
        var value = event; value["event_id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else {
            end("LiveTranslate 请求编码失败"); return
        }
        buffered += bytes; pending.append((text, bytes)); sendNext()
    }
    private func sendNext() {
        guard !closed, !sending, !pending.isEmpty, let socket else { return }
        sending = true
        let (text, bytes) = pending.removeFirst()
        socket.send(.string(text)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.sending = false; self.buffered -= bytes
                if error != nil { self.end(self.connectionError()) } else { self.sendNext() }
            }
        }
    }
    private func receive(_ configuration: LiveTranslateConfiguration) {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure: self.end(self.connectionError())
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: self.end("LiveTranslate 返回未知消息格式"); return
                    }
                    guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let type = event["type"] as? String else { self.end("LiveTranslate 返回无效数据"); return }
                    switch type {
                    case "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped":
                        let field = type.hasSuffix("started") ? "audio_start_ms" : "audio_end_ms"
                        if self.ready, let offset = event[field] as? Int { self.observeProgress(offset) }
                    case "session.created":
                        if !self.configured { self.configured = true; self.enqueue(configuration.sessionUpdate) }
                    case "session.updated":
                        guard self.configured else { self.end("LiveTranslate 会话配置顺序异常"); return }
                        guard let value = event["session"] as? [String: Any],
                              Set(value["output_modalities"] as? [String] ?? []) == Set(configuration.outputModalities),
                              (value["translation"] as? [String: Any])?["language"] as? String == configuration.language else {
                            self.end("LiveTranslate 未确认所选输出方式及目标语言，请检查模型和接口兼容性"); return
                        }
                        if configuration.audioOutput {
                            let output = (value["audio"] as? [String: Any])?["output"] as? [String: Any]
                            let format = output?["format"] as? [String: Any]
                            guard format?["type"] as? String == "pcm", format?["sample_rate"] as? Int == 24000 else {
                                self.end("LiveTranslate 未确认 24 kHz PCM 译音格式"); return
                            }
                        }
                        if !self.ready {
                            self.ready = true; self.deadline?.cancel(); self.windowStart = self.uptime()
                            let callback = self.onReady; DispatchQueue.main.async { callback?() }
                        }
                    case "session.finished":
                        self.end(self.finishing ? nil : "LiveTranslate 会话意外结束，已保留收到的文字"); return
                    case "error", "conversation.item.input_audio_transcription.failed":
                        let code = (event["error"] as? [String: Any])?["code"] as? String ?? ""
                        let message = (event["error"] as? [String: Any])?["message"] as? String ?? ""
                        self.endKind = .classify(detail: code + " " + message)
                        self.end(self.endKind.message ?? Self.serviceError(code)); return
                    case "response.done":
                        let status = (event["response"] as? [String: Any])?["status"] as? String
                        if status != "completed" { self.end("LiveTranslate 译文未完成，已保留收到的文字"); return }
                    default: break
                    }
                    let callback = self.onEvent; DispatchQueue.main.async { callback?(event) }
                    self.receive(configuration)
                }
            }
        }
    }
    private func connectionError() -> String {
        let status = (socket?.response as? HTTPURLResponse)?.statusCode
        let reason = socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        endKind = .classify(code: status == 429 ? status : socket?.closeCode.rawValue, detail: reason)
        if let message = endKind.message { return message }
        switch status {
        case 401, 403: return "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
        case 429: return "LiveTranslate 请求受限或额度不足，请稍后重试"
        default: return "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
        }
    }
    static func serviceError(_ code: String) -> String {
        let value = code.lowercased()
        if value.contains("auth") || value.contains("key") || value.contains("permission") {
            return "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
        }
        if value.contains("limit") || value.contains("quota") || value.contains("balance") {
            return "LiveTranslate 请求受限或额度不足，请检查账户余额并稍后重试"
        }
        return "LiveTranslate 服务处理失败，请检查模型权限和会话配置；已有文字已保留"
    }
    private func end(_ error: String?, notify: Bool = true) {
        guard !closed else { return }
        closed = true; ready = false; deadline?.cancel(); deadline = nil
        pending.removeAll(); buffered = 0
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        if notify { let callback = onEnd; DispatchQueue.main.async { callback?(error) } }
    }
}
