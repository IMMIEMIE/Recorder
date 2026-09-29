import Foundation

// Port of tests/test_core.py, test_endpoint.py and test_translation.py against the in-process backend.

struct TestFailure: Error { let message: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}
func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw TestFailure(message: "Expected an error")
}

let PCM: Data = {
    var data = Data()
    data.reserveCapacity(Backend.frame * 2)
    for _ in 0..<Backend.frame { data.append(contentsOf: [0x01, 0x02]) }
    return data
}()

func pcmFrames(_ count: Int) -> Data {
    var data = Data()
    data.reserveCapacity(count * PCM.count)
    for _ in 0..<count { data.append(PCM) }
    return data
}

final class EventRecorder: BackendEventSink {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    func deliver(_ event: [String: Any]) {
        lock.lock(); events.append(event); lock.unlock()
    }
    func clear() { lock.lock(); events.removeAll(); lock.unlock() }
    var all: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    func last(_ type: String) -> [String: Any]? { all.last { $0["type"] as? String == type } }
    func of(_ type: String) -> [[String: Any]] { all.filter { $0["type"] as? String == type } }
}

final class FakeASREngine: ASREngine {
    var isLoaded = true
    var calls: [Data] = []
    var text = "重复重复"
    func load(config: ModelConfig, path: String) async throws {}
    func warmup() async throws {}
    func unload() async { isLoaded = false }
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        calls.append(pcm)
        return (text, 1)
    }
}

final class FakeAPIRecognizer: APIRecognizing {
    var key = ""
    var calls: [Data] = []
    var text = "API 转写"
    func load(config: ModelConfig, key: String) throws { self.key = key }
    func clearKey() { key = "" }
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        calls.append(pcm)
        return (text, 5)
    }
}

final class FakeTranslatorEngine: TranslatorEngine {
    var isLoaded = true
    var modelID = "owner/fake"
    var calls: [(text: String, target: String, context: [(String, String)])] = []
    var onToken: (@Sendable () async -> Void)?
    func load(config: TranslationConfig, path: String) async throws {}
    func warmup() async throws {}
    func unload() async { isLoaded = false; modelID = "" }
    func stream(_ text: String, target: String, context: [(String, String)]) -> AsyncThrowingStream<String, Error> {
        calls.append((text, target, context))
        let onToken = onToken
        return AsyncThrowingStream { continuation in
            let task = Task {
                var result = ""
                for piece in ["Hello", " world", "."] {
                    if let onToken { await onToken() }
                    result += piece
                    continuation.yield(result)
                }
                continuation.finish()
            }
            _ = task
        }
    }
}

func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-backend-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func command(_ name: String, session: String = "test", extra: [String: Any] = [:]) -> [String: Any] {
    var body: [String: Any] = ["command": name, "protocol_version": 1, "session_id": session, "request_id": "req"]
    for (key, value) in extra { body[key] = value }
    return body
}

func settle(_ core: BackendCore) async throws {
    for _ in 0..<100_000 {
        if !(await core.isBusy) { return }
        await Task.yield()
    }
    throw TestFailure(message: "backend did not settle")
}

func audioPayload(sequence: Int, start: Int, session: String = "test", pcm: Data = PCM) -> Data {
    let header = try! JSONSerialization.data(withJSONObject: ["session_id": session, "sequence": sequence,
                                                              "start_sample": start, "sample_rate": 16000,
                                                              "channels": 1, "format": "s16le"])
    var size = UInt32(header.count).bigEndian
    var payload = Data(bytes: &size, count: 4)
    payload.append(header)
    payload.append(pcm)
    return payload
}

func previewJob(_ revision: Int, final: Bool = false) -> SegmentJob {
    var job = SegmentJob()
    job.segmentID = 1
    job.revision = revision
    job.final = final
    job.pcm = PCM
    return job
}

// MARK: - Config

func testConfigInvalidAndAtomicSave() throws {
    for value in [["schema_version": 2], ["preview_interval_ms": 1], ["max_segment_seconds": 300],
                  ["endpoint_silence_ms": 299], ["endpoint_silence_ms": 2001], ["endpoint_silence_ms": true],
                  ["save_audio": true], ["language": "bogus"], ["model_id": "bad"]] as [[String: Any]] {
        try rejects { _ = try ModelConfig.parse(value) }
    }
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("config.json")
    try ModelConfig().save(path)
    let reloaded = try ModelConfig.parse(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any])
    try expect(reloaded == ModelConfig(), "config roundtrip")
    try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.tmp").path), "tmp removed")
    let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
    try expect(mode == 0o600, "config saved 0600")
}

func testAPIConfigValidatesAddress() throws {
    let values: [String: Any] = ["provider": "api", "api_base_url": "https://example.com/v1", "api_model": "speech-model"]
    try expect(try ModelConfig.parse(values).provider == "api", "api provider")
    for bad in ["http://example.com/v1", "https://user:pass@example.com/v1",
                "https://example.com/v1?key=secret", "https://example.com/v1/"] {
        var broken = values
        broken["api_base_url"] = bad
        try rejects { _ = try ModelConfig.parse(broken) }
    }
    var withKey = values
    withKey["api_key"] = "secret"
    try rejects { _ = try ModelConfig.parse(withKey) }
    var qwen = values
    qwen["api_protocol"] = "qwen_realtime"
    qwen["api_base_url"] = "wss://maas.qianwenaiapi.com/api-ws/v1/inference"
    try expect(try ModelConfig.parse(qwen).apiProtocol == "qwen_realtime", "qwen realtime")
    for bad in ["https://example.com/realtime", "ws://example.com/realtime", "wss://example.com/realtime?key=secret"] {
        qwen["api_base_url"] = bad
        try rejects { _ = try ModelConfig.parse(qwen) }
    }
}

