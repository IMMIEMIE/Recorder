import Foundation

/// Qwen-Audio-3.0-ASR-Flash-Streaming over the DashScope duplex WebSocket protocol:
/// run-task → task-started → binary PCM → result-generated → finish-task → task-finished.
/// Endpoint and model are fixed; only the API key is user-configurable (tests override the endpoint).
struct StreamingASRConfiguration {
    static let endpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/inference"
    static let model = "qwen-audio-3.0-asr-flash-streaming"
    /// Keychain account of the key.
    static let keyAccount = "asr:" + endpoint
    var endpoint = Self.endpoint
    var language = "auto"
    var silenceMS = 1300

    func url(allowLocalhost: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, !parts.path.isEmpty, parts.path != "/",
              parts.scheme == "wss" || (allowLocalhost && parts.scheme == "ws" && host == "127.0.0.1"),
              let url = parts.url else {
            throw AIError.message("流式识别接口地址无效")
        }
        return url
    }
    func runTask(_ taskID: String) -> [String: Any] {
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16000,
                                         "max_sentence_silence": min(6000, max(200, silenceMS)),
                                         // Keeps the task alive through long silences; heartbeat results are skipped.
                                         "heartbeat": true]
        let code = ["Chinese": "zh", "Cantonese": "zh", "English": "en", "Japanese": "ja", "Korean": "ko"][language]
        if let code { parameters["language_hints"] = [code] }
        return ["header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
                "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                            "model": Self.model,
                            "parameters": parameters, "input": [String: Any]()] as [String: Any]]
    }
}

