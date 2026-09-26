import Foundation

struct QwenRealtimeASRConfiguration {
    static let endpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"
    static let model = "qwen-audio-3.1-realtime-plus"
    var endpoint: String
    var model: String
    var language = "auto"

    func url(allowLocalhost: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, !parts.path.isEmpty, parts.path != "/",
              parts.scheme == "wss" || (allowLocalhost && parts.scheme == "ws" && host == "127.0.0.1"),
              (parts.queryItems ?? []).allSatisfy({ $0.name == "model" }),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.contains("\n"), !model.contains("\r") else {
            throw AIError.message("请填写有效的 WSS 实时接口地址和模型 ID")
        }
        parts.queryItems = [URLQueryItem(name: "model", value: model.trimmingCharacters(in: .whitespacesAndNewlines))]
        guard let url = parts.url else { throw AIError.message("千问实时接口地址无效") }
        return url
    }
    func normalizedEndpoint() throws -> String {
        var parts = URLComponents(url: try url(), resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        return parts.url!.absoluteString
    }
    var sessionUpdate: [String: Any] {
        var session: [String: Any] = ["modalities": ["text"], "input_audio_format": "pcm",
                                    "turn_detection": NSNull()]
        let code = ["Chinese":"zh", "Cantonese":"zh", "English":"en", "Japanese":"ja", "Korean":"ko"][language]
        if let code { session["input_audio_transcription"] = ["language":code] }
        return ["type":"session.update", "session":session]
    }
}

/// Commit input audio without response.create: display ASR, never the assistant's answer.
final class QwenRealtimeASRClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
            group.addTask { try await self.receive(socket, configuration: configuration, pcm: pcm, onText: onText) }
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
    private func receive(_ socket: URLSessionWebSocketTask, configuration: QwenRealtimeASRConfiguration, pcm: Data?,
                         onText: @escaping @MainActor @Sendable (String) async -> Void) async throws -> String {
        var configured = false, submitted = false
        var text = "", itemID: String?
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() }
            catch {
                try Task.checkCancellation()
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                if status == 401 || status == 403 { throw AIError.message("千问 API Key 无效或无权访问此模型，请核对平台与模型权限") }
                if status == 429 { throw AIError.message("千问请求受限或额度不足，请稍后重试") }
                throw AIError.message("千问实时连接中断，请检查网络、服务地址和 API Key")
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
                try await send(socket, configuration.sessionUpdate)
            case "session.updated":
                guard configured, !submitted else { continue }
                guard let value = event["session"] as? [String: Any],
                      value["modalities"] as? [String] == ["text"], value["turn_detection"] is NSNull else {
                    throw AIError.message("千问未确认手动提交模式，请检查模型与接口；音频尚未发送")
                }
                guard let pcm else { return "" } // Connection test never uploads audio.
                submitted = true
                for offset in stride(from: 0, to: pcm.count, by: 3200) {
                    try Task.checkCancellation()
                    try await send(socket, ["type":"input_audio_buffer.append",
                                            "audio":pcm.subdata(in: offset..<min(offset + 3200, pcm.count)).base64EncodedString()])
                }
                try await send(socket, ["type":"input_audio_buffer.commit"])
            case "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed":
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
                if let confirmed = event["text"] as? String {
                    text = confirmed + (event["stash"] as? String ?? "")
                } else { text += event["delta"] as? String ?? "" }
                guard text.utf8.count <= 200_000 else { throw AIError.message("千问转写结果过长") }
                await onText(text)
            case "error", "conversation.item.input_audio_transcription.failed":
                let code = (event["error"] as? [String: Any])?["code"] as? String ?? ""
                if code.lowercased().contains("auth") || code.lowercased().contains("key") {
                    throw AIError.message("千问 API Key 无效或无权访问此模型")
                }
                throw AIError.message("千问实时识别失败，请检查模型权限、账户额度与接口配置")
            default: break // response.* is an assistant response, not the input transcript.
            }
        }
    }
}