func testTranslationConfigValidation() throws {
    try expect(TranslationConfig().targetLanguage == "简体中文", "default target")
    try expect(!TranslationConfig().enabled, "default disabled")
    try expect(try TranslationConfig.parse(TranslationConfig().asDict) == TranslationConfig(), "roundtrip")
    for value in [["schema_version": 2], ["enabled": 1], ["provider": "unknown"], ["api_profile": 12],
                  ["target_language": "Klingon"], ["model_id": "bad"], ["model_id": "owner/"], ["extra": true]] as [[String: Any]] {
        try rejects { _ = try TranslationConfig.parse(value) }
    }
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("translation.json")
    var config = TranslationConfig()
    config.enabled = true
    config.targetLanguage = "English"
    try config.save(path)
    let reloaded = try TranslationConfig.parse(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any])
    try expect(reloaded.targetLanguage == "English", "translation roundtrip")
    try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("translation.tmp").path), "tmp removed")
    let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
    try expect(mode == 0o600, "translation saved 0600")
}

// MARK: - Segmenter

func testSilenceNeverEmits() throws {
    var events: [SegmentJob] = []
    let segmenter = Segmenter(config: ModelConfig()) { events.append($0) }
    for _ in 0..<90_000 { try segmenter.feed(PCM, false) }
    segmenter.flush()
    try expect(events.isEmpty, "silence emits nothing")
}

func testPrerollFlushPreservesShortTail() throws {
    var events: [SegmentJob] = []
    let segmenter = Segmenter(config: ModelConfig()) { events.append($0) }
    for _ in 0..<20 { try segmenter.feed(PCM, false) }
    for _ in 0..<3 { try segmenter.feed(PCM, true) }
    segmenter.flush()
    segmenter.flush()
    try expect(events.count == 1, "one final")
    try expect(events[0].final, "final flag")
    try expect(events[0].startSample == 8 * Backend.frame, "preroll start")
    try expect(events[0].endSample == 23 * Backend.frame, "end sample")
    try expect(events[0].pcm.count == 15 * Backend.frame * 2, "pcm includes preroll")
}

func testPauseThresholdAndShortPauseReset() throws {
    for threshold in [300, 1000, 1500, 2000] {
        var events: [SegmentJob] = []
        var config = ModelConfig()
        config.endpointMode = "fixed"
        config.endpointSilenceMS = threshold
        config.previewIntervalMS = 10_000
        let segmenter = Segmenter(config: config) { events.append($0) }
        for _ in 0..<130 { try segmenter.feed(PCM, true) }
        for _ in 0..<(threshold / 20 - 1) { try segmenter.feed(PCM, false) }
        try expect(events.isEmpty, "no final before threshold")
        try segmenter.feed(PCM, true)  // Resumed speech resets the silence timer.
        for _ in 0..<(threshold / 20 - 1) { try segmenter.feed(PCM, false) }
        try expect(events.isEmpty, "reset preserves segment")
        try segmenter.feed(PCM, false)
        try expect(events.count == 1, "final after threshold")
        try expect(events[0].final, "final flag")
        try expect(!events[0].forcedCut, "never forced")
        segmenter.flush()
        try expect(events.count == 1, "flush adds nothing")
    }
}

func testLongSpeechPreviewsButWaitsForPauseToFinalize() throws {
    var events: [SegmentJob] = []
    var config = ModelConfig()
    config.endpointMode = "fixed"
    config.maxSegmentSeconds = 5
    let segmenter = Segmenter(config: config) { events.append($0) }
    for _ in 0..<1600 { try segmenter.feed(PCM, true) }
    try expect(!events.isEmpty, "previews emitted")
    try expect(events.allSatisfy { !$0.final }, "previews only")
    for _ in 0..<50 { try segmenter.feed(PCM, false) }
    let finals = events.filter(\.final)
    try expect(finals.count == 1, "one final after pause")
    try expect(finals[0].pcm == pcmFrames(1650), "whole segment pcm")
    try expect(!finals[0].forcedCut, "never forced")
    for _ in 0..<10 { try segmenter.feed(PCM, true) }
    segmenter.flush()
    try expect(finals.count == 1 && events.filter(\.final).count == 2, "second segment")
    try expect(events.first(where: \.final)!.endSample == events.last!.startSample, "contiguous")
    let joined = events.filter(\.final).reduce(Data()) { $0 + $1.pcm }
    try expect(joined == pcmFrames(1660), "no audio lost")
}

// MARK: - Smart endpoints (test_endpoint.py)

final class EndpointHarness {
    var events: [SegmentJob] = []
    lazy var segmenter = Segmenter(config: ModelConfig()) { [weak self] in self?.events.append($0) }
    func feed(_ count: Int, _ voiced: Bool) throws {
        for _ in 0..<count { try segmenter.feed(PCM, voiced) }
    }
    @discardableResult
    func result(_ text: String) throws -> SegmentJob {
        var item = events.last!
        segmenter.acceptPreview(item: item, text: text)
        return item
    }
    var finals: [SegmentJob] { events.filter(\.final) }
}

func testTerminalHints() throws {
    for text in ["完成了。", "Hello world.", "完成测试 done!", "“真的吗”？"] {
        try expect(sentenceComplete(text), "terminal: \(text)")
    }
    for text in ["等一下…", "Well...", "Mr.", "Dr.", "U.S.", "3.14.", "1.", "你好，", "未完成", "A."] {
        try expect(!sentenceComplete(text), "not terminal: \(text)")
    }
}

func testOneResultOneSecondReusesSilence() throws {
    let harness = EndpointHarness()
    try harness.feed(60, true)
    try harness.result("完成了。")
    try harness.feed(49, false)
    try expect(harness.finals.isEmpty, "waits for one second")
    try harness.feed(1, false)
    try expect(harness.finals.count == 1, "finals after 1000 ms")
    try expect(harness.events.count == 2, "no preview after result")
}

func testTwoStableResultsHalfSecond() throws {
    let harness = EndpointHarness()
    try harness.feed(60, true)
    try harness.result("完成了。")
    try harness.feed(60, true)
    try harness.result("完成了。")
    try harness.feed(24, false)
    try expect(harness.finals.isEmpty, "waits for half second")
    try harness.feed(1, false)
    try expect(harness.finals.count == 1, "finals after 500 ms")
}

func testChangedOrIncompleteWaits() throws {
    for tail in ["现在完成了。", "还没有完成", "3.14."] {
        let harness = EndpointHarness()
        try harness.feed(60, true)
        try harness.result("完成了。")
        try harness.feed(60, true)
        try harness.result(tail)
        try harness.feed(89, false)
        try expect(harness.finals.isEmpty, "not final before 1800 ms: \(tail)")
        try harness.feed(1, false)
        try expect(harness.finals.count == 1, "finals at 1800 ms: \(tail)")
    }
}

