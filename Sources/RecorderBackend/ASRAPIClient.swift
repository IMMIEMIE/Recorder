import Foundation

/// OpenAI-compatible audio transcription requests; credentials live only in memory.
final class APIRecognizer: APIRecognizing {
    private(set) var config: ModelConfig?
    private(set) var key = ""

    /// Set by RedirectBlocker when a 3xx was refused; 0 means none.
    static var lastRedirect = 0

    func load(config: ModelConfig, key: String) throws {
        if key.isEmpty || key.contains("\r") || key.contains("\n") {
            throw BackendError.value("请填写有效的识别 API Key")
        }
        self.config = config
        self.key = key
    }

    func clearKey() { key = "" }

    private static let languages = ["Chinese": "zh", "English": "en", "Cantonese": "yue", "Japanese": "ja", "Korean": "ko"]

    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        guard let config, !key.isEmpty else { throw BackendError.value("识别 API 尚未配置") }
        let start = backendNow()
        let (body, boundary) = Data.multipartBody(pcm: pcm, config: config, languages: Self.languages)
        var request = URLRequest(url: URL(string: config.apiBaseURL + "/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let status: Int
        do {
            let (payload, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackendError.value("无法连接识别 API：无效响应") }
            data = payload
            status = http.statusCode
        } catch let error as BackendError {
            throw error
        } catch {
            let redirect = APIRecognizer.lastRedirect
            APIRecognizer.lastRedirect = 0
            if (300...399).contains(redirect) {
                throw BackendError.value("识别 API 返回 HTTP \(redirect)；请检查地址、模型、密钥或额度")
            }
            let reason = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            throw BackendError.value("无法连接识别 API：\(reason)")
        }
        if (400...599).contains(status) {
            throw BackendError.value("识别 API 返回 HTTP \(status)；请检查地址、模型、密钥或额度")
        }
        if !(200...299).contains(status) {
            throw BackendError.value("识别 API 返回 HTTP \(status)")
        }
        if data.count > 2_000_000 { throw BackendError.value("识别 API 返回内容过长") }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = result["text"] as? String else {
            throw BackendError.value("识别 API 未返回 JSON 文本，请确认兼容音频转写接口")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), Int((backendNow() - start) * 1000))
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            APIRecognizer.lastRedirect = response.statusCode
            completionHandler(nil)
        }
    }
}

extension Data {
    /// Multipart request with a per-request boundary; the audio file is wrapped in a RIFF/WAVE header.
    static func multipartBody(pcm: Data, config: ModelConfig, languages: [String: String]) -> (body: Data, boundary: String) {
        let boundary = "recorder-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var wav = Data()
        func appendLE<T>(_ value: T, to data: inout Data) {
            Swift.withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        wav.append(Data("RIFF".utf8))
        appendLE(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        appendLE(UInt32(16), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt32(Backend.rate), to: &wav)
        appendLE(UInt32(Backend.rate * 2), to: &wav)
        appendLE(UInt16(2), to: &wav)
        appendLE(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLE(UInt32(pcm.count), to: &wav)
        wav.append(pcm)

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", config.apiModel)
        if let language = languages[config.language] { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, boundary)
    }
}
