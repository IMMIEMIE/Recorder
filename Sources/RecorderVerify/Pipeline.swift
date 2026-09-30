import Foundation
import RecorderBackend
import RecorderEngines
import RecorderMLX

// `RecorderVerify pipeline`: paced 20 ms PCM frames through the app's BackendCore with the real MLX
// engines, offline, against models cached in the Hugging Face layout. Replaces the Python-era
// scripts/verify_pipeline.py (endpointing latency per final), verify_translation.py (per-unit
// translation latency and same-language skipping) and verify_switching.py (Qwen <-> Whisper
// switching releases the previous weights). Hard failures exit non-zero; everything else is
// recorded in the JSON report next to the Python-era results in docs/.

/// Counts recognition calls after warmup (the former endpoint_benchmark_server.py metrics).
final class MeteredASREngine: ASREngine, @unchecked Sendable {
    private let inner: ASREngine
    private let lock = NSLock()
    private var counters = (calls: 0, inferenceMS: 0)

    init(_ inner: ASREngine) { self.inner = inner }

    var isLoaded: Bool { inner.isLoaded }
    var metrics: (calls: Int, inferenceMS: Int) {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    func load(config: ModelConfig, path: String) async throws { try await inner.load(config: config, path: path) }
    // MLXASREngine warms up through its own transcribe, so warmup never reaches the counters.
    func warmup() async throws { try await inner.warmup() }
    func unload() async { await inner.unload() }
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        let result = try await inner.transcribe(pcm)
        lock.lock()
        counters.calls += 1
        counters.inferenceMS += result.elapsedMS
        lock.unlock()
        return result
    }
}

/// Every backend event, stamped with seconds since the run started.
final class EventLog: BackendEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    let started = monotonic()

    func deliver(_ event: [String: Any]) {
        var stamped = event
        stamped["received_at"] = monotonic() - started
        lock.lock()
        events.append(stamped)
        lock.unlock()
    }

    var all: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    var mark: Int { all.count }

    func wait(from start: Int, timeout: Double = 180, _ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = monotonic() + timeout
        while monotonic() < deadline {
            if let match = all.dropFirst(start).first(where: predicate) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let tail = all.suffix(5).map { "\($0["type"] ?? "?"): \($0["state"] ?? $0["message"] ?? $0["text"] ?? "")" }
        throw VerifyError("等待事件超时，最近事件: \(tail)")
    }
}

func number(_ value: Any?) -> Double {
    switch value {
    case let value as Int: return Double(value)
    case let value as Double: return value
    case let value as NSNumber: return value.doubleValue
    default: return 0
    }
}

func string(_ value: Any?) -> String { value as? String ?? "" }

struct PipelineRun {
    let core: BackendCore
    let log: EventLog
    let asr: MeteredASREngine
    var checks: [[String: Any]] = []
    var sessionCount = 0

    mutating func check(_ passed: Bool, _ name: String, _ detail: Any = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        if !passed { print("FAIL \(name): \(detail)") }
    }

    func command(_ name: String, session: String = "", _ extra: [String: Any] = [:]) async {
        var message: [String: Any] = ["command": name, "protocol_version": 1, "session_id": session, "request_id": name]
        for (key, value) in extra { message[key] = value }
        await core.control(message)
    }

    /// Loads an ASR model by Hub ID (resolved in <root>/models) or snapshot path; returns load + warmup seconds.
    func loadASR(_ model: String, language: String, endpoint: String) async throws -> Double {
        var config = ModelConfig()
        if model.hasPrefix("/") || model.hasPrefix(".") {
            config.localModelPath = URL(fileURLWithPath: model).standardizedFileURL.path
        } else {
            config.modelID = model
        }
        config.language = language
        config.endpointMode = endpoint
        let begin = log.mark
        let started = monotonic()
        await command("load", ["config": config.asDict])
        let status = try await log.wait(from: begin) {
            string($0["type"]) == "status" && ["ready", "error"].contains(string($0["state"]))
        }
        guard string(status["state"]) == "ready" else { throw VerifyError("识别模型加载失败: \(string(status["detail"]))") }
        return monotonic() - started
    }

