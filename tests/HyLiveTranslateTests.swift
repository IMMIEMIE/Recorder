import Foundation
import AVFoundation
import Darwin

struct HyTestFailure: Error, CustomStringConvertible { let description: String }
func hyCheck(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw HyTestFailure(description: message) }
}
@MainActor func hyWait(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HyTestFailure(description: "Timed out waiting for local session")
}

/// This test executable doubles as a no-model JSONL helper. It never opens a network socket.
func runFixture(_ mode: String) {
    if mode == "ignore-term" { signal(SIGTERM, SIG_IGN) }
    func emit(_ raw: [String: Any]) {
        var value = raw; value["protocol_version"] = 1
        let data = try! JSONSerialization.data(withJSONObject: value)
        // Split the header across pipe reads to exercise incremental JSONL decoding.
        let midpoint = max(1, data.count / 2)
        FileHandle.standardOutput.write(data.prefix(midpoint))
        FileHandle.standardOutput.write(data.suffix(from: midpoint) + Data([10]))
    }
    if mode == "timeout" { sleep(30); return }
    emit(["type": "hello", "runtime_commit": mode == "wrong-runtime" ? "wrong" : HyRuntimeAvailability.runtimeCommit,
          "capabilities": ["interleave", "streaming_pcm", "bounded_context", "local_only"]])
    var session = "", byteCount = 0
    func update(_ revision: Int, final: Bool, session override: String? = nil) {
        emit(["type": "update", "session_id": override ?? session, "segment_id": 1,
              "start_sample": 320, "end_sample": max(640, 320 + byteCount / 2),
              "source": final ? "Hello world." : "Hello", "translation": final ? (mode.hasPrefix("tail") ? "你好" : "你好，世界。") : "你",
              "revision": revision, "source_done": final, "translation_done": final, "committed": final])
    }
    while let line = readLine(), let data = line.data(using: .utf8),
          let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        if line.utf8.count > 262_144 {
            emit(["type": "error", "session_id": session, "code": "protocol", "message": "line too large"])
            return
        }
        switch event["type"] as? String {
        case "start":
            session = event["session_id"] as? String ?? ""; byteCount = 0
            emit(["type": "ready", "session_id": session])
        case "audio":
            if mode == "crash" { exit(17) }
            byteCount += Data(base64Encoded: event["pcm"] as? String ?? "")?.count ?? 0
            if byteCount > 0 && byteCount <= 6400 {
                update(99, final: true, session: "stale-session")
                update(mode.hasPrefix("tail") ? 2 : 1, final: mode.hasPrefix("tail"))
            }
        case "finish":
            if byteCount > 0 { update(2, final: true); update(1, final: false) }
            if mode == "bad-done" { emit(["type": "done", "session_id": session, "complete": true]); continue }
            if mode == "partial" {
                emit(["type": "warning", "session_id": session, "code": "unresolved_audio",
                      "start_sample": 320, "end_sample": 1600, "unresolved_audio_ms": 80])
            }
            emit(["type": "done", "session_id": session, "complete": mode != "partial" && mode != "tail-error", "cancelled": false,
                  "unresolved_audio_ms": mode == "partial" || mode == "tail-error" ? 80 : 0, "skipped_untranslated_audio_ms": 0])
        case "cancel":
            emit(["type": "done", "session_id": session, "complete": false, "cancelled": true,
                  "unresolved_audio_ms": 0, "skipped_untranslated_audio_ms": 0])
        case "shutdown": return
        default: break
        }
    }
    if mode == "ignore-term" { while true { sleep(1) } }
}

