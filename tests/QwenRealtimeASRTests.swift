import Foundation

struct TestFailure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message:message) }
}

@main struct QwenRealtimeASRTests {
    @MainActor static func main() async throws {
        let config = QwenRealtimeASRConfiguration(endpoint:QwenRealtimeASRConfiguration.endpoint,
                                                 model:QwenRealtimeASRConfiguration.model, language:"Chinese")
        try check(try config.url().query == "model=qwen-audio-3.1-realtime-plus", "correct model query")
        let session = config.sessionUpdate()["session"] as! [String:Any]
        try check(session["turn_detection"] is NSNull, "manual mode avoids automatic replies")
        try check((session["input_audio_transcription"] as? [String:String])?["language"] == "zh", "input language")
        let merged = config.sessionUpdate(created:["input_audio_transcription":["model":"qwen3-asr-flash-realtime"]])["session"] as! [String:Any]
        try check((merged["input_audio_transcription"] as? [String:String]) == ["model":"qwen3-asr-flash-realtime", "language":"zh"], "language hint keeps the server's ASR model")
        let auto = QwenRealtimeASRConfiguration(endpoint:config.endpoint, model:config.model).sessionUpdate()["session"] as! [String:Any]
        try check(auto["input_audio_transcription"] == nil && Set(auto.keys) == ["modalities", "input_audio_format", "turn_detection"], "auto language sends only documented fields")
        let minimal = config.sessionUpdate(minimal:true)["session"] as! [String:Any]
        try check(Set(minimal.keys) == ["turn_detection"] && minimal["turn_detection"] is NSNull, "minimal update keeps manual commit only")
        for (endpoint, expected) in [("https://maas.qianwenaiapi.com/compatible-mode/v1", "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"),
                                     ("https://dashscope.aliyuncs.com/api/v1/", "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"),
                                     ("wss://MAAS.QianwenAIAPI.com:443", "wss://maas.qianwenaiapi.com/api-ws/v1/realtime"),
                                     ("wss://ws.example.com/custom/realtime?model=old", "wss://ws.example.com/custom/realtime")] {
            try check(try QwenRealtimeASRConfiguration(endpoint:endpoint, model:config.model).normalizedEndpoint() == expected, "endpoint normalized: " + endpoint)
        }
        try check(QwenRealtimeASRConfiguration.manualCommitConfirmed([:]) && QwenRealtimeASRConfiguration.manualCommitConfirmed(["turn_detection":NSNull()]), "omitted or null turn detection is manual")
        try check(!QwenRealtimeASRConfiguration.manualCommitConfirmed(nil) &&
                  !QwenRealtimeASRConfiguration.manualCommitConfirmed(["turn_detection":["type":"server_vad"]]) &&
                  !QwenRealtimeASRConfiguration.manualCommitConfirmed(["audio":["input":["turn_detection":["type":"smart_turn"]]]]), "automatic turn detection rejected")
        let service = QwenRealtimeASRClient.serviceError(["code":"InvalidApiKey", "message":"Invalid key sk-secret\n"], key:"sk-secret", model:config.model)
        try check(service.contains("InvalidApiKey") && service.contains("API Key") && !service.contains("sk-secret") && !service.contains("\n"), "server reason shown with key masked")
        for endpoint in ["https://example.com/realtime", "http://maas.qianwenaiapi.com/api/v1", "ws://example.com/realtime", "wss://user:secret@example.com/realtime", "wss://example.com/realtime?key=secret", "wss://example.com/realtime#secret"] {
            var rejected = false
            do { _ = try QwenRealtimeASRConfiguration(endpoint:endpoint, model:config.model).url() } catch { rejected = true }
            try check(rejected, "unsafe endpoint rejected")
        }
        guard let base = ProcessInfo.processInfo.environment["RECORDER_QWEN_MOCK"] else { throw TestFailure(message:"Use scripts/test_qwen_asr.sh") }
        let pcm = Data(Array(repeating:[UInt8(1), UInt8(2)], count:3200).flatMap { $0 })
        for _ in 0..<2 {
            let client = QwenRealtimeASRClient(timeout:2, allowLocalhost:true)
            var deltas: [String] = []
            let text = try await client.transcribe(configuration:.init(endpoint:base + "/ok", model:config.model), key:"mock-only", pcm:pcm) { deltas.append($0) }
            try check(text == "你好，世界🌏。" && deltas == ["你好🌏", "你好，世界"], "input transcript only; tentative text replaced; final authoritative; duplicate ignored")
            let empty = try await client.transcribe(configuration:.init(endpoint:base + "/ok", model:config.model), key:"mock-only", pcm:nil)
            try check(empty.isEmpty, "connection test sends no audio")
        }
        let client = QwenRealtimeASRClient(timeout:2, allowLocalhost:true)
        let hinted = try await client.transcribe(configuration:.init(endpoint:base + "/ok", model:config.model, language:"Chinese"), key:"mock-only", pcm:pcm)
        try check(hinted == "你好，世界🌏。", "language hint accepted by the service")
        let sparse = try await client.transcribe(configuration:.init(endpoint:base + "/sparse", model:config.model), key:"mock-only", pcm:pcm)
        try check(sparse == "你好，世界🌏。", "session echo without turn_detection is manual commit")
        for _ in 0..<2 {
            let fallback = try await client.transcribe(configuration:.init(endpoint:base + "/no-language", model:config.model, language:"Chinese"), key:"mock-only", pcm:pcm)
            try check(fallback == "你好，世界🌏。", "rejected configuration falls back to the minimal update once")
        }
        do {
            _ = try await client.transcribe(configuration:.init(endpoint:base + "/error", model:config.model), key:"mock-only", pcm:nil)
            throw TestFailure(message:"service error expected")
        } catch let failure as AIError {
            let text = failure.localizedDescription
            try check(text.contains("Throttling.AllocationQuota") && text.contains("额度") && !text.contains("mock-only"), "service error shows the server reason without the key")
        }
        for path in ["/unauthorized", "/redirect", "/error", "/closed", "/wrong-mode", "/disconnect", "/timeout", "/failed"] {
            var error: String?
            do {
                _ = try await QwenRealtimeASRClient(timeout:0.3, allowLocalhost:true).transcribe(configuration:.init(endpoint:base + path, model:config.model), key:"mock-only", pcm:pcm)
            } catch let failure { error = failure.localizedDescription }
            try check(error != nil && !error!.contains("mock-only"), "safe failure: " + path)
        }
        let cancelled = Task {
            try await QwenRealtimeASRClient(timeout:2, allowLocalhost:true).transcribe(configuration:.init(endpoint:base + "/timeout", model:config.model), key:"mock-only", pcm:pcm)
        }
        try await Task.sleep(nanoseconds:100_000_000); cancelled.cancel()
        var didCancel = false
        do { _ = try await cancelled.value } catch { didCancel = true }
        try check(didCancel, "cancel interrupts pending recognition")
        print("PASS: Qwen WSS configuration, endpoint normalization, manual commit, language hint fallback, exact PCM, input ASR events, Unicode, duplicate handling, no assistant response, connection test, errors, timeout and cancellation")
    }
}
