import Foundation

struct TestFailure: Error { let message: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}
func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw TestFailure(message: "Expected an error")
}
actor Output {
    var value = ""
    func append(_ text: String) { value += text }
}
@main struct Tests {
    static func main() async throws {
        for endpoint in ["http://example.com/v1/chat/completions", "https://user:password@example.com/chat", "https://example.com/chat?key=x", "file:///tmp/test", "https://example.com/"] {
            try rejects { _ = try AIServiceConfiguration(endpoint: endpoint, model: "model").url() }
        }
        try expect(try AIServiceConfiguration(endpoint: "http://127.0.0.1:1234/v1/chat/completions", model: "local").url().host == "127.0.0.1", "local endpoint")
        try rejects { _ = try AIServiceConfiguration(endpoint: "https://example.com/chat", model: " ").url() }
        let normalizedBase = try AIProfile.normalize(" HTTPS://EXAMPLE.COM:443/v1/chat/completions/ ")
        try expect(normalizedBase == "https://example.com/v1", "base URL normalization")
        try expect(AIProfile(baseURL: normalizedBase, modelID: "test").configuration.endpoint == "https://example.com/v1/chat/completions", "endpoint derivation")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AIProfileFiles(directory: folder)
        try files.save(AIProfile(baseURL: normalizedBase, modelID: "first"))
        try files.save(AIProfile(baseURL: "https://other.example/v1", modelID: "second"))
        try files.save(AIProfile(baseURL: normalizedBase, modelID: "updated"))
        let reloaded = try AIProfileFiles(directory: folder).load()
        try expect(reloaded.count == 2, "one file per base URL")
        try expect(reloaded.first { $0.baseURL == normalizedBase }?.modelID == "updated", "persistent model update")
        try files.remove(AIProfile(baseURL: normalizedBase, modelID: "updated"))
        try expect(try files.load().count == 1, "independent profile deletion")
        let request = try AIClient.request(config: .init(), key: "test-secret", instruction: "翻译", text: "Hello\n你好 \"quoted\"")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret", "authorization header")
        try expect(!request.url!.absoluteString.contains("test-secret"), "key in URL")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
        try expect(body["stream"] as? Bool == true, "streaming flag")
        try expect(!String(data: request.httpBody!, encoding: .utf8)!.contains("test-secret"), "key in body")
        try expect((body["thinking"] as? [String:String])?["type"] == "disabled", "DeepSeek reasoning option")
        let custom = try AIClient.request(config: .init(endpoint: "https://example.com/chat", model: "custom-model"), key: "test", instruction: "总结", text: "测试")
        let customBody = try JSONSerialization.jsonObject(with: custom.httpBody!) as! [String:Any]
        try expect(customBody["thinking"] == nil, "provider option leaked")
        try expect(customBody["model"] as? String == "custom-model", "model override")
        try rejects { _ = try AIClient.request(config: .init(), key: "test", instruction: "总结", text: String(repeating: "中", count: 110_000)) }
        try rejects { _ = try AIClient.request(config: .init(), key: "", instruction: "总结", text: "test") }
        try rejects { _ = try AIClient.request(config: .init(), key: "key", instruction: "", text: "test") }
        try expect(try AIStreamEvent.parse(#"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#).text == "你好", "Unicode delta")
        try expect(try AIStreamEvent.parse("[DONE]").finished, "done marker")
        try rejects { _ = try AIStreamEvent.parse("not json") }
        try rejects { _ = try AIStreamEvent.parse(#"{"error":{"message":"secret"}}"#) }
        guard let base = ProcessInfo.processInfo.environment["RECORDER_MOCK_URL"] else { throw TestFailure(message: "Use scripts/test_ai.sh") }
        func config(_ path: String) -> AIServiceConfiguration { .init(endpoint: base + path, model: "mock-model") }
        let output = Output()
        try await AIClient().stream(config: config("/ok"), key: "mock-key", instruction: "总结", text: "synthetic test") { text in await output.append(text) }
        let result = await output.value
        try expect(result == "你好，世界🌏", "SSE Unicode fragments and keepalive")
        for path in ["/unauthorized", "/redirect", "/malformed", "/truncated", "/length"] {
            var failed = false
            do { try await AIClient().stream(config: config(path), key: "mock-key", instruction: "总结", text: "synthetic test") { _ in } }
            catch { failed = true; try expect(!error.localizedDescription.contains("mock-key"), "secret in error") }
            try expect(failed, "Expected failure for \(path)")
        }
        let task = Task { try await AIClient().stream(config: config("/slow"), key: "mock-key", instruction: "总结", text: "test") { _ in } }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        var cancelled = false
        do { try await task.value } catch { cancelled = true }
        try expect(cancelled, "cancellation")
        print("PASS: endpoint validation, credential isolation, request encoding, input bounds, SSE parser, Unicode streaming, HTTP errors, redirect rejection, malformed/truncated responses, output limit and cancellation")
    }
}