func testResumedSpeechInvalidatesOldPunctuation() throws {
    let harness = EndpointHarness()
    try harness.feed(60, true)
    let old = try harness.result("完成了。")
    try harness.feed(20, false)
    try harness.feed(1, true)
    harness.segmenter.acceptPreview(item: old, text: "完成了。")
    try harness.feed(50, false)
    try expect(harness.finals.isEmpty, "resumed speech invalidates")
    try harness.feed(40, false)
    try expect(harness.finals.count == 1, "final after 1800 ms")
}

func testLateFeedbackCanFinalizeButNeverNewSegment() throws {
    let harness = EndpointHarness()
    try harness.feed(60, true)
    let old = harness.events.last!
    try harness.feed(50, false)
    harness.segmenter.acceptPreview(item: old, text: "完成了。")
    try expect(harness.finals.count == 1, "late feedback finalizes")
    try harness.feed(60, true)
    harness.segmenter.acceptPreview(item: old, text: "旧句。")
    try harness.feed(50, false)
    try expect(harness.finals.count == 1, "stale feedback never starts new segment")
    harness.segmenter.flush()
    harness.segmenter.flush()
    try expect(harness.finals.count == 2, "second segment flushed")
}

func testOutOfOrderFeedbackDoesNotReplaceNewerText() throws {
    let harness = EndpointHarness()
    try harness.feed(60, true)
    let old = harness.events.last!
    try harness.feed(60, true)
    try harness.result("还没说完")
    harness.segmenter.acceptPreview(item: old, text: "旧句。")
    try harness.feed(50, false)
    try expect(harness.finals.isEmpty, "old text keeps waiting")
    try harness.feed(40, false)
    try expect(harness.finals.count == 1, "final after full wait")
}

func testNeverForceCutSpeech() throws {
    let harness = EndpointHarness()
    try harness.feed(2000, true)
    try expect(harness.finals.isEmpty, "no forced cut")
    harness.segmenter.flush()
    try expect(harness.finals[0].pcm == pcmFrames(2000), "flush keeps whole audio")
}

// MARK: - RecognitionCache (test_endpoint.py CacheTests)

final class CacheFakeAdapter: Transcriber {
    var calls: [Data] = []
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        calls.append(pcm)
        return ("重复", 10)
    }
}

func cacheItem(_ frames: Int, voiced: Int? = nil, segment: Int = 1) -> SegmentJob {
    var job = SegmentJob()
    job.sessionID = "s"
    job.segmentID = segment
    job.startSample = 0
    job.pcm = pcmFrames(frames)
    job.lastVoicedSample = (voiced ?? frames) * Backend.frame
    return job
}

func testSameSpeechReusesResult() async throws {
    let cache = RecognitionCache()
    let adapter = CacheFakeAdapter()
    var config = ModelConfig()
    config.maxSegmentSeconds = 5
    let joined = try await cache.transcribe(adapter, config: config, item: cacheItem(600))
    try expect(joined.0 == "重复重复重复", "joined chunks")
    let reused = try await cache.transcribe(adapter, config: config, item: cacheItem(650, voiced: 600))
    try expect(reused.0 == "重复重复重复" && reused.1 == 0, "last-voiced reuse")
    try expect(adapter.calls.count == 3, "three chunk calls")
}

func testPrefixCachedTailUpdatedAndSessionIsolated() async throws {
    let cache = RecognitionCache()
    let adapter = CacheFakeAdapter()
    var config = ModelConfig()
    config.maxSegmentSeconds = 5
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(600))
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(650))
    try expect(adapter.calls.map { $0.count / (Backend.frame * 2) } == [250, 250, 100, 150], "chunk plan")
    var other = cacheItem(650)
    other.sessionID = "new"
    _ = try await cache.transcribe(adapter, config: config, item: other)
    try expect(adapter.calls.count == 7, "new session isolated")
    cache.forget(other)
    try expect(cache.entries.count == 1, "forget removes entry")
    cache.clear()
    try expect(cache.entries.isEmpty, "clear removes all")
}

func testNewVoicedTailRequiresInference() async throws {
    let cache = RecognitionCache()
    let adapter = CacheFakeAdapter()
    var config = ModelConfig()
    config.maxSegmentSeconds = 5
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(60))
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(61))
    try expect(adapter.calls.count == 2, "new voiced tail re-infers")
    cache.forget(cacheItem(61))
    try expect(cache.entries.isEmpty, "forget")
}

func testObsoleteResultIsNotReused() async throws {
    let cache = RecognitionCache()
    let adapter = CacheFakeAdapter()
    var config = ModelConfig()
    config.maxSegmentSeconds = 5
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(60)) { true }
    try expect(adapter.calls.isEmpty, "obsolete skips inference")
    _ = try await cache.transcribe(adapter, config: config, item: cacheItem(60))
    try expect(adapter.calls.count == 1, "fresh run infers")
}

// MARK: - TranslationPlanner

func testPlannerSilenceEndedFinals() throws {
    let planner = TranslationPlanner()
    let unit = planner.add(session: "s", segmentID: 1, text: "你好。", forcedCut: false)
    try expect(unit?.anchorSegment == 1 && unit?.source == "你好。", "first unit")
    try expect(planner.add(session: "s", segmentID: 2, text: "  ", forcedCut: false) == nil, "whitespace ignored")
}

func testPlannerForcedCutCarriesTail() throws {
    let planner = TranslationPlanner()
    let first = planner.add(session: "s", segmentID: 1, text: "First sentence. Second half", forcedCut: true)
    try expect(first?.anchorSegment == 1 && first?.source == "First sentence.", "complete sentence only")
    let second = planner.add(session: "s", segmentID: 2, text: "continues here.", forcedCut: false)
    try expect(second?.anchorSegment == 2 && second?.source == "Second half continues here.", "carried tail joined")
}

