import Foundation

struct TestFailure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message:message) }
}

@MainActor final class Collected {
    var ready = false
    var partials: [String] = []
    var finals: [(Int, String, Int)] = []
    var ended = false
    var error: String?
    func wait(_ condition: () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw TestFailure(message:"timed out") }
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }
}

@main struct StreamingASRTests {
    @MainActor static func attach(_ client: StreamingASRClient) -> Collected {
        let collected = Collected()
        client.onReady = { collected.ready = true }
        client.onPartial = { collected.partials.append($0) }
        client.onFinal = { collected.finals.append(($0, $1, $2)) }
        client.onEnd = { collected.ended = true; collected.error = $0 }
        return collected
    }

    @MainActor static func main() async throws {
        let config = StreamingASRConfiguration(language:"Chinese", silenceMS:800)
        try check(try config.url().absoluteString == "wss://maas.qianwenaiapi.com/api-ws/v1/inference", "fixed endpoint; model is not a URL query")
        try check((config.runTask("t")["payload"] as! [String:Any])["model"] as? String == "qwen-audio-3.0-asr-flash-streaming", "fixed model")
        try check(StreamingASRConfiguration.keyAccount == "asr:wss://maas.qianwenaiapi.com/api-ws/v1/inference", "key account")
        let parameters = (config.runTask("t")["payload"] as! [String:Any])["parameters"] as! [String:Any]
        try check(parameters["language_hints"] as? [String] == ["zh"] && parameters["max_sentence_silence"] as? Int == 800, "language and pause")
        let auto = StreamingASRConfiguration(silenceMS:50)
        let autoParameters = (auto.runTask("t")["payload"] as! [String:Any])["parameters"] as! [String:Any]
        try check(autoParameters["language_hints"] == nil && autoParameters["max_sentence_silence"] as? Int == 200, "auto language, clamped pause")
        for endpoint in ["https://example.com/api-ws/v1/inference", "ws://example.com/api-ws/v1/inference",
                         "wss://user:secret@example.com/api-ws/v1/inference", "wss://example.com/api-ws/v1/inference?key=secret",
                         "wss://example.com/api-ws/v1/inference#secret", "wss://example.com"] {
            var rejected = false
            do { _ = try StreamingASRConfiguration(endpoint:endpoint).url() } catch { rejected = true }
            try check(rejected, "unsafe endpoint rejected: " + endpoint)
        }
        guard let base = ProcessInfo.processInfo.environment["RECORDER_STREAMING_MOCK"] else { throw TestFailure(message:"Use scripts/test_streaming_asr.sh") }
        func configuration(_ path: String) -> StreamingASRConfiguration {
            StreamingASRConfiguration(endpoint:base + path, language:"Chinese", silenceMS:800)
        }

        for _ in 0..<2 {
            let client = StreamingASRClient(allowLocalhost:true)
            let events = attach(client)
            try client.connect(configuration:configuration("/ok"), key:"mock-only")
            try check(!client.append(Data([1, 2])), "no audio before task-started")
            try await events.wait { events.ready }
            let pcm = Data(Array(repeating:[UInt8(1), UInt8(2)], count:3200).flatMap { $0 })
            for offset in stride(from:0, to:pcm.count, by:1000) {
                try check(client.append(pcm.subdata(in:offset..<min(offset + 1000, pcm.count))), "audio accepted")
            }
            try await events.wait { !events.partials.isEmpty }
            client.finish()
            try await events.wait { events.ended }
            try check(events.error == nil, "clean finish: \(events.error ?? "")")
            try check(events.partials == ["", "你好"], "partials stream while speaking; heartbeat skipped: \(events.partials)")
            try check(events.finals.map(\.0) == [1, 2] && events.finals.map(\.1) == ["你好，世界🌏。", "第二句"] && events.finals.map(\.2) == [170, 1000],
                      "sentence ends become finals in order before the end callback")
        }

        let probe = StreamingASRClient(allowLocalhost:true)
        let probed = attach(probe)
        try probe.connect(configuration:configuration("/ok"), key:"mock-only")
        try await probed.wait { probed.ready }
        probe.cancel()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(!probed.ended && !probe.append(Data([1, 2])), "connection test closes silently after task-started")

        var errors: [String:String] = [:]
        for path in ["/unauthorized", "/redirect", "/failed", "/closed", "/early-end", "/timeout", "/finish-timeout"] {
            let client = StreamingASRClient(connectTimeout:0.5, finishTimeout:0.5, allowLocalhost:true)
            let events = attach(client)
            try client.connect(configuration:configuration(path), key:"mock-only")
            if path == "/finish-timeout" {
                try await events.wait { events.ready }
                _ = client.append(Data(repeating:1, count:3200)); client.finish()
            }
            try await events.wait { events.ended }
            let error = events.error ?? ""
            try check(!error.isEmpty && !error.contains("mock-only"), "safe failure: " + path)
            errors[path] = error
        }
        try check(errors["/unauthorized"]!.contains("401"), "HTTP status shown: " + errors["/unauthorized"]!)
        try check(errors["/failed"]!.contains("InvalidParameter") && errors["/failed"]!.contains("Quota exceeded for key ***"),
                  "task-failed reason shown with key redacted: " + errors["/failed"]!)
        try check(errors["/closed"]!.contains("Access denied for model"), "close reason shown: " + errors["/closed"]!)
        try check(errors["/early-end"]!.contains("意外结束"), "unexpected task end: " + errors["/early-end"]!)
        try check(errors["/timeout"]!.contains("超时") && errors["/finish-timeout"]!.contains("尾句"), "connect and finish timeouts")
        print("PASS: streaming ASR configuration, run-task, ~100 ms binary PCM frames, partial and final sentences, heartbeat and foreign-task filtering, connection test, errors, redaction and timeouts")
    }
}