/// All transport state lives on one serial queue; audio producers only enqueue bounded data.
final class StreamingASRClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var onReady: (() -> Void)?
    var onPartial: ((String) -> Void)?
    /// Sentence id (from 1 within a task), text, and sentence start in milliseconds.
    var onFinal: ((Int, String, Int) -> Void)?
    /// nil after task-finished following finish(); otherwise a user-facing reason.
    var onEnd: ((String?) -> Void)?
    private let queue = DispatchQueue(label: "recorder.streaming-asr")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var key = ""
    private let taskID = UUID().uuidString.lowercased()
    private var pending: [(URLSessionWebSocketTask.Message, Int)] = []
    private var chunk = Data()
    private var buffered = 0
    private var sending = false
    private var ready = false
    private var finishing = false
    private var closed = false
    private var deadline: DispatchWorkItem?
    private let connectTimeout: TimeInterval
    private let finishTimeout: TimeInterval
    private let allowLocalhost: Bool

    init(connectTimeout: TimeInterval = 20, finishTimeout: TimeInterval = 30, allowLocalhost: Bool = false) {
        self.connectTimeout = connectTimeout; self.finishTimeout = finishTimeout; self.allowLocalhost = allowLocalhost
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func connect(configuration: StreamingASRConfiguration, key: String) throws {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw AIError.message("请保存识别服务的 API Key") }
        var request = URLRequest(url: try configuration.url(allowLocalhost: allowLocalhost))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 30
        let task = configuration.runTask(taskID)
        queue.sync {
            self.key = key
            let session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 2_000_000
            self.socket = socket
            socket.resume()
            armTimeout(connectTimeout, message: "识别服务连接或任务启动超时，请检查网络和服务地址")
            enqueueJSON(task)
            receive()
        }
    }
    /// Coalesces capture callbacks into ~100 ms binary frames, as the service recommends.
    func append(_ data: Data) -> Bool {
        queue.sync {
            guard ready, !finishing, !closed, buffered + chunk.count + data.count <= 320_000 else { return false }
            chunk.append(data)
            if chunk.count >= 3200 { flushChunk() }
            return true
        }
    }
    func finish() {
        queue.async {
            guard self.ready, !self.closed, !self.finishing else { return }
            self.finishing = true
            self.flushChunk()
            self.armTimeout(self.finishTimeout, message: "识别服务尾句处理超时，已保留收到的文字，末句可能不完整")
            self.enqueueJSON(["header": ["action": "finish-task", "task_id": self.taskID, "streaming": "duplex"],
                              "payload": ["input": [String: Any]()]])
        }
    }
    func cancel() { queue.sync { end(nil, notify: false) } }

    private func flushChunk() {
        guard !chunk.isEmpty else { return }
        let data = chunk; chunk = Data()
        buffered += data.count; pending.append((.data(data), data.count)); sendNext()
    }
    private func enqueueJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { end("识别请求编码失败"); return }
        pending.append((.string(String(decoding: data, as: UTF8.self)), 0)); sendNext()
    }
    private func armTimeout(_ seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end(message) }
        deadline = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func sendNext() {
        guard !closed, !sending, !pending.isEmpty, let socket else { return }
        sending = true
        let (message, bytes) = pending.removeFirst()
        socket.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.sending = false; self.buffered -= bytes
                if let error { self.end(self.connectionError(error)) } else { self.sendNext() }
            }
        }
    }
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure(let error): self.end(self.connectionError(error))
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: self.end("识别服务返回未知消息格式"); return
                    }
                    guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let header = event["header"] as? [String: Any], let name = header["event"] as? String else {
                        self.end("识别服务返回无效数据"); return
                    }
                    guard header["task_id"] as? String == self.taskID else { self.receive(); return }
                    switch name {
                    case "task-started":
                        guard !self.ready else { break }
                        self.ready = true; self.deadline?.cancel()
                        let callback = self.onReady; DispatchQueue.main.async { callback?() }
                    case "result-generated":
                        self.result(event)
                    case "task-finished":
                        self.end(self.finishing ? nil : "识别任务意外结束，已保留收到的文字"); return
                    case "task-failed":
                        let code = header["error_code"] as? String ?? "", detail = header["error_message"] as? String ?? ""
                        let reason = Self.redact([code, detail].filter { !$0.isEmpty }.joined(separator: "："), key: self.key)
                        self.end("识别服务任务失败" + (reason.isEmpty ? "，请检查模型权限和账户额度" : "：" + reason)); return
                    default: break
                    }
                    self.receive()
                }
            }
        }
    }
    private func result(_ event: [String: Any]) {
        guard let sentence = ((event["payload"] as? [String: Any])?["output"] as? [String: Any])?["sentence"] as? [String: Any],
              sentence["heartbeat"] as? Bool != true, let text = sentence["text"] as? String, text.utf8.count <= 200_000 else { return }
        if sentence["sentence_end"] as? Bool == true {
            guard let id = sentence["sentence_id"] as? Int, id > 0 else { return }
            let begin = max(0, sentence["begin_time"] as? Int ?? 0)
            let callback = onFinal; DispatchQueue.main.async { callback?(id, text, begin) }
        } else {
            let callback = onPartial; DispatchQueue.main.async { callback?(text) }
        }
    }
    /// Server text is shown to the user, so never echo the key and keep it short.
    static func redact(_ text: String, key: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "***") }
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }
    private func connectionError(_ error: Error) -> String {
        let reason = socket?.closeReason.map { Self.redact(String(decoding: $0, as: UTF8.self), key: key) } ?? ""
        let detail = reason.isEmpty ? "" : "（\(reason)）"
        switch (socket?.response as? HTTPURLResponse)?.statusCode {
        case 401?: return "识别服务 API Key 无效（HTTP 401）。请使用千问AI平台（qianwenai.com）的 API Key，阿里云百炼的密钥不能用于此服务"
        case 403?: return "识别服务拒绝访问（HTTP 403）：此 API Key 未开通该模型或业务空间权限" + detail
        case 404?: return "识别服务地址不存在（HTTP 404）"
        case 429?: return "识别服务请求受限或额度不足（HTTP 429），请稍后重试"
        case let status? where status != 101: return "识别服务返回 HTTP \(status)" + detail
        default:
            if ready || !reason.isEmpty { return "识别服务连接被关闭" + (reason.isEmpty ? "，已保留收到的文字" : "：" + reason) }
            return "无法连接识别服务：" + Self.redact(error.localizedDescription, key: key)
        }
    }
    private func end(_ error: String?, notify: Bool = true) {
        guard !closed else { return }
        closed = true; ready = false; deadline?.cancel(); deadline = nil
        pending.removeAll(); chunk = Data(); buffered = 0
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        if notify { let callback = onEnd; DispatchQueue.main.async { callback?(error) } }
    }
}