func testPlannerCutOffSentenceStillCarries() throws {
    // Real Qwen3-ASR output around a 5 s forced cut: it adds 。 where the audio was cut.
    let planner = TranslationPlanner()
    let first = planner.add(session: "s", segmentID: 1, text: "你好，这是一个本地语音识别测试。今天下午三点。", forcedCut: true)
    try expect(first?.source == "你好，这是一个本地语音识别测试。", "first unit")
    let second = planner.add(session: "s", segmentID: 2, text: "开会，请记住数字一二三四五。", forcedCut: false)
    try expect(second?.source == "今天下午三点开会，请记住数字一二三四五。", "tail without boundary punctuation")
}

func testPlannerWithoutSentenceEndWaits() throws {
    let planner = TranslationPlanner()
    try expect(planner.add(session: "s", segmentID: 1, text: "我们今天讨论的是", forcedCut: true) == nil, "carry waits")
    let second = planner.add(session: "s", segmentID: 2, text: "本地推理。", forcedCut: false)
    try expect(second?.source == "我们今天讨论的是本地推理。", "joined")
    try expect(planner.add(session: "s", segmentID: 3, text: "The value is 3.14 and", forcedCut: true) == nil, "decimal not terminal")
}

func testPlannerFlushAnchorsAndSessionsDoNotMix() throws {
    let planner = TranslationPlanner()
    _ = planner.add(session: "s", segmentID: 1, text: "Done. Tail", forcedCut: true)
    try expect(planner.add(session: "s", segmentID: 2, text: "", forcedCut: true) == nil, "empty add")
    let flushed = planner.flush(session: "s")
    try expect(flushed?.anchorSegment == 1 && flushed?.source == "Tail", "flush anchored to last text")
    try expect(planner.flush(session: "s") == nil, "flush empties carry")
    _ = planner.add(session: "s", segmentID: 3, text: "Old tail", forcedCut: true)
    let switched = planner.add(session: "t", segmentID: 1, text: "New.", forcedCut: false)
    try expect(switched?.anchorSegment == 1 && switched?.source == "New.", "session switch resets")
    try expect(planner.flush(session: "t") == nil, "no cross-session carry")
}

func testPlannerLongCarryTranslatesWithoutWaiting() throws {
    let text = String(repeating: "word ", count: 100)
    let unit = TranslationPlanner().add(session: "s", segmentID: 1, text: text, forcedCut: true)
    try expect(unit?.source == text.trimmingCharacters(in: .whitespaces), "long carry passes through")
}

func testAlreadyInTarget() throws {
    try expect(TranslationText.alreadyInTarget("今天我们测试Python和Swift，所有音频都在本地处理。", "简体中文"), "han dominant")
    try expect(!TranslationText.alreadyInTarget("This is a local speech recognition test.", "简体中文"), "latin not chinese")
    try expect(!TranslationText.alreadyInTarget("今日はいい天気ですね。", "简体中文"), "kana not chinese")
    try expect(TranslationText.alreadyInTarget("今日はいい天気ですね。", "日本語"), "japanese")
    try expect(TranslationText.alreadyInTarget("안녕하세요", "한국어"), "korean")
    try expect(!TranslationText.alreadyInTarget("你好", "繁體中文"), "traditional never auto-skips")
    try expect(!TranslationText.alreadyInTarget("Bonjour à tous", "English"), "latin never auto-skips")
    try expect(TranslationText.alreadyInTarget("123。", "English"), "no letters at all")
}

func testSameText() throws {
    try expect(TranslationText.sameText("Hello, world!", "hello world"), "punctuation and case ignored")
    try expect(!TranslationText.sameText("Hello", "你好"), "different scripts")
}

func testBuildMessages() throws {
    let messages = TranslationText.buildMessages(architecture: "qwen3", text: "第二句。", target: "English",
                                                 context: [("第一句。", "First sentence.")])
    try expect(messages[0]["content"]?.contains("English") == true, "system names target")
    try expect(messages.map { $0["role"]! } == ["system", "user", "assistant", "user"], "role order")
    try expect(messages.last?["content"] == "第二句。", "current text last")
    try expect(TranslationText.buildMessages(architecture: "hunyuan_v1_dense", text: "Hello.", target: "简体中文", context: [("ignored", "context")]) ==
               [["role": "user", "content": "把下面的文本翻译成简体中文，不要额外解释。\n\nHello."]], "hunyuan chinese instruction")
    try expect(TranslationText.buildMessages(architecture: "hunyuan_v1_dense", text: "Hello.", target: "Français")[0]["content"]?.contains("into French") == true, "hunyuan english instruction")
}

func testValidateTranslator() throws {
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    func model(_ path: URL, config: [String: Any] = ["model_type": "qwen3"], tokenizer: [String: Any] = [:],
               chatTemplate: Bool = true, weights: Bool = true) throws {
        try JSONSerialization.data(withJSONObject: config).write(to: path.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: tokenizer).write(to: path.appendingPathComponent("tokenizer_config.json"))
        try Data("{}".utf8).write(to: path.appendingPathComponent("tokenizer.json"))
        if chatTemplate { try Data("{{ messages }}".utf8).write(to: path.appendingPathComponent("chat_template.jinja")) }
        if weights { try Data().write(to: path.appendingPathComponent("model.safetensors")) }
    }
    let good = dir.appendingPathComponent("good")
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    try model(good)
    try validateTranslator(good)
    let noTemplate = dir.appendingPathComponent("no-template")
    try FileManager.default.createDirectory(at: noTemplate, withIntermediateDirectories: true)
    try model(noTemplate, chatTemplate: false)
    try rejects { try validateTranslator(noTemplate) }
    let custom = dir.appendingPathComponent("custom")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try model(custom, config: ["model_type": "qwen3", "auto_map": ["x": "remote.code"]])
    try rejects { try validateTranslator(custom) }
    let badArch = dir.appendingPathComponent("bad-arch")
    try FileManager.default.createDirectory(at: badArch, withIntermediateDirectories: true)
    try model(badArch, config: ["model_type": "qwen3_asr"])
    try rejects { try validateTranslator(badArch) }
    let customTokenizer = dir.appendingPathComponent("custom-tokenizer")
    try FileManager.default.createDirectory(at: customTokenizer, withIntermediateDirectories: true)
    try model(customTokenizer, tokenizer: ["auto_map": ["AutoTokenizer": ["x.Tok", nil]]])
    try rejects { try validateTranslator(customTokenizer) }
    let missingShard = dir.appendingPathComponent("missing-shard")
    try FileManager.default.createDirectory(at: missingShard, withIntermediateDirectories: true)
    try model(missingShard)
    let index: [String: Any] = ["weight_map": ["a": "model-00002.safetensors"]]
    try JSONSerialization.data(withJSONObject: index).write(to: missingShard.appendingPathComponent("model.safetensors.index.json"))
    try rejects { try validateTranslator(missingShard) }
}