    /// One paced session. `trailing` seconds of silence let the pause endpoint finalize before stop;
    /// with `waitForFinal` the stop is sent only after the first final, like verify_pipeline.py.
    mutating func session(_ pcm: Data, label: String, trailing: Double, waitForFinal: Bool,
                          waitForTranslations: Bool) async throws -> [String: Any] {
        sessionCount += 1
        let session = "pipeline-\(sessionCount)-\(label)"
        let begin = log.mark
        let before = asr.metrics
        await command("start", session: session)
        _ = try await log.wait(from: begin) { string($0["state"]) == "recording" && string($0["session_id"]) == session }
        var audio = Data(count: Backend.rate * 2)  // 1 s of leading silence checks quiet input
        audio.append(pcm)
        audio.append(Data(count: Int(Double(Backend.rate) * trailing) * 2))
        let vad = try WebRTCVAD(aggressiveness: 2)
        var voicedEnds: [Int] = []
        let frameBytes = Backend.frame * 2
        let sendStart = monotonic() - log.started
        let clock = monotonic()
        var sequence = 0
        for offset in stride(from: 0, to: audio.count, by: frameBytes) {
            let chunk = audio.subdata(in: offset..<min(offset + frameBytes, audio.count))
            var padded = chunk
            if padded.count < frameBytes { padded.append(Data(count: frameBytes - padded.count)) }
            if vad.isSpeech(padded) { voicedEnds.append(offset / 2 + Backend.frame) }
            let header: [String: Any] = ["session_id": session, "sequence": sequence, "start_sample": offset / 2,
                                         "sample_rate": Backend.rate, "channels": 1, "format": "s16le"]
            let headerData = try JSONSerialization.data(withJSONObject: header)
            var payload = withUnsafeBytes(of: UInt32(headerData.count).bigEndian) { Data($0) }
            payload.append(headerData)
            payload.append(chunk)
            await core.audio(payload)
            sequence += 1
            let wait = clock + Double(sequence) * 0.02 - monotonic()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        if waitForFinal {
            _ = try await log.wait(from: begin, timeout: 60) { string($0["type"]) == "final" && string($0["session_id"]) == session }
        }
        let stopped = monotonic() - log.started
        await command("stop", session: session)
        let ready = try await log.wait(from: begin) {
            string($0["type"]) == "status" && string($0["state"]) == "ready" && string($0["session_id"]) == session
        }
        if waitForTranslations {
            let deadline = monotonic() + 120
            while true {
                var done: [Int: Bool] = [:]
                for event in log.all.dropFirst(begin) where string(event["type"]) == "translation" && string(event["session_id"]) == session {
                    done[Int(number(event["unit_id"]))] = event["done"] as? Bool ?? false
                }
                if done.values.allSatisfy({ $0 }) { break }
                guard monotonic() < deadline else { throw VerifyError("翻译未在 120 s 内完成: \(session)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let window = log.all.dropFirst(begin).filter { string($0["session_id"]) == session }
        let errors = log.all.dropFirst(begin).filter { string($0["type"]) == "error" }.map { string($0["message"]) }
        let finals = window.filter { string($0["type"]) == "final" }
        let partials = window.filter { string($0["type"]) == "partial" }.count
        let boundaries: [[String: Any]] = finals.map { event in
            let start = Int(number(event["start_sample"]))
            let end = Int(number(event["end_sample"]))
            let voicedEnd = voicedEnds.filter { $0 > start && $0 <= end }.max() ?? start
            return ["start_sample": start, "end_sample": end, "text": string(event["text"]),
                    "vad_speech_to_final_ms": (number(event["received_at"]) - sendStart - Double(voicedEnd) / Double(Backend.rate)) * 1000]
        }
        var units: [[String: Any]] = []
        let translationEvents = window.filter { string($0["type"]) == "translation" }
        for unit in Set(translationEvents.map { Int(number($0["unit_id"])) }).sorted() {
            let updates = translationEvents.filter { Int(number($0["unit_id"])) == unit }
            guard let done = updates.last else { continue }
            let anchor = finals.first { number($0["segment_id"]) == number(done["segment_id"]) }
            let first = updates.first { !string($0["text"]).isEmpty } ?? done
            let finalAt = number(anchor?["received_at"])
            units.append(["segment_id": Int(number(done["segment_id"])), "text": string(done["text"]),
                          "skipped": done["skipped"] as? Bool ?? false, "generation_ms": Int(number(done["elapsed_ms"])),
                          "final_to_first_text_seconds": number(first["received_at"]) - finalAt,
                          "final_to_done_seconds": number(done["received_at"]) - finalAt])
        }
        let after = asr.metrics
        let segmentIDs = finals.map { Int(number($0["segment_id"])) }
        check(!finals.isEmpty, "\(label): 至少一个 final")
        check(Set(segmentIDs).count == segmentIDs.count, "\(label): final 段号不重复", segmentIDs)
        check(!window.contains { $0["forced_cut"] as? Bool == true }, "\(label): 不强制切段")
        check(errors.isEmpty, "\(label): 无错误事件", errors)
        return ["label": label, "session_id": session, "finals": finals.count, "partials": partials,
                "text": finals.map { string($0["text"]) }.joined(separator: "\n"), "boundaries": boundaries,
                "units": units, "asr_calls": after.calls - before.calls,
                "asr_inference_ms": after.inferenceMS - before.inferenceMS,
                "stop_to_ready_seconds": number(ready["received_at"]) - stopped,
                "stop_to_last_event_seconds": (window.map { number($0["received_at"]) }.max() ?? stopped) - stopped]
    }
}

func runPipeline(options: [String: String], fixtures: [String], machine: String) async throws -> Bool {
    let manager = FileManager.default
    let models = URL(fileURLWithPath: options["models"] ?? "models").standardizedFileURL.resolvingSymlinksInPath()
    let asrModel = options["asr"] ?? Backend.defaultModel
    let translatorModel = options["translator"] ?? Backend.defaultTranslator
    let language = options["language"] ?? "auto"
    let endpoint = options["endpoint"] ?? "smart"
    let fixtureDir = "tests/fixtures"
    let fixturePaths = fixtures.isEmpty ? ["chinese", "english", "mixed"].map { "\(fixtureDir)/\($0).aiff" } : fixtures
    ASRValidation.whisperAssets = URL(fileURLWithPath: options["assets"] ?? "assets/whisper").standardizedFileURL

    // A throwaway root: config.json / translation.json writes never touch the user's settings, and the
    // model cache is reached through a symlink exactly like the Python verify_translation.py did.
    let root = manager.temporaryDirectory.appendingPathComponent("recorder-pipeline-\(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    try manager.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: models)

    let asr = MeteredASREngine(MLXASREngine())
    let core = BackendCore(root: root, asrEngine: asr, translator: MLXTranslatorEngine())
    let log = EventLog()
    await core.attach(log)
    var run = PipelineRun(core: core, log: log, asr: asr)
    await run.command("hello")

    let loadSeconds = try await run.loadASR(asrModel, language: language, endpoint: endpoint)
    let activeAfterLoad = MLXRuntime.sync { MLXRuntime.activeMemory }
    var audio: [String: Data] = [:]
    for path in fixturePaths { audio[path] = pcm16Data(try loadPCM16Samples(path)) }

    // verify_pipeline.py: 2 s of trailing silence, stop only after the pause endpoint produced a final.
    var sessions: [[String: Any]] = []
    for path in fixturePaths {
        let label = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var report = try await run.session(audio[path]!, label: label, trailing: 2, waitForFinal: true, waitForTranslations: false)
        report["fixture"] = label
        sessions.append(report)
    }

    // verify_translation.py: stop right after the audio; every unit must finish, same-language speech is skipped.
    var translation: [String: Any] = ["model": translatorModel]
    if translatorModel != "none" {
        var begin = log.mark
        var started = monotonic()
        // A translator load commits enabled = true, like the app's first download/enable.
        await run.command("load", ["role": "translator", "translation": ["provider": "local", "model_id": translatorModel]])
        let state = try await log.wait(from: begin) {
            string($0["type"]) == "translator" && ["ready", "error"].contains(string($0["state"]))
        }
        guard string(state["state"]) == "ready" else { throw VerifyError("翻译模型加载失败: \(string(state["detail"]))") }
        translation["load_and_warmup_seconds"] = monotonic() - started
        let cases = [("english", "简体中文"), ("english", "日本語"), ("chinese", "English"), ("mixed", "English"), ("chinese", "简体中文")]
        var reports: [[String: Any]] = []
        for (fixture, target) in cases {
            guard let pcm = audio["\(fixtureDir)/\(fixture).aiff"] else { continue }
            begin = log.mark
            started = monotonic()
            await run.command("translation_settings", ["target_language": target])
            _ = try await log.wait(from: begin) {
                string($0["type"]) == "translator" && string(($0["config"] as? [String: Any])?["target_language"]) == target
            }
            var report = try await run.session(pcm, label: "\(fixture)-\(target)", trailing: 0, waitForFinal: false,
                                               waitForTranslations: true)
            report["fixture"] = fixture
            report["target"] = target
            let units = report["units"] as? [[String: Any]] ?? []
            if fixture == "chinese" && target == "简体中文" {
                run.check(units.isEmpty, "\(fixture)→\(target): 同语言不翻译", units)
            } else {
                run.check(units.contains { !string($0["text"]).isEmpty }, "\(fixture)→\(target): 有译文", units)
            }
            reports.append(report)
        }
        translation["sessions"] = reports
        begin = log.mark
        await run.command("translation_settings", ["enabled": false])
        _ = try await log.wait(from: begin) { string($0["type"]) == "translator" && string($0["state"]) == "idle" }
    }

    // verify_switching.py: switch architectures and back in one process; the first model's weights
    // must be released (active MLX memory returns to the first load's level).
    var switching: [[String: Any]] = []
    if let other = options["switch"], let chinese = audio["\(fixtureDir)/chinese.aiff"] ?? audio.values.first {
        switching.append(["model": asrModel, "load_and_warmup_seconds": loadSeconds, "active_bytes": activeAfterLoad])
        for model in [other, asrModel] {
            let seconds = try await run.loadASR(model, language: language, endpoint: endpoint)
            let active = MLXRuntime.sync { MLXRuntime.activeMemory }
            let report = try await run.session(chinese, label: "switch-\(switching.count)", trailing: 2, waitForFinal: true,
                                               waitForTranslations: false)
            switching.append(["model": model, "load_and_warmup_seconds": seconds, "active_bytes": active,
                              "text": report["text"] ?? ""])
        }
        let back = number(switching.last?["active_bytes"])
        run.check(back <= Double(activeAfterLoad) * 1.1, "切换回原模型后显存回落（上一模型已释放）",
                  ["first": activeAfterLoad, "after_switch_back": back])
    }

    await core.shutdown()
    let failed = run.checks.contains { $0["passed"] as? Bool == false }
    try writeReport(["platform": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": machine,
                     "implementation": "mlx-swift", "offline_environment": true, "paced_audio": true,
                     "asr_model": asrModel, "language": language, "endpoint_mode": endpoint,
                     "asr_load_and_warmup_seconds": loadSeconds, "mlx_active_bytes_after_load": activeAfterLoad,
                     "mlx_peak_bytes": MLXRuntime.peakMemory, "sessions": sessions, "translation": translation,
                     "switching": switching, "checks": run.checks, "passed": !failed],
                    to: options["output"] ?? "docs/pipeline-verification-swift.json")
    return failed
}
