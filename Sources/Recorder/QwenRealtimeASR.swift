import Foundation

struct QwenRealtimeASRConfiguration {
    static let endpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    static let model = "qwen-audio-3.1-realtime-plus"
    static let realtimePath = "/api-ws/v1/realtime"
    /// A key only works on the platform and region that issued it.
    static let presets = [("千问AI平台（qianwenai.com）", "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"),
                          ("阿里云百炼 · 北京", "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"),
                          ("阿里云百炼 · 新加坡", "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"),
                          ("QwenCloud（国际）", "wss://maas.qwencloudapi.com/api-ws/v1/realtime")]
    static let languageCodes = ["Chinese":"zh", "Cantonese":"zh", "English":"en", "Japanese":"ja", "Korean":"ko"]
    var endpoint: String
    var model: String
    var language = "auto"

    /// Accepts the realtime WSS address or the platform's HTTPS base URL, which shares its host.
    func url(allowLocalhost: Bool = false) throws -> URL {
        let invalid = AIError.message("请填写有效的实时接口地址（wss://…/api-ws/v1/realtime，或平台的 https Base URL）和模型 ID")
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              (parts.queryItems ?? []).allSatisfy({ $0.name == "model" }),
              !modelID.isEmpty, !modelID.contains("\n"), !modelID.contains("\r") else { throw invalid }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        switch (parts.scheme ?? "").lowercased() {
        case "https":
            guard ["", "/api/v1", "/compatible-mode/v1", Self.realtimePath].contains(path) else { throw invalid }
            parts.scheme = "wss"; path = Self.realtimePath
        case "wss":
            parts.scheme = "wss"
            if path.isEmpty { path = Self.realtimePath }
        case "ws" where allowLocalhost && host == "127.0.0.1" && !path.isEmpty:
            parts.scheme = "ws"
        default:
            throw invalid
        }
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "model", value: modelID)]
        guard let url = parts.url else { throw AIError.message("千问实时接口地址无效") }
        return url
    }
    func normalizedEndpoint() throws -> String {
        var parts = URLComponents(url: try url(), resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        return parts.url!.absoluteString
    }
    /// `created` is the server's default session; its ASR model is kept when a language hint is added.
    /// `minimal` keeps only the field manual commit depends on, for services that reject the others.
    func sessionUpdate(created: [String: Any]? = nil, minimal: Bool = false) -> [String: Any] {
        var session: [String: Any] = ["turn_detection": NSNull()]
        if !minimal {
            session["modalities"] = ["text"]; session["input_audio_format"] = "pcm"
            if let code = Self.languageCodes[language] {
                var transcription: [String: Any] = ["language": code]
                if let asr = (created?["input_audio_transcription"] as? [String: Any])?["model"] as? String {
                    transcription["model"] = asr
                }
                session["input_audio_transcription"] = transcription
            }
        }
        return ["type":"session.update", "session":session]
    }
    /// Automatic turn detection would make the server answer on its own, so audio waits until it is off.
    static func manualCommitConfirmed(_ session: [String: Any]?) -> Bool {
        guard let session else { return false }
        let nested = ((session["audio"] as? [String: Any])?["input"] as? [String: Any])?["turn_detection"]
        return [session["turn_detection"], nested].allSatisfy { value in
            guard let value else { return true }
            return value is NSNull
        }
    }
}