func testResolveCachedModel() throws {
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let snapshot = dir.appendingPathComponent("models--owner--mt").appendingPathComponent("snapshots").appendingPathComponent("abc")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["model_type": "qwen3"]).write(to: snapshot.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("tokenizer_config.json"))
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("tokenizer.json"))
    try Data("{{ messages }}".utf8).write(to: snapshot.appendingPathComponent("chat_template.jinja"))
    try Data().write(to: snapshot.appendingPathComponent("model.safetensors"))
    var config = TranslationConfig()
    config.modelID = "owner/mt"
    let resolved = try ModelCache.resolve(modelID: config.modelID, revision: config.revision, cache: dir, validate: { try validateTranslator($0) },
                                          missing: "翻译模型尚未下载")
    let samePath = URL(fileURLWithPath: resolved.path).resolvingSymlinksInPath() == snapshot.resolvingSymlinksInPath()
    try expect(samePath && resolved.revision == "abc", "mtime scan finds snapshot")
    try rejects {
        _ = try ModelCache.resolve(modelID: "owner/none", revision: "", cache: dir, validate: { try validateTranslator($0) },
                                   missing: "翻译模型尚未下载")
    }
    try rejects {
        _ = try ModelCache.resolve(modelID: "owner/mt", revision: "deadbeef", cache: dir, validate: { try validateTranslator($0) })
    }
}

// MARK: - BackendCore server tests

final class CoreHarness {
    let core: BackendCore
    let recorder = EventRecorder()
    let asr: FakeASREngine
    let translator: FakeTranslatorEngine
    let api: FakeAPIRecognizer
    let dir = tempRoot()

    init(asrText: String = "重复重复") {
        asr = FakeASREngine()
        asr.text = asrText
        translator = FakeTranslatorEngine()
        api = FakeAPIRecognizer()
        core = BackendCore(root: dir, asrEngine: asr, apiRecognizer: api, translator: translator)
    }

    func ready() async throws {
        await core.attach(recorder)
        await core.prepareForTest(state: "ready")
    }

    func settleDown() async throws { try await settle(core) }

    func speakAndStop(_ frames: Int = 8) async throws {
        await core.control(command("start"))
        try expect(recorder.last("status")?["state"] as? String == "recording", "recording started")
        try await feed(frames, true)
        await core.control(command("stop"))
    }

    func feed(_ frames: Int, _ voiced: Bool) async throws {
        for _ in 0..<frames { try await core.feedForTest(PCM, voiced) }
    }

    func waitUntil(_ predicate: @escaping ([String: Any]) -> Bool) async throws -> [[String: Any]] {
        var seen: [[String: Any]] = []
        for _ in 0..<100_000 {
            seen = recorder.all
            if let last = seen.last, predicate(last) { return seen }
            await Task.yield()
        }
        throw TestFailure(message: "condition never reached: \(recorder.all.map { $0["type"] as? String ?? "?" })")
    }
}

func testHelloBeforeAttachBuffersEvents() async throws {
    let dir = tempRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = BackendCore(root: dir, asrEngine: FakeASREngine(), apiRecognizer: APIRecognizer(), translator: FakeTranslatorEngine())
    // The first command may win the race against the async attach; its reply must be buffered.
    await core.control(command("hello"))
    let recorder = EventRecorder()
    await core.attach(recorder)
    try await settle(core)
    try expect((recorder.all.first?["type"] as? String) == "config", "hello reply delivered first")
    try expect(recorder.all.map { $0["type"] as? String } == ["config", "translator", "status"], "hello batch shape")
}

func testStopFinalizesOnceAndPreservesRepetition() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    await harness.core.control(command("start"))
    try await harness.feed(8, true)
    await harness.core.control(command("stop"))
    try await harness.settleDown()
    let finals = harness.recorder.of("final")
    try expect(finals.count == 1, "one final")
    try expect(finals[0]["text"] as? String == "重复重复", "repetition preserved")
    try expect(finals[0]["session_id"] as? String == "test", "session stamped")
    await harness.core.control(command("stop"))
    let state = await harness.core.state
    try expect(state == "ready", "state stays ready")
}

func testStartAppliesAndSavesPauseWithoutModelReload() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    await harness.core.control(command("start", extra: ["endpoint_mode": "fixed", "endpoint_silence_ms": 1500]))
    try expect(harness.recorder.last("status")?["state"] as? String == "recording", "recording")
    let segmenter = await harness.core.segmenter
    try expect(segmenter?.config.endpointMode == "fixed", "mode applied")
    try expect(segmenter?.config.endpointSilenceMS == 1500, "silence applied")
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.dir.appendingPathComponent("config.json"))) as! [String: Any]
    try expect(saved["endpoint_silence_ms"] as? Int == 1500, "pause saved")
}

func testInvalidPauseDoesNotStartRecording() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    await harness.core.control(command("start", extra: ["endpoint_silence_ms": 0]))
    try expect((harness.recorder.all.last?["type"] as? String) == "error", "error event")
    let state = await harness.core.state
    let silence = await harness.core.config.endpointSilenceMS
    try expect(state == "ready", "still ready")
    try expect(silence == 1000, "config unchanged")
}

func testAudioGapStopsAndReports() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    await harness.core.control(command("start"))
    await harness.core.audio(audioPayload(sequence: 2, start: 0))
    try await harness.settleDown()
    try expect(harness.recorder.of("error").contains { ($0["message"] as? String)?.contains("序号") == true }, "gap reported")
    let state = await harness.core.state
    try expect(state == "ready", "stopped")
}

func testLatestPreviewCoalesces() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    for revision in 0..<100 {
        await harness.core.enqueueForTest(previewJob(revision))
    }
    try await harness.settleDown()
    let preview = await harness.core.preview
    let partials = harness.recorder.of("partial")
    try expect(preview?.revision == 99 || (partials.last?["revision"] as? Int) == 99, "latest preview wins")
    let jobCount = await harness.core.jobCount
    try expect(jobCount == 0, "no jobs queued")
}

