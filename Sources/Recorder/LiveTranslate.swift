import Foundation

struct LiveTranslateConfiguration: Codable, Equatable {
    static let model = "qwen3.8-livetranslate-flash-realtime"
    static let languages = [("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
                            ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский")]
    var enabled = false
    var endpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    var language = "zh"
    var languageName: String { Self.languages.first { $0.0 == language }?.1 ?? language }
    // Separate namespace from both ASR credentials and Chat Completions profiles.
    var keyAccount: String { "livetranslate:" + endpoint }

    func url(allowLocalhost: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "wss" || (allowLocalhost && parts.scheme == "ws" && host == "127.0.0.1"),
              !parts.path.isEmpty, parts.path != "/",
              (parts.queryItems ?? []).allSatisfy({ $0.name == "model" }),
              Self.languages.contains(where: { $0.0 == language }) else {
            throw AIError.message("请填写有效的 WSS 实时服务地址，并选择支持的目标语言")
        }
        parts.queryItems = [URLQueryItem(name: "model", value: Self.model)]
        guard let url = parts.url else { throw AIError.message("LiveTranslate 地址无效") }
        return url
    }
    func normalized() throws -> Self {
        var result = self
        var parts = URLComponents(url: try url(), resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        result.endpoint = parts.url!.absoluteString
        return result
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "livetranslate.configuration.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(try normalized()), forKey: "livetranslate.configuration.v1")
    }
    var sessionUpdate: [String: Any] {
        ["type": "session.update", "session": [
            "output_modalities": ["text"], "translation": ["language": language],
            "audio": ["input": ["format": ["type": "pcm", "sample_rate": 16000],
                                 "turn_detection": ["type": "server_vad", "threshold": 0.5, "silence_duration_ms": 1000]]]
        ]]
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
        case "response.text.delta":
            var part = outputs[id] ?? Part()
            if !part.done { part.text += event["delta"] as? String ?? "" }
            outputs[id] = part
        case "response.text.done":
            outputs[id] = Part(text: event["text"] as? String ?? "", done: true)
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

/// All transport state lives on one serial queue; audio producers only enqueue bounded data.
final class LiveTranslateClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

    init(finishTimeout: TimeInterval = 30, allowLocalhost: Bool = false) {
        self.finishTimeout = finishTimeout; self.allowLocalhost = allowLocalhost
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func connect(configuration: LiveTranslateConfiguration, key: String, allowLocalhost: Bool = false) throws {
        guard !key.isEmpty else { throw AIError.message("请在 LiveTranslate 设置中保存专用 API Key") }
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
            guard ready, !finishing, !closed, buffered + data.count <= 320_000 else { return false }
            enqueue(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], bytes: data.count)
            return true
        }
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
                    case "session.created":
                        if !self.configured { self.configured = true; self.enqueue(configuration.sessionUpdate) }
                    case "session.updated":
                        guard self.configured else { self.end("LiveTranslate 会话配置顺序异常"); return }
                        guard let value = event["session"] as? [String: Any],
                              value["output_modalities"] as? [String] == ["text"],
                              (value["translation"] as? [String: Any])?["language"] as? String == configuration.language else {
                            self.end("LiveTranslate 未确认文本输出及目标语言，请检查模型和接口兼容性"); return
                        }
                        if !self.ready {
                            self.ready = true; self.deadline?.cancel()
                            let callback = self.onReady; DispatchQueue.main.async { callback?() }
                        }
                    case "session.finished":
                        self.end(self.finishing ? nil : "LiveTranslate 会话意外结束，已保留收到的文字"); return
                    case "error", "conversation.item.input_audio_transcription.failed":
                        let code = (event["error"] as? [String: Any])?["code"] as? String ?? ""
                        self.end(Self.serviceError(code)); return
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
        switch (socket?.response as? HTTPURLResponse)?.statusCode {
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