/// Commit input audio without response.create: display ASR, never the assistant's answer.
final class QwenRealtimeASRClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct ConfigurationRejected: Error {}
    private static let minimalLock = NSLock()
    private static var minimalSessions = Set<String>()
    private let timeout: TimeInterval
    private let allowLocalhost: Bool
    init(timeout: TimeInterval = 90, allowLocalhost: Bool = false) {
        self.timeout = timeout; self.allowLocalhost = allowLocalhost
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func transcribe(configuration: QwenRealtimeASRConfiguration, key: String, pcm: Data?,
                    onText: @escaping @MainActor @Sendable (String) async -> Void = { _ in }) async throws -> String {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else {
            throw AIError.message("请保存千问平台的 API Key")
        }
        if let pcm, pcm.isEmpty || pcm.count % 2 != 0 || pcm.count > 800_000 {
            throw AIError.message("千问识别音频片段无效或过长")
        }
        let service = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + configuration.model
        if Self.needsMinimal(service) { return try await connect(configuration, minimal: true, key: key, pcm: pcm, onText: onText) }
        do { return try await connect(configuration, minimal: false, key: key, pcm: pcm, onText: onText) }
        catch is ConfigurationRejected {
            // Models validate session.update strictly (e.g. no language option); manual commit needs only turn_detection.
            let text = try await connect(configuration, minimal: true, key: key, pcm: pcm, onText: onText)
            Self.rememberMinimal(service)
            return text
        }
    }
    private static func needsMinimal(_ service: String) -> Bool {
        minimalLock.lock(); defer { minimalLock.unlock() }
        return minimalSessions.contains(service)
    }
    private static func rememberMinimal(_ service: String) {
        minimalLock.lock(); defer { minimalLock.unlock() }
        minimalSessions.insert(service)
    }
    private func connect(_ configuration: QwenRealtimeASRConfiguration, minimal: Bool, key: String, pcm: Data?,
                         onText: @escaping @MainActor @Sendable (String) async -> Void) async throws -> String {
        var request = URLRequest(url: try configuration.url(allowLocalhost: allowLocalhost))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_000_000
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        socket.resume()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.receive(socket, configuration: configuration, minimal: minimal, key: key, pcm: pcm, onText: onText)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                socket.cancel(with: .goingAway, reason: nil)
                throw AIError.message("千问实时识别连接或转写超时，已确认文字仍保留")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func send(_ socket: URLSessionWebSocketTask, _ event: [String: Any]) async throws {
        var event = event; event["event_id"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive(_ socket: URLSessionWebSocketTask, configuration: QwenRealtimeASRConfiguration, minimal: Bool, key: String,
                         pcm: Data?, onText: @escaping @MainActor @Sendable (String) async -> Void) async throws -> String {
        var configured = false, confirmed = false, submitted = false
        var text = "", itemID: String?
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() }
            catch {
                try Task.checkCancellation()
                throw AIError.message(Self.connectionError(socket, error, key: key))
            }
            let data: Data
            switch message {
            case .string(let value): data = Data(value.utf8)
            case .data(let value): data = value
            @unknown default: throw AIError.message("千问返回未知消息格式")
            }
            guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String else { throw AIError.message("千问返回无效数据") }
            if let id = event["event_id"] as? String, !seen.insert(id).inserted { continue }
            switch type {
            case "session.created":
                guard !configured else { continue }
                configured = true
                try await send(socket, configuration.sessionUpdate(created: event["session"] as? [String: Any], minimal: minimal))
            case "session.updated":
                guard configured, !confirmed else { continue }
                // The server echoes its full session; a missing or null turn_detection both mean manual commit.
                let session = event["session"] as? [String: Any]
                guard QwenRealtimeASRConfiguration.manualCommitConfirmed(session) else {
                    let mode = (session?["turn_detection"] as? [String: Any])?["type"] as? String ?? "未知"
                    throw AIError.message("千问会话未关闭自动断句（turn_detection: \(mode)），无法使用手动提交；音频尚未发送")
                }
                confirmed = true
                guard let pcm else { return "" } // Connection test never uploads audio.
                submitted = true
                for offset in stride(from: 0, to: pcm.count, by: 3200) {
                    try Task.checkCancellation()
                    try await send(socket, ["type":"input_audio_buffer.append",
                                            "audio":pcm.subdata(in: offset..<min(offset + 3200, pcm.count)).base64EncodedString()])
                }
                try await send(socket, ["type":"input_audio_buffer.commit"])
            case "input_audio_buffer.committed":
                if submitted, itemID == nil { itemID = event["item_id"] as? String }
            case "conversation.item.input_audio_transcription.text", "conversation.item.input_audio_transcription.delta",
                 "conversation.item.input_audio_transcription.completed":
                guard submitted, let id = event["item_id"] as? String else { continue }
                if itemID == nil { itemID = id }
                guard id == itemID else { continue }
                if type.hasSuffix(".completed") {
                    guard let final = event["transcript"] as? String, final.utf8.count <= 200_000 else {
                        throw AIError.message("千问转写结果无效或过长")
                    }
                    return final.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Qwen publishes confirmed text plus a replaceable tentative suffix.
                if let stable = event["text"] as? String {
                    text = stable + (event["stash"] as? String ?? "")
                } else { text += event["delta"] as? String ?? "" }
                guard text.utf8.count <= 200_000 else { throw AIError.message("千问转写结果过长") }
                await onText(text)
            case "error", "conversation.item.input_audio_transcription.failed":
                if type == "error", configured, !confirmed, !minimal { throw ConfigurationRejected() }
                throw AIError.message(Self.serviceError(event["error"] as? [String: Any], key: key, model: configuration.model))
            default: break // response.* is an assistant response, not the input transcript.
            }
        }
    }

    /// Server text can echo request details, so the key is masked and the length bounded before display.
    static func serverDetail(_ values: [Any?], key: String) -> String {
        var text = values.compactMap { value -> String? in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "***") }
        text = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
    static func serviceError(_ error: [String: Any]?, key: String, model: String) -> String {
        let detail = serverDetail([error?["code"], error?["message"], error?["param"]], key: key)
        let value = detail.lowercased(), suffix = detail.isEmpty ? "" : "（服务器返回：\(detail)）"
        if ["auth", "apikey", "api key", "api-key", "unauthorized", "forbidden", "access denied", "permission"].contains(where: { value.contains($0) }) {
            return "千问 API Key 无效或无权访问 \(model)，请确认密钥与服务地址属于同一平台和区域，并已开通该模型" + suffix
        }
        if ["quota", "arrearage", "balance", "throttl", "rate limit", "ratelimit"].contains(where: { value.contains($0) }) {
            return "千问请求受限或额度不足，请检查账户余额后稍后重试" + suffix
        }
        if value.contains("model"), ["not found", "notfound", "not exist", "unsupported", "not support"].contains(where: { value.contains($0) }) {
            return "该服务地址不提供模型 \(model)，请核对模型 ID 或更换服务平台" + suffix
        }
        return "千问实时识别失败，请检查模型权限、账户额度与接口配置" + suffix
    }
    static func connectionError(_ socket: URLSessionWebSocketTask, _ error: Error, key: String) -> String {
        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status != 101 {
            switch status {
            case 401, 403:
                return "千问拒绝连接（HTTP \(status)）：API Key 无效，或密钥与服务地址不属于同一平台/区域。千问AI平台的密钥对应 maas.qianwenaiapi.com，阿里云百炼对应 dashscope.aliyuncs.com（新加坡为 dashscope-intl.aliyuncs.com）"
            case 404: return "服务地址不存在（HTTP 404），请核对 WebSocket 地址与模型 ID"
            case 429: return "千问请求受限或额度不足（HTTP 429），请稍后重试"
            case 500...599: return "千问服务暂时不可用（HTTP \(status)），请稍后重试"
            default: return "千问拒绝了实时连接（HTTP \(status)），请核对服务地址、模型 ID 与 API Key"
            }
        }
        if socket.closeCode != .invalid {
            let reason = serverDetail([socket.closeReason.map { String(decoding: $0, as: UTF8.self) }], key: key)
            let detail = reason.isEmpty ? String(socket.closeCode.rawValue) : String(socket.closeCode.rawValue) + "：" + reason
            return "千问关闭了实时连接（\(detail)），请检查模型权限与接口配置"
        }
        let host = socket.originalRequest?.url?.host ?? ""
        guard let code = (error as? URLError)?.code else { return "千问实时连接中断，请检查网络、服务地址和 API Key" }
        switch code {
        case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址 \(host)，请检查网络和地址拼写"
        case .notConnectedToInternet: return "网络未连接，请检查网络后重试"
        case .timedOut: return "连接 \(host) 超时，请检查网络、代理或防火墙设置"
        case .cannotConnectToHost: return "无法连接到 \(host)，请检查网络、代理或防火墙设置"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "与 \(host) 的安全连接失败，请检查代理、防火墙或系统时间"
        default: return "千问实时连接中断（错误 \(code.rawValue)），请检查网络、服务地址和 API Key"
        }
    }
}