func testAPILoadUsesMemoryKeyAndPersistsOnlySettings() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    var config = ModelConfig()
    config.provider = "api"
    config.apiBaseURL = "https://example.com/v1"
    config.apiModel = "speech-model"
    await harness.core.control(command("load", extra: ["config": config.asDict, "api_key": "top-secret"]))
    try await harness.settleDown()
    let apiKey = await harness.core.currentAPIKey
    let provider = await harness.core.config.provider
    try expect(apiKey == "top-secret", "key in memory only")
    try expect(provider == "api", "api provider active")
    let saved = (try? String(contentsOf: harness.dir.appendingPathComponent("config.json"), encoding: .utf8)) ?? ""
    try expect(!saved.contains("top-secret"), "key never persisted")
    try expect(!harness.recorder.of("config").isEmpty, "config mirrored")
}

func testAPIRecognitionUsesExistingFinalEvent() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    var config = ModelConfig()
    config.provider = "api"
    config.apiBaseURL = "https://example.com/v1"
    config.apiModel = "speech-model"
    await harness.core.control(command("load", extra: ["config": config.asDict, "api_key": "top-secret"]))
    try await harness.settleDown()
    try await harness.speakAndStop()
    try await harness.settleDown()
    try expect(harness.api.calls.count == 1, "single API call")
    try expect(harness.recorder.of("final").map { $0["text"] as? String } == ["API 转写"], "API text")
}

func testStreamingFinalsComeFromAppWithoutAudioOrKey() async throws {
    let harness = CoreHarness()
    try await harness.ready()
    var config = ModelConfig()
    config.provider = "api"
    config.apiProtocol = "qwen_realtime"
    config.apiBaseURL = "wss://maas.qianwenaiapi.com/api-ws/v1/inference"
    config.apiModel = "qwen-audio-3.0-asr-flash-streaming"
    await harness.core.control(command("load", extra: ["config": config.asDict]))
    try await harness.settleDown()
    let apiKey = await harness.core.currentAPIKey
    try expect(apiKey == "", "no key for realtime")
    await harness.core.control(command("start"))
    let segmenter = await harness.core.segmenter
    try expect(segmenter == nil, "no local segmenter")
    await harness.core.audio(audioPayload(sequence: 0, start: 0))
    try await harness.settleDown()
    try expect((harness.recorder.last("error")?["message"] as? String)?.contains("不接收音频") == true, "audio rejected")
    await harness.core.control(command("asr_stream_final", extra: ["session_id": "other", "segment_id": 1, "text": "必须忽略", "start_sample": 0]))
    await harness.core.control(command("asr_stream_final", extra: ["segment_id": 1, "text": " 第一句。", "start_sample": 16000]))
    await harness.core.control(command("asr_stream_final", extra: ["segment_id": 1, "text": "重复", "start_sample": 0]))
    await harness.core.control(command("asr_stream_final", extra: ["segment_id": 2, "text": "第二句。", "start_sample": 48000]))
    await harness.core.control(command("stop"))
    try await harness.settleDown()
    try expect(harness.recorder.of("error").contains { ($0["message"] as? String)?.contains("无效") == true }, "duplicate segment invalid")
    let finals = harness.recorder.of("final")
    try expect(finals.map { $0["text"] as? String } == ["第一句。", "第二句。"], "streaming finals")
    let identity: [(Int?, Int?, Int?)] = [(1, 1, 16000), (2, 1, 48000)]
    let actual = finals.map { ($0["segment_id"] as? Int, $0["revision"] as? Int, $0["start_sample"] as? Int) }
    try expect(actual.count == identity.count && zip(actual, identity).allSatisfy { $0 == $1 }, "final identity")
    await harness.core.control(command("asr_stream_final", extra: ["segment_id": 3, "text": "会话已结束", "start_sample": 0]))
    try await harness.settleDown()
    let count = harness.recorder.all.count
    await harness.core.control(command("hello"))
    try await harness.settleDown()
    try expect((harness.recorder.all[count]["type"] as? String) == "config", "hello answers config")
}

// MARK: - Translation server tests

func translationHarness(target: String = "English") async -> CoreHarness {
    let harness = CoreHarness(asrText: "这是测试")
    await harness.core.attach(harness.recorder)
    var config = ModelConfig()
    config.endpointMode = "fixed"
    await harness.core.prepareForTest(state: "ready", config: config)
    var translation = TranslationConfig()
    translation.enabled = true
    translation.targetLanguage = target
    await harness.core.prepareForTest(translation: translation)
    return harness
}

func testFinalIsSentFirstThenTranslationStreams() async throws {
    let harness = await translationHarness()
    try await harness.speakAndStop()
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translation" && ($0["done"] as? Bool) == true }
    let kinds = events.map { $0["type"] as? String }
    try expect(kinds.firstIndex { $0 == "final" }! < kinds.firstIndex { $0 == "translation" }!, "final first")
    let final = events.first { ($0["type"] as? String) == "final" }!
    let translations = events.filter { ($0["type"] as? String) == "translation" }
    try expect(translations[0]["revision"] as? Int == 0 && translations[0]["text"] as? String == "", "placeholder first")
    try expect(translations.last?["text"] as? String == "Hello world.", "cumulative text")
    try expect(translations.last?["skipped"] as? Bool == false, "not skipped")
    try expect(Set(translations.compactMap { $0["segment_id"] as? Int }) == Set([final["segment_id"] as! Int]), "same segment")
    let revisions = translations.compactMap { $0["revision"] as? Int }
    try expect(revisions == Array(Set(revisions)).sorted(), "revisions monotonic")
    try expect(harness.translator.calls[0].text == "这是测试" && harness.translator.calls[0].target == "English", "translator input")
}

