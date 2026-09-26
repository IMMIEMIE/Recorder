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
        let session = config.sessionUpdate["session"] as! [String:Any]
        try check(session["turn_detection"] is NSNull, "manual mode avoids automatic replies")
        try check((session["input_audio_transcription"] as? [String:String])?["language"] == "zh", "input language")
        for endpoint in ["https://example.com/realtime", "ws://example.com/realtime", "wss://user:secret@example.com/realtime", "wss://example.com/realtime?key=secret", "wss://example.com/realtime#secret"] {
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
        for path in ["/unauthorized", "/redirect", "/error", "/wrong-mode", "/disconnect", "/timeout", "/failed"] {
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
        print("PASS: Qwen WSS configuration, manual commit, exact PCM, input ASR events, Unicode, duplicate handling, no assistant response, connection test, errors, timeout and cancellation")
    }
}