struct FixtureModelStore: HyModelStoring {
    let path: URL
    var cached = true
    func hasCachedFile(in cache: URL) -> Bool { cached }
    func verifiedFile(in cache: URL) async throws -> URL? { path }
    func download(to cache: URL, progress: @escaping @Sendable (String, Int64, Int64) async -> Void) async throws -> URL { path }
}
final class FixtureSpeech: LocalSpeechOutputting {
    var onFailure: ((String) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    var isPlaying = false
    var enabled = false
    var spoken: [String] = []
    var replayed: [(String, String)] = []
    func start(session: String, language: String, volume: Double, timing: LiveTranslatePlaybackTiming, enabled: Bool) { self.enabled = enabled }
    func consume(session: String, itemID: String, text: String, committed: Bool, final: Bool) {
        if enabled && committed && final { spoken.append(text) }
    }
    func finish(completion: @escaping () -> Void) { completion() }
    func stop() { isPlaying = false }
    func replay(text: String, language: String, volume: Double, completion: @escaping () -> Void) {
        replayed.append((text, language)); completion()
    }
}

final class FixtureSpeechDevice: LocalSpeechQueue {
    let synchronous: Bool
    private(set) var texts: [String] = []
    private var completions: [() -> Void] = []
    init(synchronous: Bool) { self.synchronous = synchronous }
    func enqueue(text: String, language: String, volume: Double, rate: Float, completion: @escaping () -> Void) throws {
        texts.append(text)
        if synchronous { completion() } else { completions.append(completion) }
    }
    func stop() { completions.removeAll() }
    func completeAll() {
        let pending = completions; completions.removeAll()
        pending.forEach { $0() }
    }
}

final class EndingFixtureSession: LiveTranslationSession, @unchecked Sendable {
    var onReady: (() -> Void)?
    var onEvent: ((LiveTranslationSessionEvent) -> Void)?
    var onEnd: ((String?) -> Void)?
    private let lock = NSLock()
    private var appends = 0
    var appendCount: Int { lock.lock(); defer { lock.unlock() }; return appends }
    func start(configuration: LiveTranslateConfiguration, key: String, sessionID: String) throws {
        DispatchQueue.main.async { [weak self] in self?.onReady?() }
    }
    func append(_ pcm: Data) -> Bool {
        lock.lock(); appends += 1; let first = appends == 1; lock.unlock()
        if first {
            DispatchQueue.main.async { [weak self] in self?.onEnd?("fixture ended during audio append") }
            // Keep the audio callback in append while the main queue processes onEnd.
            Thread.sleep(forTimeInterval: 0.03)
        }
        return true
    }
    func finish() { onEnd?(nil) }
    func cancel() {}
}

@main struct HyLiveTranslateTests {
    @MainActor static func main() async throws {
        if let modelIndex = CommandLine.arguments.firstIndex(of: "--model"), CommandLine.arguments.count > modelIndex + 1 {
            runFixture(URL(fileURLWithPath: CommandLine.arguments[modelIndex + 1]).lastPathComponent)
            return
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let suite = "HyLiveTranslateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"enabled":true,"endpoint":"wss://example.com/realtime","language":"ja","audioOutput":true}"#.utf8)
        let migrated = try JSONDecoder().decode(LiveTranslateConfiguration.self, from: legacy)
        try hyCheck(migrated.provider == .qwenCloud, "old installations remain cloud")
        try hyCheck(migrated.selecting(.hyLocal).language == "zh" && !migrated.selecting(.hyLocal).audioOutput, "local defaults do not inherit cloud speech")
        try migrated.save(defaults: defaults)
        let settings = AppModel(defaults: defaults, integrateSystem: false, runtimeVerified: { true }, localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        settings.liveEndpoint = "invalid unsaved cloud draft"
        settings.setLiveProvider(.hyLocal)
        try hyCheck(settings.liveProvider == .hyLocal && settings.liveLanguage == "zh" && !settings.liveAudioOutput, "invalid cloud draft does not block switching")
        try hyCheck(!settings.canStart, "verified runtime still requires a loaded model")
        settings.liveLanguage = "en"; settings.liveVolume = 0.4
        try hyCheck(settings.saveLiveSettings(), "local preferences save")
        settings.setLiveProvider(.qwenCloud)
        try hyCheck(settings.liveLanguage == "ja" && settings.liveAudioOutput && settings.liveEndpoint == migrated.endpoint, "cloud preferences restored independently")
        settings.setLiveProvider(.hyLocal)
        try hyCheck(settings.liveLanguage == "en" && settings.liveVolume == 0.4 && !settings.liveAudioOutput, "local saved preferences restored")
        settings.shutdown()
        let restored = LiveTranslateConfiguration.load(defaults: defaults)
        try hyCheck(restored.provider == .hyLocal && restored.language == "en" && restored.selecting(.qwenCloud).language == "ja", "both providers survive reload")
        try LiveTranslateConfiguration().save(defaults: defaults)
        let gatedSelection = AppModel(defaults: defaults, integrateSystem: false, runtimeVerified: { false },
            localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        gatedSelection.setLiveProvider(.hyLocal)
        try hyCheck(gatedSelection.liveProvider == .qwenCloud && !gatedSelection.liveMessage.isEmpty,
                    "unverified runtime rejects provider selection in the model layer")
        try hyCheck(LiveTranslateConfiguration.load(defaults: defaults).provider == .qwenCloud,
                    "rejected selection cannot change persisted provider")
        gatedSelection.shutdown()
        try LiveTranslateConfiguration(provider: .hyLocal).save(defaults: defaults)
        let gatedEnable = AppModel(defaults: defaults, integrateSystem: false, runtimeVerified: { false },
            localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        gatedEnable.setLiveEnabled(true)
        try hyCheck(!gatedEnable.liveEnabled && !gatedEnable.canStart && !gatedEnable.liveMessage.isEmpty,
                    "unverified persisted local selection cannot be enabled")
        try hyCheck(!gatedEnable.saveLiveSettings(enabled: true) && !LiveTranslateConfiguration.load(defaults: defaults).enabled,
                    "direct save cannot bypass the local enable gate")
        gatedEnable.shutdown()
        var invalid = restored; invalid.language = "ja"
        do { _ = try invalid.normalized(); throw HyTestFailure(description: "local Japanese was accepted") }
        catch is HyTestFailure { throw HyTestFailure(description: "local Japanese was accepted") }
        catch {}
        print("PASS: backwards configuration migration, independent provider preferences and native release gate")

        let local = LiveTranslateConfiguration(enabled: true, provider: .hyLocal)
        let session = HyLocalSession(loadTimeout: 2, finishTimeout: 2)
        var loaded = 0, failures: [String] = [], ready = false, ends: [String?] = [], updates: [LiveTranslationUpdate] = []
        session.onLoaded = { loaded += 1 }
        session.onLoadFailure = { failures.append($0) }
        session.onReady = { ready = true }
        session.onEnd = { ends.append($0) }
        session.onEvent = { if case .update(let update) = $0 { updates.append(update) } }
        try session.load(executableURL: executable, modelURL: URL(fileURLWithPath: "/fixture/normal"))
        try await hyWait { loaded == 1 || !failures.isEmpty }
        try hyCheck(session.isLoaded && failures.isEmpty, "helper hello validated")
        try hyCheck(!session.append(Data([0, 0])), "audio blocked before session ready")
        for count in 1...2 {
            ready = false
            try session.start(configuration: local, key: "", sessionID: "run-\(count)")
            try await hyWait { ready }
            try hyCheck(!session.append(Data(repeating: 0, count: 320_002)), "bounded audio queue")
            try hyCheck(!session.append(Data([0])), "odd PCM rejected")
            try hyCheck(session.append(Data(repeating: 0, count: 640)), "PCM accepted")
            session.finish()
            try await hyWait { ends.count == count }
            try hyCheck(ends.last! == nil && session.isLoaded, "normal finish preserves loaded model")
        }
        try hyCheck(loaded == 1 && updates.count == 6 && updates.allSatisfy { $0.revision != 99 }, "reuse and stale session filtering")
        try hyCheck(updates.contains { $0.committed && $0.sourceDone && $0.translationDone }, "interleave completion fields preserved")
        ready = false; try session.start(configuration: local, key: "", sessionID: "large-pcm")
        try await hyWait { ready }
        try hyCheck(session.append(Data(repeating: 0, count: 320_000)), "maximum admitted PCM callback is accepted")
        session.finish()
        try await hyWait { ends.count == 3 }
        try hyCheck(ends.last! == nil && session.isLoaded, "large callback is split below native JSONL limits")
        ready = false; try session.start(configuration: local, key: "", sessionID: "cancelled")
        try await hyWait { ready }
        session.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        try hyCheck(ends.count == 3, "cancel suppresses callbacks")
        session.unload()
        try hyCheck(!session.isLoaded, "unload clears readiness immediately")
        print("PASS: native JSONL framing, handshake, PCM bounds, interleave updates, reuse and cancellation")

        for mode in ["wrong-runtime", "bad-done", "partial", "crash", "timeout"] {
            let broken = HyLocalSession(loadTimeout: mode == "timeout" ? 0.1 : 2, finishTimeout: 1)
            var didLoad = false, error: String?, ended = false, didReady = false, warnings = 0
            broken.onLoaded = { didLoad = true }
            broken.onLoadFailure = { error = $0 }
            broken.onReady = { didReady = true }
            broken.onEnd = { ended = true; error = $0 }
            broken.onEvent = { if case .untranslatedAudio = $0 { warnings += 1 } }
            try broken.load(executableURL: executable, modelURL: URL(fileURLWithPath: "/fixture/" + mode))
            try await hyWait { didLoad || error != nil }
            if didLoad {
                try broken.start(configuration: local, key: "", sessionID: UUID().uuidString)
                try await hyWait { didReady || error != nil }
                _ = broken.append(Data(repeating: 0, count: 640)); broken.finish()
                try await hyWait { ended || error != nil }
            }
            try hyCheck(error != nil, "invalid/incomplete native state is surfaced: \(mode)")
            if mode == "partial" { try hyCheck(warnings == 1, "untranslated interval preserved") }
            else { try hyCheck(!broken.isLoaded, "broken helper cannot remain usable: \(mode)") }
            broken.unload()
        }
        print("PASS: runtime mismatch, missing completion fields, untranslated intervals, process crash and load timeout")

        let stubborn = HyLocalSession(loadTimeout: 3)
        var launches = 0
        stubborn.onLoaded = { launches += 1 }
        try stubborn.load(executableURL: executable, modelURL: URL(fileURLWithPath: "/fixture/ignore-term"))
        try await hyWait { launches == 1 }
        let unloadAt = Date()
        stubborn.unload()
        try hyCheck(Date().timeIntervalSince(unloadAt) < 0.5, "unload never waits on main thread")
        try stubborn.load(executableURL: executable, modelURL: URL(fileURLWithPath: "/fixture/normal"))
        try await hyWait { launches == 2 }
        try hyCheck(Date().timeIntervalSince(unloadAt) >= 1.5, "new helper waits for stubborn previous helper to be killed and reaped")
        stubborn.unload()
        print("PASS: nonblocking unload, forced-termination fallback and sequential model replacement")

        func turn(_ id: String, _ start: Int, _ end: Int, _ source: String, _ target: String, committed: Bool = true) -> LiveTranslationUpdate {
            LiveTranslationUpdate(segmentID: id, startSample: start, endSample: end, source: source, translation: target,
                                  revision: 1, sourceDone: committed, translationDone: committed, committed: committed)
        }
        var sentences = LiveSentenceRows()
        let opening = sentences.place(turn("1", 0, 16000, "大家好，", "Hello everyone, "))
        try hyCheck(opening.row == "1" && opening.startSample == 0, "the first turn opens a row")
        let partial = sentences.place(turn("2", 16000, 32000, "今天", "today", committed: false))
        try hyCheck(partial.row == "1" && partial.source == "大家好，今天" && partial.translation == "Hello everyone, today",
                    "a provisional turn shows after the row's committed text")
        let closing = sentences.place(turn("2", 16000, 48000, "今天开会。", "we meet. "))
        try hyCheck(closing.row == "1" && closing.source == "大家好，今天开会。" && closing.translation == "Hello everyone, we meet. "
                    && closing.startSample == 0 && closing.endSample == 48000, "a revision replaces only its own turn's text")
        let next = sentences.place(turn("3", 48000, 64000, "第二句", "Second"))
        try hyCheck(next.row == "3" && next.source == "第二句" && next.startSample == 48000, "a finished sentence closes its row")
        let afterPause = sentences.place(turn("4", 64000 + 3 * 16000 + 1, 128000, "停顿后", "after a pause"))
        try hyCheck(afterPause.row == "4", "a long pause closes an unfinished row")
        let long = String(repeating: "长", count: 400)
        _ = sentences.place(turn("5", 128000, 144000, long, "text"))
        try hyCheck(sentences.place(turn("6", 144000, 160000, "下一段", "next")).row == "6", "an endless sentence still gets new rows")
        print("PASS: Hy model turns join into sentence rows, with provisional text, pauses and a length bound")

        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("hy-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6400)!
            pcm.frameLength = 6400
            for i in 0..<6400 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
            try file.write(from: pcm)
        }
        let appSpeech = FixtureSpeech(), replaySpeech = FixtureSpeech()
        let saved = LiveTranslateConfiguration(enabled: true, language: "zh", audioOutput: true, provider: .hyLocal)
        try saved.save(defaults: defaults)
        var keyReads = 0
        let modelStore = HyModelStore(storage: FixtureModelStore(path: URL(fileURLWithPath: "/fixture/normal")))
        let app = AppModel(defaults: defaults, integrateSystem: false, liveKeyReader: { _ in keyReads += 1; return nil },
            hyModelStore: modelStore, runtimeVerified: { true }, runtimeExecutable: { executable },
            localSpeech: appSpeech, replaySpeech: replaySpeech)
        defer { app.shutdown() }
        app.loadHyModel()
        try await hyWait { app.hyRuntimeState == "ready" || app.hyRuntimeState == "error" }
        try hyCheck(app.canStart, "app becomes ready only after model verification and helper hello")
        app.audioSource = "file"; app.audioFileURL = audioURL
        for count in 1...2 {
            app.start()
            try await hyWait { app.state == "ready" && app.finalText.count == count }
            let row = app.finalText.last!
            try hyCheck(row.text == "Hello world." && row.translation == "你好，世界。" && !row.incomplete, "source revision and final bilingual row")
            try hyCheck(app.canReplay(row), "committed local translation can be replayed")
            app.replay(row)
        }
        try hyCheck(keyReads == 0, "local mode never reads cloud credentials")
        try hyCheck(appSpeech.spoken == ["你好，世界。", "你好，世界。"], "stale revisions never trigger duplicate speech")
        try hyCheck(replaySpeech.replayed.count == 2 && replaySpeech.replayed.allSatisfy { $0.1 == "zh" }, "replay preserves captured target language")
        try hyCheck(app.exportText == "Hello world.\n你好，世界。\n\nHello world.\n你好，世界。", "bilingual export remains compatible")
        app.clear()
        try hyCheck(app.finalText.isEmpty && app.exportText.isEmpty, "clear drops transcript and replay history")
        app.unloadHyModel()
        try hyCheck(!app.canStart && app.hyRuntimeState == "idle", "unload blocks start")
        print("PASS: app file audio to native helper, revisions, local-only credentials, TTS dispatch, replay, export and unload")

        try LiveTranslateConfiguration(enabled: true, provider: .hyLocal).save(defaults: defaults)
        let launched = AppModel(defaults: defaults, integrateSystem: false,
            hyModelStore: HyModelStore(storage: FixtureModelStore(path: URL(fileURLWithPath: "/fixture/normal"))),
            runtimeVerified: { true }, runtimeExecutable: { executable }, localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        try hyCheck(launched.hyRuntimeState == "idle" && launched.state == "idle" && launched.canLoadHyModel,
                    "opening the app takes no model memory and offers a load")
        launched.shutdown()
        try LiveTranslateConfiguration(enabled: true).save(defaults: defaults)
        let switched = AppModel(defaults: defaults, integrateSystem: false, liveKeyReader: { _ in nil },
            hyModelStore: HyModelStore(storage: FixtureModelStore(path: URL(fileURLWithPath: "/fixture/normal"))),
            runtimeVerified: { true }, runtimeExecutable: { executable }, localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        switched.setLiveProvider(.hyLocal)
        if switched.hyMemoryIsLow {
            try hyCheck(switched.hyRuntimeState == "idle" && switched.canLoadHyModel, "low memory leaves loading to the user")
        } else {
            try await hyWait { switched.canStart }
            try hyCheck(!switched.canLoadHyModel, "a loaded model offers no second load")
            switched.setLiveProvider(.qwenCloud)
            try hyCheck(switched.hyRuntimeState == "idle" && switched.canStart, "leaving local mode releases the model")
        }
        switched.shutdown()
        try LiveTranslateConfiguration().save(defaults: defaults)
        let notDownloaded = AppModel(defaults: defaults, integrateSystem: false,
            hyModelStore: HyModelStore(storage: FixtureModelStore(path: URL(fileURLWithPath: "/fixture/normal"), cached: false)),
            runtimeVerified: { true }, runtimeExecutable: { executable }, localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        notDownloaded.setLiveProvider(.hyLocal); notDownloaded.setLiveEnabled(true)
        try hyCheck(notDownloaded.liveEnabled && notDownloaded.hyRuntimeState == "idle", "a missing model never starts a load by itself")
        notDownloaded.shutdown()
        print("PASS: the switches load a downloaded model; opening the app or a missing model does not")

        // Exercise the actual phrase aggregator: committed text has no punctuation and therefore
        // is not playing until normal session completion flushes it to the injected speech device.
        for mode in ["tail-sync", "tail-async", "tail-error", "tail-cancel"] {
            let device = FixtureSpeechDevice(synchronous: mode == "tail-sync")
            let output = LocalSpeechOutput(queue: device)
            try LiveTranslateConfiguration(enabled: true, audioOutput: true, playbackTiming: .afterFinal, provider: .hyLocal).save(defaults: defaults)
            let tailApp = AppModel(defaults: defaults, integrateSystem: false,
                hyModelStore: HyModelStore(storage: FixtureModelStore(path: URL(fileURLWithPath: "/fixture/" + mode))),
                runtimeVerified: { true }, runtimeExecutable: { executable }, localSpeech: output, replaySpeech: FixtureSpeech())
            tailApp.loadHyModel()
            try await hyWait { tailApp.canStart }
            tailApp.audioSource = "file"; tailApp.audioFileURL = audioURL; tailApp.start()
            try await hyWait { !tailApp.finalText.isEmpty }
            try hyCheck(device.texts.isEmpty && !tailApp.livePlaying, "unpunctuated committed tail stays buffered before EOF: \(mode)")
            if mode == "tail-cancel" {
                tailApp.shutdown()
                try await Task.sleep(nanoseconds: 100_000_000)
                try hyCheck(device.texts.isEmpty, "shutdown discards buffered local speech without flushing")
            } else if mode == "tail-error" {
                try await hyWait { tailApp.state == "ready" }
                try hyCheck(device.texts.isEmpty && !tailApp.error.isEmpty, "failed local completion never flushes buffered speech")
            } else if mode == "tail-async" {
                try await hyWait { device.texts.count == 1 }
                try hyCheck(device.texts == ["你好"] && tailApp.state == "finalizing" && tailApp.livePlaying,
                            "normal completion flushes idle speech and awaits asynchronous playback")
                device.completeAll()
                try hyCheck(tailApp.state == "ready" && !tailApp.livePlaying, "asynchronous tail completion restores readiness")
            } else {
                try await hyWait { tailApp.state == "ready" }
                try hyCheck(device.texts == ["你好"] && !tailApp.livePlaying,
                            "synchronous tail completion restores readiness without getting stuck")
            }
            tailApp.shutdown()
        }
        print("PASS: local speech EOF flush with synchronous/asynchronous playback, failure and cancellation")

        try LiveTranslateConfiguration(enabled: true).save(defaults: defaults)
        var endingSessions: [EndingFixtureSession] = []
        let endingApp = AppModel(defaults: defaults, integrateSystem: false, liveKeyReader: { _ in "fixture-only" },
            liveSessionFactory: { _ in let value = EndingFixtureSession(); endingSessions.append(value); return value },
            localSpeech: FixtureSpeech(), replaySpeech: FixtureSpeech())
        defer { endingApp.shutdown() }
        endingApp.audioSource = "file"; endingApp.audioFileURL = audioURL
        for count in 1...5 {
            endingApp.start()
            try await hyWait { endingSessions.count == count && endingApp.state == "ready" }
            try hyCheck(endingSessions.last!.appendCount == 1, "session end detaches audio atomically")
        }
        try hyCheck(endingApp.error.contains("fixture ended"), "concurrent provider end remains visible")
        print("PASS: provider completion concurrent with audio append stops capture and supports immediate restart")
    }
}