func testLongUtteranceRecognizedOnlyAfterPauseThenTranslatedOnce() async throws {
    let harness = await translationHarness()
    var config = ModelConfig()
    config.endpointMode = "fixed"
    config.maxSegmentSeconds = 5
    config.previewIntervalMS = 10_000
    await harness.core.prepareForTest(config: config)
    await harness.core.control(command("start"))
    try await harness.feed(300, true)
    try await harness.feed(49, false)
    try expect(harness.asr.calls.isEmpty, "no inference before pause")
    try expect(harness.translator.calls.isEmpty, "no translation before pause")
    try await harness.feed(1, false)
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translation" && ($0["done"] as? Bool) == true }
    try expect((events.first { ($0["type"] as? String) != "status" }?["type"] as? String) == "final", "final first event")
    let finals = events.filter { ($0["type"] as? String) == "final" }
    try expect(finals.count == 1 && finals[0]["text"] as? String == "这是测试这是测试", "joined chunks")
    try expect(!events.contains { ($0["type"] as? String) == "partial" }, "no partials")
    try expect(harness.asr.calls.count == 2, "two chunks")
    try expect(harness.asr.calls.allSatisfy { $0.count <= 5 * 16000 * 2 }, "chunk size bound")
    try expect(harness.asr.calls.reduce(Data(), +) == pcmFrames(350), "all audio recognized: \(harness.asr.calls.map(\.count))")
    try expect(harness.translator.calls.count == 1 && harness.translator.calls[0].text == "这是测试这是测试", "one translation")
    let state = await harness.core.state
    try expect(state == "recording", "still recording")
}

func testPeriodicPreviewDoesNotTranslateBeforePause() async throws {
    let harness = await translationHarness()
    await harness.core.control(command("start"))
    try await harness.feed(60, true)
    try await harness.settleDown()
    try expect(harness.recorder.last("partial") != nil, "preview emitted")
    try expect(harness.translator.calls.isEmpty, "no translation on preview")
    let partialCount = harness.recorder.of("partial").count
    try await harness.feed(49, false)
    try await harness.settleDown()
    try expect(harness.recorder.of("partial").count == partialCount, "silence adds no preview")
    try expect(harness.translator.calls.isEmpty, "still no translation")
    try await harness.feed(1, false)
    try await harness.waitUntil { ($0["type"] as? String) == "translation" && ($0["done"] as? Bool) == true }
    try expect((harness.recorder.of("final").first?["type"] as? String) == "final", "final emitted")
    try expect(harness.translator.calls.count == 1, "translated once")
}

func testSmartFinalReusesPreviewAndTranslatesOnce() async throws {
    let harness = await translationHarness()
    var config = ModelConfig()
    config.endpointMode = "smart"
    await harness.core.prepareForTest(config: config)
    await harness.core.control(command("start"))
    harness.asr.text = "这是测试。"
    try await harness.feed(60, true)
    try await harness.settleDown()
    try expect(harness.recorder.last("partial") != nil, "preview emitted")
    try await harness.feed(50, false)
    try await harness.waitUntil { ($0["type"] as? String) == "translation" && ($0["done"] as? Bool) == true }
    try expect(harness.recorder.of("final").count == 1, "one final")
    try expect(harness.asr.calls.count == 1, "preview reused")
    try expect(harness.translator.calls.count == 1, "one translation")
    let entries = await harness.core.recognitionEntryCount
    try expect(entries == 0, "cache forgotten")
}

func testASRFinalPreemptsRunningTranslation() async throws {
    let harness = await translationHarness()
    final class InjectedBox: @unchecked Sendable { var value = false }
    let injected = InjectedBox()
    let core = harness.core
    harness.translator.onToken = { @Sendable in
        guard !injected.value else { return }
        injected.value = true
        var job = SegmentJob()
        job.segmentID = 99
        job.revision = 1
        job.startSample = 0
        job.endSample = Backend.frame
        job.final = true
        job.pcm = PCM
        await core.enqueueForTest(job)
    }
    try await harness.speakAndStop()
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translation" && ($0["done"] as? Bool) == true && ($0["segment_id"] as? Int) == 99 }
    let order = events.map { ($0["type"] as? String, $0["segment_id"] as? Int, $0["done"] as? Bool) }
    let finalEntry: (String?, Int?, Bool?) = ("final", 99, nil)
    let doneEntry: (String?, Int?, Bool?) = ("translation", 1, true)
    func orderIndex(_ type: String, segment: Int?, done: Bool?) -> Int? {
        order.firstIndex { $0.0 == type && $0.1 == segment && $0.2 == done }
    }
    try expect(orderIndex("final", segment: 99, done: nil)! < orderIndex("translation", segment: 1, done: true)!, "ASR final outruns translation")
    try expect(harness.translator.calls[1].context.count == 1 && harness.translator.calls[1].context[0] == ("这是测试", "Hello world."), "context from finished unit")
}

func testSameLanguageSpeechIsNotTranslated() async throws {
    let harness = await translationHarness(target: "简体中文")
    try await harness.speakAndStop()
    try await harness.waitUntil { ($0["state"] as? String) == "ready" }
    try expect(harness.recorder.of("translation").isEmpty, "no translation events")
    try expect(harness.translator.calls.isEmpty, "translator untouched")
}

func testDisablingUnloadsAndPersists() async throws {
    let harness = await translationHarness()
    await harness.core.control(command("translation_settings", extra: ["enabled": false]))
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translator" && ($0["state"] as? String) == "idle" }
    try expect((events.last?["config"] as? [String: Any])?["enabled"] as? Bool == false, "config disabled")
    let unloaded = await harness.translator.isLoaded
    try expect(unloaded == false, "model unloaded")
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.dir.appendingPathComponent("translation.json"))) as! [String: Any]
    try expect(saved["enabled"] as? Bool == false, "persisted disabled")
}

func testEnablingWithoutDownloadedModelReportsAndTurnsOff() async throws {
    let harness = CoreHarness(asrText: "这是测试")
    await harness.core.attach(harness.recorder)
    var config = ModelConfig()
    config.endpointMode = "fixed"
    await harness.core.prepareForTest(state: "ready", config: config)
    await harness.core.prepareForTest(translation: TranslationConfig())  // disabled, no model
    harness.translator.isLoaded = false
    await harness.core.control(command("translation_settings", extra: ["enabled": true]))
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translator" && ($0["state"] as? String) == "error" }
    try expect((events.last?["detail"] as? String)?.contains("尚未下载") == true, "missing model reported")
    try expect((events.last?["config"] as? [String: Any])?["enabled"] as? Bool == false, "turned back off")
}

func testAPIProviderPersistsAndNeverCallsLocalTranslator() async throws {
    let harness = await translationHarness()
    await harness.core.control(command("translation_settings",
                                       extra: ["provider": "api", "api_profile": "https://example.com/v1", "enabled": true]))
    let events = try await harness.waitUntil { ($0["type"] as? String) == "translator" && ($0["detail"] as? String) == "实时翻译已关闭" }
    try expect((events.last?["config"] as? [String: Any])?["enabled"] as? Bool == true, "enabled kept")
    try expect((events.last?["config"] as? [String: Any])?["provider"] as? String == "api", "provider api")
    let saved = try TranslationConfig.parse(try JSONSerialization.jsonObject(with: Data(contentsOf: harness.dir.appendingPathComponent("translation.json"))) as! [String: Any])
    try expect(saved.provider == "api" && saved.apiProfile == "https://example.com/v1", "persisted api profile")
    harness.translator.calls.removeAll()
    try await harness.speakAndStop()
    _ = try await harness.waitUntil { ($0["state"] as? String) == "ready" }
    try expect(!harness.recorder.of("final").isEmpty, "finals emitted")
    try expect(!harness.recorder.all.contains { ($0["type"] as? String) == "translation" }, "no local translation")
    try expect(harness.translator.calls.isEmpty, "translator untouched")
    await harness.core.control(command("load", extra: ["role": "translator"]))
    try expect((harness.recorder.all.last?["type"] as? String) == "error", "translator load rejected")
    await harness.core.control(command("translation_settings", extra: ["enabled": false]))
    let last = try await harness.waitUntil { ($0["type"] as? String) == "translator" && ($0["config"] as? [String: Any])?["enabled"] as? Bool == false }
    try expect((last.last?["config"] as? [String: Any])?["api_profile"] as? String == "https://example.com/v1", "profile survives disable")
}

func testInvalidTargetRejectedWithoutChangingConfig() async throws {
    let harness = await translationHarness()
    await harness.core.control(command("translation_settings", extra: ["target_language": "Klingon"]))
    try expect((harness.recorder.all.last?["type"] as? String) == "error", "rejected")
    let target = await harness.core.translation.targetLanguage
    try expect(target == "English", "config unchanged")
}

@main struct BackendTests {
    static func main() async throws {
        let started = Date()
        var failures = 0
        var passed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                passed += 1
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        await run("config invalid + atomic save", testConfigInvalidAndAtomicSave)
        await run("api config address validation", testAPIConfigValidatesAddress)
        await run("translation config validation", testTranslationConfigValidation)
        await run("silence never emits", testSilenceNeverEmits)
        await run("preroll flush preserves tail", testPrerollFlushPreservesShortTail)
        await run("pause threshold + reset", testPauseThresholdAndShortPauseReset)
        await run("long speech previews", testLongSpeechPreviewsButWaitsForPauseToFinalize)
        await run("terminal hints", testTerminalHints)
        await run("one result one second", testOneResultOneSecondReusesSilence)
        await run("two stable results half second", testTwoStableResultsHalfSecond)
        await run("changed or incomplete waits", testChangedOrIncompleteWaits)
        await run("resumed speech invalidates", testResumedSpeechInvalidatesOldPunctuation)
        await run("late feedback finalizes", testLateFeedbackCanFinalizeButNeverNewSegment)
        await run("out-of-order feedback", testOutOfOrderFeedbackDoesNotReplaceNewerText)
        await run("never force cut", testNeverForceCutSpeech)
        await run("cache reuses result", testSameSpeechReusesResult)
        await run("cache prefix + sessions", testPrefixCachedTailUpdatedAndSessionIsolated)
        await run("cache new tail", testNewVoicedTailRequiresInference)
        await run("cache obsolete", testObsoleteResultIsNotReused)
        await run("planner silence units", testPlannerSilenceEndedFinals)
        await run("planner forced cut carry", testPlannerForcedCutCarriesTail)
        await run("planner cut-off sentence", testPlannerCutOffSentenceStillCarries)
        await run("planner no sentence end", testPlannerWithoutSentenceEndWaits)
        await run("planner flush anchors", testPlannerFlushAnchorsAndSessionsDoNotMix)
        await run("planner long carry", testPlannerLongCarryTranslatesWithoutWaiting)
        await run("already in target", testAlreadyInTarget)
        await run("same text", testSameText)
        await run("build messages", testBuildMessages)
        await run("validate translator", testValidateTranslator)
        await run("resolve cached model", testResolveCachedModel)
        await run("hello before attach", testHelloBeforeAttachBuffersEvents)
        await run("stop finalizes once", testStopFinalizesOnceAndPreservesRepetition)
        await run("start applies pause", testStartAppliesAndSavesPauseWithoutModelReload)
        await run("invalid pause", testInvalidPauseDoesNotStartRecording)
        await run("audio gap", testAudioGapStopsAndReports)
        await run("preview coalesce", testLatestPreviewCoalesces)
        await run("api load memory key", testAPILoadUsesMemoryKeyAndPersistsOnlySettings)
        await run("api recognition", testAPIRecognitionUsesExistingFinalEvent)
        await run("streaming finals", testStreamingFinalsComeFromAppWithoutAudioOrKey)
        await run("final then translation", testFinalIsSentFirstThenTranslationStreams)
        await run("long utterance chunks", testLongUtteranceRecognizedOnlyAfterPauseThenTranslatedOnce)
        await run("preview no translate", testPeriodicPreviewDoesNotTranslateBeforePause)
        await run("smart reuses preview", testSmartFinalReusesPreviewAndTranslatesOnce)
        await run("asr final preempts", testASRFinalPreemptsRunningTranslation)
        await run("same language skip", testSameLanguageSpeechIsNotTranslated)
        await run("disable unloads", testDisablingUnloadsAndPersists)
        await run("enable without model", testEnablingWithoutDownloadedModelReportsAndTurnsOff)
        await run("api provider local", testAPIProviderPersistsAndNeverCallsLocalTranslator)
        await run("invalid target", testInvalidTargetRejectedWithoutChangingConfig)
        print("\(passed) passed, \(failures) failed in \(String(format: "%.1fs", -started.timeIntervalSinceNow))")
        if failures > 0 { exit(1) }
    }
}
