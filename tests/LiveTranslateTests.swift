import Foundation
import AVFoundation

struct LiveTestError: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw LiveTestError(message: message) }
}

@MainActor final class Probe {
    var ready = false
    var ended = false
    var error: String?
    var events = LiveTranslateEvents()
    var bytes = 0
    var audioBytes = 0
    var audioDecoder = LiveTranslateAudioDecoder()
    var callbacks = 0
    let client: LiveTranslateClient
    init(timeout: TimeInterval = 30, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        client = LiveTranslateClient(finishTimeout: timeout, uptime: uptime)
        client.onReady = { [weak self] in self?.ready = true; self?.callbacks += 1 }
        client.onEvent = { [weak self] event in
            self?.callbacks += 1
            self?.events.apply(event)
            if let pcm = try? self?.audioDecoder.consume(event) { self?.audioBytes += pcm.count }
            if event["type"] as? String == "fixture.audio_bytes" { self?.bytes = event["count"] as? Int ?? 0 }
        }
        client.onEnd = { [weak self] error in self?.ended = true; self?.error = error; self?.callbacks += 1 }
    }
    func connect(_ url: String, audio: Bool = false) throws {
        try client.connect(configuration: .init(endpoint: url, audioOutput: audio), key: "mock-only", allowLocalhost: true)
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LiveTestError(message: "Timed out waiting for websocket fixture")
    }
}

@main struct LiveTranslateTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        // API keys go to a temporary file store, never the real data root or the login Keychain.
        let keyDirectory = ProcessInfo.processInfo.environment["RECORDER_TEST_KEY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("live-keys-\(UUID().uuidString)")
        APIKeyStore.shared = APIKeyFileStore(directory: keyDirectory)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--read-profile" {
            let suite = UserDefaults(suiteName: CommandLine.arguments[2])!
            let saved = LiveTranslateConfiguration.load(defaults: suite)
            try check(saved.profile.id == CommandLine.arguments[3] && saved.catalog.profiles.count == 3, "selection in new process")
            try check(try APIKeyStore.read(endpoint: saved.keyAccount) == (saved.profile.id == "c" ? "mock-c" : "mock-only"),
                      "credential in new process")
            return
        }
        defer { try? FileManager.default.removeItem(at: keyDirectory) }
        let suite = "recorder.live.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"enabled":true,"endpoint":"wss://example.com/realtime","language":"en"}"#.utf8)
        let migrated = try JSONDecoder().decode(LiveTranslateConfiguration.self, from: legacy)
        try check(migrated.enabled && !migrated.audioOutput && migrated.volume == 0.8, "existing configuration preserved without enabling sound")
        try check(migrated.playbackTiming == .streaming, "old settings keep immediate playback")
        let audioConfig = LiveTranslateConfiguration(audioOutput: true, volume: 0.35, playbackTiming: .afterFinal)
        try audioConfig.save(defaults: defaults)
        try check(LiveTranslateConfiguration.load(defaults: defaults) == audioConfig, "audio settings survive reload")
        var decoder = LiveTranslateAudioDecoder()
        func audioEvent(_ id: String, _ data: Data) -> [String: Any] {
            ["type": "response.audio.delta", "event_id": id, "item_id": "a", "delta": data.base64EncodedString()]
        }
        try check(try decoder.consume(audioEvent("one", Data([0]))) == nil, "partial PCM sample buffered")
        let pcm = try decoder.consume(audioEvent("two", Data([64, 0, 128, 255, 127])))!
        let decoded = try LiveTranslateAudioDecoder.buffer(pcm)
        try check(decoded.frameLength == 3 && decoded.floatChannelData![0][0] == 0.5 && decoded.floatChannelData![0][1] == -1, "PCM16 little endian conversion")
        try check(try decoder.consume(audioEvent("two", Data([0, 0]))) == nil, "duplicate audio never replays")
        _ = try decoder.consume(["type": "response.audio.done", "item_id": "a"])
        try check(try decoder.consume(audioEvent("late", Data([0, 0]))) == nil, "late audio ignored after done")
        var corrupt = LiveTranslateAudioDecoder()
        var rejected = false
        do { _ = try corrupt.consume(["type": "response.audio.delta", "item_id": "a", "delta": "bad base64!"]) } catch { rejected = true }
        try check(rejected, "invalid audio rejected")
        _ = try corrupt.consume(audioEvent("odd", Data([0])))
        rejected = false
        do { _ = try corrupt.consume(["type": "response.audio.done", "item_id": "a"]) } catch { rejected = true }
        try check(rejected, "incomplete final PCM sample rejected")
        var textEvents = LiveTranslateEvents()
        var delayed = LiveTranslatePlaybackQueue(timing: .afterFinal)
        func sourceFinal(_ id: String) -> [String: Any] {
            ["type": "conversation.item.input_audio_transcription.completed", "item_id": id, "transcript": "source"]
        }
        func mapping(_ source: String, _ output: String) -> [String: Any] {
            ["type": "conversation.item.created", "previous_item_id": source, "item": ["id": output, "role": "assistant"]]
        }
        func textFinal(_ output: String) -> [String: Any] {
            ["type": "response.audio_transcript.done", "item_id": output, "transcript": "译文"]
        }
        func doneAudio(_ output: String) -> [String: Any] { ["type": "response.audio.done", "item_id": output] }
        func feed(_ event: [String: Any]) throws -> [Data] {
            textEvents.apply(event)
            return try delayed.consume(event, transcripts: textEvents)
        }
        let chunk = audioEvent("buffered", Data([0, 64]))
        try check(try feed(chunk).isEmpty && delayed.hasPendingAudio, "audio arriving before association is buffered")
        try check(try feed(mapping("s", "a")).isEmpty, "association alone cannot start playback")
        try check(try feed(doneAudio("a")).isEmpty, "complete audio waits for source and translation")
        try check(try feed(textFinal("a")).isEmpty, "final translation waits for final source")
        try check(try feed(sourceFinal("s")) == [Data([0, 64])], "late source final releases whole utterance")
        try check(try feed(sourceFinal("s")).isEmpty && !delayed.hasPendingAudio, "duplicate final does not replay")
        delayed = LiveTranslatePlaybackQueue(timing: .afterFinal); textEvents = LiveTranslateEvents()
        _ = try feed(mapping("first", "a")); _ = try feed(mapping("second", "b"))
        _ = try feed(sourceFinal("second")); _ = try feed(textFinal("b"))
        var secondChunk = audioEvent("second", Data([1, 64])); secondChunk["item_id"] = "b"
        _ = try feed(secondChunk)
        try check(try feed(doneAudio("b")).isEmpty, "later utterance cannot overtake pending first sentence")
        _ = try feed(chunk); _ = try feed(sourceFinal("first")); _ = try feed(textFinal("a"))
        try check(try feed(doneAudio("a")) == [Data([0, 64]), Data([1, 64])], "completed sentences released in order")
        var immediate = LiveTranslatePlaybackQueue(timing: .streaming)
        try check(try immediate.consume(chunk, transcripts: LiveTranslateEvents()) == [Data([0, 64])], "streaming mode plays before any final")
        delayed = LiveTranslatePlaybackQueue(timing: .afterFinal); textEvents = LiveTranslateEvents()
        rejected = false
        do { _ = try feed(audioEvent("large", Data(repeating: 0, count: 1_440_002))) } catch { rejected = true }
        try check(rejected, "waiting audio memory is bounded")
        delayed = LiveTranslatePlaybackQueue(timing: .afterFinal)
        try check(!delayed.hasPendingAudio, "new session clears waiting audio")
        print("PASS: selectable playback timing, late finals, ordered sentences, duplicates and bounded buffering")
        var replayCache = LiveTranslateReplayCache(capacity: 8)
        var replayText = LiveTranslateEvents()
        func captureReplay(_ event: [String: Any], session: String = "one") {
            replayText.apply(event); replayCache.consume(event, transcripts: replayText, session: session)
        }
        captureReplay(chunk)
        captureReplay(mapping("s", "a"))
        captureReplay(sourceFinal("s")); captureReplay(textFinal("a"))
        try check(replayCache.audio(for: "one:live:s") == nil, "replay waits for complete audio")
        captureReplay(doneAudio("a"))
        try check(replayCache.audio(for: "one:live:s") == Data([0, 64]), "replay retains exact audio by transcript ID")
        let cacheRevision = replayCache.revision
        captureReplay(doneAudio("a")); captureReplay(sourceFinal("s"))
        try check(replayCache.revision == cacheRevision, "duplicate finals never append duplicate clips")
        try check(replayCache.audio(for: "one:live:s") == replayCache.audio(for: "one:live:s"), "reading replay is nondestructive")
        replayCache.beginSession(); replayText = LiveTranslateEvents()
        try check(replayCache.audio(for: "one:live:s") != nil, "previous recording remains replayable")
        captureReplay(mapping("s", "a"), session: "two")
        captureReplay(audioEvent("new-session", Data(repeating: 1, count: 8)), session: "two")
        captureReplay(sourceFinal("s"), session: "two"); captureReplay(textFinal("a"), session: "two")
        captureReplay(doneAudio("a"), session: "two")
        try check(replayCache.audio(for: "one:live:s") == nil && replayCache.audio(for: "two:live:s")?.count == 8, "bounded cache evicts oldest clip without mixing session IDs")
        replayCache.clear()
        try check(replayCache.audio(for: "two:live:s") == nil, "clear releases retained audio")
        print("PASS: replay cache association, completion, duplicates, repeated reads, session isolation and eviction")
        var config = LiveTranslateConfiguration(enabled: true, endpoint: "wss://EXAMPLE.com:443/api-ws/v1/realtime?model=old", language: "ja")
        config = try config.normalized()
        try check(config.endpoint == "wss://example.com/api-ws/v1/realtime", "normalized endpoint")
        try check(config.keyAccount == "livetranslate:" + config.endpoint, "dedicated key namespace")
        try check(config.keyAccount != "asr:" + config.endpoint, "ASR credentials isolated")
        try config.save(defaults: defaults)
        try check(LiveTranslateConfiguration.load(defaults: defaults) == config, "configuration persists")
        try check(try config.url().query == "model=qwen3.8-livetranslate-flash-realtime", "fixed model query")
        for address in ["https://example.com/realtime", "ws://example.com/realtime", "wss://user:secret@example.com/realtime", "wss://example.com/realtime?key=secret", "wss://example.com/realtime#secret"] {
            var rejected = false
            do { _ = try LiveTranslateConfiguration(endpoint: address).url() } catch { rejected = true }
            try check(rejected, "unsafe URL rejected")
        }
        var unknown = config
        var unsupported = config.profile; unsupported.version = "3.5"
        unknown.catalog.use(unsupported)
        try check((try? unknown.url()) == nil, "unsupported protocol version rejected before connection")
        let model = AppModel(defaults: defaults, integrateSystem: false)
        defer { model.shutdown() }
        try check(model.liveEnabled && model.canStart, "Live mode starts without local models")
        model.load(); model.loadTranslator()
        try check(model.state == "ready", "local model load routes disabled")
        let liveMenu = TranslationMenu(model: model)
        model.partial = "live partial"
        try check(liveMenu == TranslationMenu(model: model), "LiveTranslate transcription keeps the menu stable")
        let target = model.translationTarget
        model.setTranslation(enabled: true); model.setTranslationTarget("English")
        try check(!model.translationEnabled && model.translationTarget == target, "other translation route disabled")
        model.state = "recording"
        model.setLiveEnabled(false)
        try check(model.liveEnabled, "cannot switch during recording")
        model.state = "finalizing"
        try check(!model.saveLiveSettings(enabled: false), "cannot switch during finalization")
        model.state = "ready"
        model.liveEndpoint = "invalid draft"
        model.setLiveEnabled(false)
        try check(!model.liveEnabled && !LiveTranslateConfiguration.load(defaults: defaults).enabled, "can leave mode with invalid draft")
        try check(model.translationTarget == target, "previous translation preference preserved")

        let menu = TranslationMenu(model: model)
        try check(menu != liveMenu, "leaving LiveTranslate reveals ordinary translation controls")
        model.level = 0.5
        model.partial = "in progress"
        model.translationTick += 1
        try check(menu == TranslationMenu(model: model), "transcript updates leave the open translation menu alone")
        model.setTranslationTarget("日本語")
        try check(menu != TranslationMenu(model: model), "a new target updates the checkmark even with translation off")
        model.setTranslationTarget(target)
        model.translatorState = "warming"
        let warmingMenu = TranslationMenu(model: model)
        try check(menu != warmingMenu, "warming disables the ordinary translation toggle")
        model.translatorState = "downloading"
        try check(warmingMenu == TranslationMenu(model: model), "a tooltip-only change leaves the open menu alone")
        model.translatorState = "idle"

        var events = LiveTranslateEvents()
        let delta: [String: Any] = ["event_id": "same", "type": "response.text.delta", "item_id": "t", "delta": "译文"]
        events.apply(delta); events.apply(delta)
        events.apply(["type": "response.text.done", "item_id": "t", "text": "完整译文"])
        events.apply(["type": "response.text.delta", "item_id": "t", "delta": "忽略迟到内容"])
        try check(events.hasUnmatchedOutput, "unmatched translation buffered")
        events.apply(["type": "conversation.item.created", "previous_item_id": "s", "item": ["id": "t", "role": "assistant"]])
        events.apply(["type": "conversation.item.created", "previous_item_id": "s", "item": ["id": "t", "role": "assistant"]])
        events.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "s", "transcript": "完整原文"])
        events.apply(["type": "conversation.item.input_audio_transcription.delta", "item_id": "s", "delta": "忽略迟到内容"])
        try check(events.rows.count == 1 && events.rows["s"]!.source.text == "完整原文", "one source row, final authoritative")
        try check(events.translation(for: events.rows["s"]!).text == "完整译文", "out-of-order translation associated once")
        try check(!events.hasUnmatchedOutput, "pending association resolved")
        events.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "s2", "transcript": "完整原文"])
        try check(events.rows.count == 2, "repeated speech is never deduplicated by text")

        guard let base = ProcessInfo.processInfo.environment["RECORDER_LIVE_MOCK"] else { throw LiveTestError(message: "Use scripts/test_livetranslate.sh") }
        for _ in 0..<2 {
            let probe = Probe()
            try check(!probe.client.append(Data([0, 0])), "audio blocked before ready")
            try probe.connect(base + "/ok")
            try await probe.wait { probe.ready || probe.ended }
            try check(probe.ready, "configuration acknowledged")
            for _ in 0..<30 { try check(probe.client.append(Data(repeating: 0, count: 640)), "audio accepted") }
            probe.client.finish()
            try await probe.wait { probe.ended }
            try check(probe.error == nil && probe.bytes == 30 * 640, "finish follows all queued audio")
            let row = probe.events.rows["source"]!
            try check(row.source.text == "Hello world." && row.source.done, "source tail collected")
            let translated = probe.events.translation(for: row)
            try check(translated.text == "你好，世界🌏。" && translated.done, "translation tail collected")
            try check(row.seconds == 1.2, "audio timestamp mapping")
            try check(!probe.client.append(Data([0, 0])), "closed session rejects audio")
        }
        // Exercise the app's real file-input -> websocket -> rows -> export path, without any models.
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200)!
            buffer.frameLength = 3200
            for i in 0..<3200 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
            try file.write(from: buffer)
        }
        // Upgrade a legacy address, then add a second model on it and a separately authenticated endpoint.
        let profileDefaults = UserDefaults(suiteName: suite + "-profiles")!
        defer { profileDefaults.removePersistentDomain(forName: suite + "-profiles") }
        let ab = base + "/profiles/ab", other = base + "/profiles/c"
        let legacyProfile = try JSONSerialization.data(withJSONObject: ["enabled": true, "endpoint": ab, "language": "zh"])
        profileDefaults.set(legacyProfile, forKey: "livetranslate.configuration.v1")
        // Keys per address in the temporary key store; the restarted process reads them back.
        for (address, value) in [(ab, "mock-only"), (other, "mock-c")] {
            let account = "livetranslate:" + address
            try check(try APIKeyStore.read(endpoint: account) == nil, "fixture needs an unused key account")
            try APIKeyStore.save(value, endpoint: account)
        }
        var profileClients = [LiveTranslateClient]()
        let profileApp = AppModel(defaults: profileDefaults, integrateSystem: false, liveAllowLocalhost: true,
            liveClientFactory: {
                let client = LiveTranslateClient(allowLocalhost: true)
                profileClients.append(client)
                return client
            },
            liveKeyReader: { try APIKeyStore.read(endpoint: $0) })
        defer { profileApp.shutdown() }
        var a = profileApp.liveProfile
        a.name = "A"; a.modelID = "model-a"; a.threshold = 0.4; a.silenceMS = 600
        var b = a; b.id = "b"; b.name = "B"; b.modelID = "model+b"; b.turnDetection = "speaker_detection"
        var c = a; c.id = "c"; c.name = "C"; c.endpoint = other; c.modelID = "model-c"
        for profile in [a, b, c] {
            profileApp.liveProfile = profile
            try check(profileApp.saveLiveSettings(), "save named profile")
        }
        profileApp.audioSource = "file"; profileApp.audioFileURL = URL(fileURLWithPath: "tests/fixtures/livetranslate-16k.wav")
        let profileWait = Probe()
        for (index, profile) in [a, b, c, a].enumerated() {
            profileApp.selectLiveProfile(profile.id)
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            reopen.arguments = ["--read-profile", suite + "-profiles", profile.id]
            reopen.environment = ProcessInfo.processInfo.environment.merging(["RECORDER_TEST_KEY_DIR": keyDirectory.path]) { $1 }
            try reopen.run(); reopen.waitUntilExit()
            try check(reopen.terminationStatus == 0, "restarted process restored selected profile")
            let restored = LiveTranslateConfiguration.load(defaults: profileDefaults)
            try check(restored.catalog.profiles == [a, b, c] && restored.profile == profile, "restore exact selection")
            profileApp.testLiveConnection()
            try await profileWait.wait { !profileApp.liveTesting }
            try check(profileApp.liveMessage.contains("连接成功") && profileApp.finalText.count == index, "silent profile probe")
            profileApp.start()
            try await profileWait.wait { profileApp.finalText.count == index + 1 && profileApp.state == "ready" }
            try check(profileApp.finalText.last?.translation == "你好，世界🌏。", "profile recording drains tail")
        }
        let recordingOwner = profileApp.activeSessionID
        var browsed = profileApp.sessionLibrary.load(id: recordingOwner)!
        browsed.id = SessionFile.newID()
        try profileApp.sessionLibrary.save(browsed)
        profileApp.start()
        try await profileWait.wait { profileApp.state == "recording" && profileApp.finalText.count > 4 }
        profileApp.selectSession(browsed.id)
        try check(profileApp.viewedSession?.id == browsed.id, "can browse another conversation while recording")
        profileClients.last?.onSlowService?(true)
        profileApp.switchRecordingProfile(b)
        try await profileWait.wait { profileApp.liveConfiguration.profile.id == b.id && profileApp.state == "ready" }
        try check(profileApp.activeSessionID == recordingOwner && profileApp.viewedSession?.id == browsed.id,
                  "automatic restart after switching service keeps recording in the original conversation")
        try check(profileApp.sessionLibrary.load(id: browsed.id) == browsed && profileApp.finalText.count == 6,
                  "read-only history is unchanged and both segments are saved to their owner")
        try check(profileApp.finalText.suffix(2).allSatisfy { $0.sourceDone && !$0.incomplete }, "switch drains both segments into history")
        profileApp.selectLiveProfile(a.id)
        profileApp.liveKeyInput = "mock-only"
        profileApp.liveProfile.endpoint = other
        try check(profileApp.liveKeyInput.isEmpty, "changing address synchronously clears draft key")
        profileApp.liveProfile.modelID = "missing"
        profileApp.testLiveConnection()
        try await profileWait.wait { !profileApp.liveTesting }
        try check(!profileApp.liveMessage.contains("成功") && !profileApp.liveMessage.contains("mock-"), "model failure is safe")
        try check(LiveTranslateConfiguration.load(defaults: profileDefaults).profile == a, "failed test preserves saved model")
        print("PASS: per-address API key files, read back by a restarted process")
        print("PASS: migrated credential account, A/B/C profile selection, shared handshake, recording and failed draft isolation")
        let mockConfig = LiveTranslateConfiguration(enabled: true, endpoint: base + "/ok")
        defaults.set(try JSONEncoder().encode(mockConfig), forKey: "livetranslate.configuration.v1")
        var clients: [LiveTranslateClient] = []
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("live-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let sessionStore = SessionStore(directory: sessionDirectory)
        let app = AppModel(defaults: defaults, integrateSystem: false, liveClientFactory: {
            let client = LiveTranslateClient(allowLocalhost: true); clients.append(client); return client
        }, liveKeyReader: { account in
            try check(account == mockConfig.keyAccount, "app requests only dedicated credential")
            return "mock-only"
        }, sessionStore: sessionStore)
        defer { app.shutdown() }
        app.audioSource = "file"; app.audioFileURL = audioURL
        let waiter = Probe()
        for count in 1...2 {
            app.start()
            try await waiter.wait { app.finalText.count == count && app.state == "ready" }
            try check(app.finalText.last!.text == "Hello world.", "file input reaches source row")
            try check(app.finalText.last!.translation == "你好，世界🌏。", "file EOF drains translation tail")
            try check(!app.finalText.last!.incomplete && app.finalText.last!.sourceDone, "both sides finalized")
            try check(app.exportText.contains("Hello world.\n你好，世界🌏。"), "bilingual export")
            try check(app.joinedText.components(separatedBy: "\n").count == count, "restarts create distinct row IDs")
        }
        let previousRows = app.exportText
        clients[0].onEvent?(["type": "conversation.item.input_audio_transcription.completed", "item_id": "stale", "transcript": "MUST NOT APPEAR"])
        clients[0].onEnd?("MUST NOT APPEAR")
        try check(app.exportText == previousRows && app.error.isEmpty, "stale session callbacks ignored")
        app.start(); app.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(app.state == "ready" && app.exportText == previousRows, "stop during handshake does not start capture")
        // Both recordings went into one conversation session, finalized rows only, segments closed.
        let stored = sessionStore.list()
        try check(stored.count == 1 && stored[0].segments.count == 2 && stored[0].rows.map(\.segment) == [0, 1], "one session, one segment per recording")
        try check(stored[0].rows.allSatisfy { $0.kind == .text && $0.source == "Hello world." && $0.translation == "你好，世界🌏。" }, "finalized rows saved")
        try check(stored[0].segments.allSatisfy { $0.endedAtMs != nil && $0.mode == "live_translate" && $0.targetLanguage == "zh" }, "segments closed with mode and language")
        try check(stored[0].rows.allSatisfy { $0.languages.target == "zh" }, "live rows store their own target")
        try check(stored[0].title.hasSuffix(" Hello world.") && !stored[0].titleEdited, "default title")
        try check(app.sessionSummaries.map(\.id) == [stored[0].id] && app.recordingSessionID == nil && app.continuesSession, "listed, not recording")
        app.clear()
        try check(app.finalText.isEmpty && app.exportText.isEmpty, "clear removes both languages")
        try check(app.activeSessionID != stored[0].id && sessionStore.list().count == 1 && !app.continuesSession, "clear starts a new session and keeps the old one")
        // Selecting a past session while idle makes it the one the next recording continues.
        app.selectSession(stored[0].id)
        try check(app.activeSessionID == stored[0].id && app.finalText.count == 2 && app.exportText == previousRows, "past session reopened")
        app.start()
        try await waiter.wait { app.finalText.count == 3 && app.state == "ready" }
        let continued = sessionStore.load(id: stored[0].id)!
        try check(continued.segments.count == 3 && continued.rows.map(\.segment) == [0, 1, 2] && continued.createdAtMs == stored[0].createdAtMs, "continue recording appends a segment")
        try check(SessionExport.render(continued, format: .txt, content: .bilingual).contains("【继续录制 "), "export marks the continued recording")
        // Persistence off: nothing new is written, but the session stays listed for this run; deleting still works.
        app.persistSessions = false
        try check(defaults.object(forKey: AppModel.persistSessionsKey) as? Bool == false, "switch persisted")
        app.clear(); app.start()
        try await waiter.wait { app.finalText.count == 1 && app.state == "ready" }
        try check(sessionStore.list().map(\.id) == [stored[0].id] && app.sessionSummaries.count == 2, "no writes while persistence is off")
        app.renameSession(stored[0].id, to: "  改名  ")
        try check(sessionStore.load(id: stored[0].id)?.title == continued.title && app.sessionSummaries.contains { $0.title == "改名" }, "rename stays in memory")
        app.deleteSession(stored[0].id)
        try check(sessionStore.list().isEmpty && app.sessionSummaries.count == 1, "delete removes the file even with persistence off")
        app.persistSessions = true
        try check(sessionStore.list().map(\.id) == [app.activeSessionID], "turning persistence back on saves the active session")
        app.deleteAllSessions()
        try check(sessionStore.list().isEmpty && app.sessionSummaries.isEmpty && app.finalText.isEmpty, "delete all")

        print("PASS: previous text-only and app file-input regressions")
        let spoken = Probe()
        try spoken.connect(base + "/ok", audio: true)
        try await spoken.wait { spoken.ready || spoken.ended }
        try check(spoken.ready, "audio format acknowledged")
        _ = spoken.client.append(Data(repeating: 0, count: 640))
        spoken.client.finish()
        try await spoken.wait { spoken.ended }
        try check(spoken.error == nil && spoken.audioBytes == 4800, "audio output received once despite duplicates")
        try check(spoken.events.translation(for: spoken.events.rows["source"]!).text == "你好，世界🌏。", "spoken translation still yields subtitles")
        let badFormat = Probe()
        try badFormat.connect(base + "/wrong-audio-format", audio: true)
        try await badFormat.wait { badFormat.ended }
        try check(badFormat.error != nil && !badFormat.ready, "unexpected audio sample rate rejected before capture")
        print("PASS: audio websocket events and output format verification")
        // Offline engine exercises scheduled playback and volume without playing sound on the user's speakers.
        let engine = AVAudioEngine()
        let offlineFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 1024)
        let player = LiveTranslateAudioPlayer(engineFactory: { engine })
        try player.start(volume: 0.5)
        try player.append(Data([[UInt8]](repeating: [0, 64], count: 2400).flatMap { $0 }))
        let rendered = AVAudioPCMBuffer(pcmFormat: offlineFormat, frameCapacity: 1024)!
        var peak: Float = 0
        for _ in 0..<8 {
            _ = try engine.renderOffline(1024, to: rendered)
            for i in 0..<Int(rendered.frameLength) { peak = max(peak, abs(rendered.floatChannelData![0][i])) }
        }
        try check(peak > 0.15 && peak < 0.3, "volume applied in offline audio render")
        var drained = false
        player.finish { drained = true }
        for _ in 0..<4 { _ = try engine.renderOffline(1024, to: rendered) }
        try await waiter.wait { drained }
        player.stop()
        print("PASS: offline playback, volume and drain")

        let empty = Probe()
        try empty.connect(base + "/ok")
        try await empty.wait { empty.ready }
        empty.client.finish()
        try await empty.wait { empty.ended }
        try check(empty.error == nil && empty.bytes == 0 && empty.events.rows.isEmpty, "connection test sends no audio")
        for route in ["/unauthorized", "/redirect", "/error", "/wrong-language", "/model-error", "/wrong-mode", "/disconnect", "/timeout"] {
            let probe = Probe(timeout: 0.1)
            try probe.connect(base + route)
            try await probe.wait { probe.ready || probe.ended }
            if probe.ready {
                if route == "/disconnect" { _ = probe.client.append(Data([0, 0])) }
                else { probe.client.finish() }
            }
            try await probe.wait { probe.ended }
            try check(probe.error != nil, "failure surfaced: \(route)")
            try check(!probe.error!.contains("mock-only"), "provider payload never leaks credentials")
        }
        var virtualTime: TimeInterval = 0
        let slowReader = Probe(uptime: { virtualTime += 16; return virtualTime })
        var speedChanges: [Bool] = []
        slowReader.client.onSlowService = { speedChanges.append($0) }
        try slowReader.connect(base + "/slow-reader")
        try await slowReader.wait { slowReader.ready }
        _ = slowReader.client.append(Data([0, 0]))
        try await slowReader.wait { speedChanges == [true, false] }
        slowReader.client.finish()
        try await slowReader.wait { slowReader.ended }
        for (route, kind) in [("/rate-limited", LiveCloudEndKind.rateLimited), ("/no-semantic", .noResult), ("/no-semantic-close", .noResult)] {
            let probe = Probe()
            try probe.connect(base + route)
            try await probe.wait { probe.ready || probe.ended }
            if probe.ready { _ = probe.client.append(Data([0, 0])) }
            try await probe.wait { probe.ended }
            try check(probe.client.endKind == kind && probe.error == kind.message, "classified service end: " + route)
        }
        let cancel = Probe()
        try cancel.connect(base + "/ok")
        try await cancel.wait { cancel.ready }
        try check(!cancel.client.append(Data(repeating: 0, count: 320_001)), "bounded audio queue")
        cancel.client.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let callbacks = cancel.callbacks
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(cancel.callbacks == callbacks && !cancel.ended, "cancel suppresses subsequent transport callbacks")

        // AppModel audio source persistence, idle-only switching lock, echo hint and permission gating.
        let audioSuite = "test.appmodel.audiosource.\(UUID().uuidString)"
        let audioDefaults = UserDefaults(suiteName: audioSuite)!
        defer { audioDefaults.removePersistentDomain(forName: audioSuite) }
        var screenGranted = false
        var micGranted = false
        let audioApp = AppModel(
            defaults: audioDefaults,
            integrateSystem: false,
            liveAllowLocalhost: true,
            screenCaptureAuthorized: { screenGranted },
            requestMicrophoneAccess: { $0(micGranted) }
        )
        defer { audioApp.shutdown() }
        try check(audioApp.audioSource == "microphone", "fresh AppModel defaults to microphone")
        try check(!audioApp.screenCaptureAuthorized && audioApp.screenCapturePermission == "未允许", "screen capture preflight reflects unauthorized")
        // Verify connecting state locks switching, then ready state allows switching.
        audioApp.shutdown()
        audioApp.state = "connecting"
        audioApp.setAudioSource("system_mix")
        try check(audioApp.audioSource == "microphone", "audioSource must stay locked while connecting")
        audioApp.state = "ready"
        audioApp.setAudioSource("system_mix")
        try check(audioApp.audioSource == "system_mix", "idle switch to system_mix succeeds")
        try check(audioApp.shouldShowEchoHint, "system_mix without headphones shows non-blocking echo hint")

        // Persistence across relaunch.
        let restoredAudioApp = AppModel(
            defaults: audioDefaults,
            integrateSystem: false,
            liveAllowLocalhost: true,
            screenCaptureAuthorized: { true },
            requestMicrophoneAccess: { $0(true) }
        )
        defer { restoredAudioApp.shutdown() }
        restoredAudioApp.shutdown()
        try check(restoredAudioApp.audioSource == "system_mix", "AppModel restores saved system_mix mode")
        try check(restoredAudioApp.screenCaptureAuthorized && restoredAudioApp.screenCapturePermission == "已允许", "screen capture preflight reflects authorized")

        // Idle-only switching lock.
        restoredAudioApp.state = "recording"
        restoredAudioApp.setAudioSource("microphone")
        try check(restoredAudioApp.audioSource == "system_mix", "audioSource must stay locked while recording")
        restoredAudioApp.state = "ready"
        restoredAudioApp.setAudioSource("system")
        try check(restoredAudioApp.audioSource == "system", "audioSource unlocks when idle/ready")

        // Permission gates in system and system_mix modes:
        // - CGPreflightScreenCaptureAccess() == false must NOT hard-block start() (SCShareableContent/SCStream is authoritative).
        // - Microphone permission IS strictly gated in system_mix mode.
        func waitCondition(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw LiveTestError(message: "Timed out waiting for audio permission check")
        }
        audioApp.state = "ready"
        audioApp.setAudioSource("system")
        screenGranted = false
        audioApp.start()
        try check(audioApp.error.isEmpty && audioApp.canStop, "system mode must not hard-block start() when CGPreflightScreenCaptureAccess() is false: \(audioApp.error)")
        audioApp.stop()

        audioApp.state = "ready"
        audioApp.setAudioSource("system_mix")
        micGranted = false; screenGranted = false
        audioApp.start()
        try await waitCondition { !audioApp.error.isEmpty }
        try check(audioApp.error.contains("麦克风权限"), "system_mix missing mic permission must block with mic guidance: \(audioApp.error)")

        audioApp.error = ""
        audioApp.state = "ready"
        micGranted = true; screenGranted = false
        audioApp.start()
        try await waitCondition { audioApp.canStop }
        try check(audioApp.error.isEmpty, "system_mix with mic granted must not hard-block on CGPreflightScreenCaptureAccess(): \(audioApp.error)")
        audioApp.stop()

        print("PASS: configuration, credential namespace, independent startup, model bypass, mode locks and restoration")
        print("PASS: WebSocket handshake, PCM ordering, association, duplicate events, Unicode, tail drain, empty session, cancellation, repeated sessions, errors and timeouts")
        print("PASS: audio source persistence, idle-only switching lock, echo hint and system/mix permission gates")

        try await runSeedLiveInterpretTests(qwenBase: base, audioURL: audioURL)
    }

    @MainActor static func runSeedLiveInterpretTests(qwenBase: String, audioURL: URL) async throws {
        // 1. Protobuf wire codec unit tests (varint, nested messages, unknown fields, subtitle merger).
        var writer = VolcAstProtoWriter()
        var metaWriter = VolcAstProtoWriter()
        metaWriter.writeString(field: 1, value: "sid-1")
        metaWriter.writeInt32(field: 2, value: 42)
        metaWriter.writeInt32(field: 3, value: VolcAstTranslateResponse.statusSuccess)
        metaWriter.writeString(field: 4, value: "ok")
        // Unknown billing submessage (field 5, wire 2) should be skipped cleanly.
        metaWriter.writeBytes(field: 5, value: Data([0x0A, 0x03, 0x61, 0x62, 0x63]))
        writer.writeMessage(field: 1, encoded: metaWriter.data)
        writer.writeInt32(field: 2, value: VolcAstEventType.translationSubtitleEnd.rawValue)
        writer.writeBytes(field: 3, value: Data([0x00, 0x40]))
        writer.writeString(field: 4, value: "你好，世界🌏。")
        writer.writeInt32(field: 5, value: 1200)
        writer.writeInt32(field: 6, value: 2400)
        writer.writeBool(field: 7, value: true)
        writer.writeInt32(field: 8, value: 300)
        // Unknown fixed32 (field 99, wire 5) should be skipped cleanly.
        writer.writeTag(field: 99, wireType: 5)
        var rawWithUnknown = writer.data
        rawWithUnknown.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // 4 bytes for fixed32 field 99
        let decoded = try VolcAstTranslateResponse.decode(rawWithUnknown)
        try check(decoded.responseMeta?.sessionID == "sid-1" && decoded.responseMeta?.sequence == 42, "decode ResponseMeta")
        try check(!decoded.hasErrorStatus && decoded.event == .translationSubtitleEnd, "decode event and success status")
        try check(decoded.data == Data([0x00, 0x40]) && decoded.text == "你好，世界🌏。", "decode payload and UTF-8 text")
        try check(decoded.startTime == 1200 && decoded.endTime == 2400 && decoded.spkChg && decoded.mutedDurationMS == 300, "decode timestamps and flags")
        try check(VolcAstSubtitleMerger.append(existing: "yes ", incoming: "yes") == "yes yes", "repeated words with space preserved")
        try check(VolcAstSubtitleMerger.append(existing: "yes", incoming: "yes") == "yesyes", "identical tokens never swallowed")
        try check(VolcAstSubtitleMerger.append(existing: "to ", incoming: "today") == "to today", "short prefix word preserved")
        try check(VolcAstSubtitleMerger.append(existing: "to", incoming: "day") == "today", "subword delta concatenated cleanly")
        try check(VolcAstSubtitleMerger.append(existing: "a ", incoming: "and") == "a and", "short article prefix preserved")
        try check(VolcAstSubtitleMerger.append(existing: "你好", incoming: "，世界") == "你好，世界", "Chinese incremental delta preserved")

        // 2. Profile protocol switching, validation, URL formatting and backward-compatible JSON.
        var switched = LiveServiceProfile().switchingProtocol(to: LiveServiceProfile.volcAstProtocolID)
        try check(switched.isVolcAst && switched.version == "2.0", "switched to volc-ast 2.0")
        try check(switched.endpoint == LiveServiceProfile.volcAstDefaultEndpoint, "default volc-ast endpoint")
        try check(switched.modelID == LiveServiceProfile.volcAstDefaultResourceID, "default volc-ast resource ID")
        try check(switched.resolvedSourceLanguage(targetLanguage: "zh") == "en", "auto source for zh -> en")
        try check(switched.resolvedSourceLanguage(targetLanguage: "en") == "zh", "auto source for en -> zh")
        switched.sourceLanguage = "zhen"
        try check(switched.resolvedSourceLanguage(targetLanguage: "zh") == "zhen", "explicit zhen preserved")
        var volcCfg = LiveTranslateConfiguration(enabled: true, language: "zh")
        volcCfg.catalog.use(switched)
        let volcURL = try volcCfg.url()
        try check(volcURL.absoluteString == LiveServiceProfile.volcAstDefaultEndpoint && volcURL.query == nil, "volc-ast URL omits model query")
        let encodedProfile = try JSONEncoder().encode(switched)
        let decodedProfile = try JSONDecoder().decode(LiveServiceProfile.self, from: encodedProfile)
        try check(decodedProfile == switched, "volc-ast profile JSON round-trip")
        // Minimal profile JSON omitting optional Qwen VAD/audio fields still decodes cleanly.
        let minimalProfile = Data(#"{"id":"v-min","name":"Seed","endpoint":"wss://openspeech.bytedance.com/api/v4/ast/v2/translate","modelID":"volc.service_type.10053","protocolID":"volc-ast","version":"2.0"}"#.utf8)
        let decodedMinimal = try JSONDecoder().decode(LiveServiceProfile.self, from: minimalProfile)
        try check(decodedMinimal.isVolcAst && decodedMinimal.inputFormat == "pcm" && decodedMinimal.turnDetection == "server_vad", "minimal profile JSON decodes with defaults")
        var badAppKey = switched; badAppKey.appKey = "bad key\n"
        try check((try? badAppKey.validate()) == nil, "invalid App Key rejected")
        var badSource = switched; badSource.sourceLanguage = "xx"
        try check((try? badSource.validate()) == nil, "unsupported source language rejected")

        guard let volcBase = ProcessInfo.processInfo.environment["RECORDER_VOLC_AST_MOCK"] else {
            throw LiveTestError(message: "Use scripts/test_livetranslate.sh (RECORDER_VOLC_AST_MOCK missing)")
        }

        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<600 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw LiveTestError(message: "Timed out waiting for volc-ast fixture")
        }

        // 3. Silent connection test (single X-Api-Key and legacy dual X-Api-App-Key + X-Api-Access-Key).
        for (path, appKey, secret) in [("/ok", "", "mock-volc-key"), ("/dual-auth", "app-12345", "mock-volc-access")] {
            var cfg = LiveTranslateConfiguration(enabled: true, language: "zh")
            cfg.catalog.use(.seedLiveInterpret(id: "v-test", endpoint: volcBase + path, appKey: appKey))
            let session = SeedLiveInterpretSession(client: SeedLiveInterpretClient(allowLocalhost: true))
            var ready = false, ended = false
            var endError: String?
            var events: [LiveTranslationSessionEvent] = []
            session.onReady = { ready = true; session.finish() }
            session.onEvent = { events.append($0) }
            session.onEnd = { endError = $0; ended = true }
            try session.start(configuration: cfg, key: secret, sessionID: "s-silent")
            try await waitFor { ended }
            try check(ready && endError == nil && events.isEmpty, "silent connection test succeeded without audio: \(path)")
        }

        // 4. S2T and S2S (streaming + afterFinal playback + replay clip + explicit source_language).
        for (audioOutput, timing, path, srcLang) in [
            (false, LiveTranslatePlaybackTiming.streaming, "/source-check/zhen", "zhen"),
            (true, LiveTranslatePlaybackTiming.streaming, "/ok", ""),
            (true, LiveTranslatePlaybackTiming.afterFinal, "/ok", "en"),
        ] {
            var cfg = LiveTranslateConfiguration(enabled: true, language: "zh", audioOutput: audioOutput, playbackTiming: timing)
            cfg.catalog.use(.seedLiveInterpret(id: "v-run", endpoint: volcBase + path, sourceLanguage: srcLang))
            let session = SeedLiveInterpretSession(client: SeedLiveInterpretClient(allowLocalhost: true))
            var ready = false, ended = false
            var endError: String?
            var updates: [LiveTranslationUpdate] = []
            var audioBytes = 0
            var replayBytes = 0
            session.onReady = { ready = true }
            session.onEvent = { ev in
                switch ev {
                case .update(let u): updates.append(u)
                case .audio(let pcm): audioBytes += pcm.count
                case .replayClip(_, let pcm): replayBytes += pcm.count
                default: break
                }
            }
            session.onEnd = { endError = $0; ended = true }
            try session.start(configuration: cfg, key: "mock-volc-key", sessionID: "s-run")
            try await waitFor { ready || ended }
            try check(ready, "volc-ast session started: \(path)")
            try check(session.append(Data(repeating: 1, count: 640)), "audio chunk accepted")
            try await waitFor { updates.contains { $0.source == "Hello world" && $0.translation == "你好，世界" } }
            if audioOutput && timing == .afterFinal {
                try check(audioBytes == 0, "afterFinal waits until subtitles finalize before releasing audio")
            }
            session.finish()
            try await waitFor { ended }
            try check(endError == nil, "clean session end: \(endError ?? "")")
            let last = updates.last!
            try check(last.source == "Hello world." && last.sourceDone, "final source text")
            try check(last.translation == "你好，世界🌏。" && last.translationDone, "final translation text")
            try check(last.startSample == 1200 * 16, "start_time mapped to samples")
            try check(audioBytes == (audioOutput ? 4800 : 0), "24kHz PCM audio reassembled across odd byte split")
            try check(replayBytes == (audioOutput ? 4800 : 0), "replay clip cached on completion")
        }

        // 5b. Repeated words, short prefixes, and authoritative End replacement over wire.
        do {
            var cfg = LiveTranslateConfiguration(enabled: true, language: "zh")
            cfg.catalog.use(.seedLiveInterpret(id: "v-rep", endpoint: volcBase + "/repeat-words"))
            let session = SeedLiveInterpretSession(client: SeedLiveInterpretClient(allowLocalhost: true))
            var ready = false, ended = false
            var updates: [LiveTranslationUpdate] = []
            session.onReady = { ready = true }
            session.onEvent = { if case .update(let u) = $0 { updates.append(u) } }
            session.onEnd = { _ in ended = true }
            try session.start(configuration: cfg, key: "mock-volc-key", sessionID: "s-rep")
            try await waitFor { ready || ended }
            _ = session.append(Data(repeating: 1, count: 640))
            try await waitFor { updates.contains { $0.source == "yes yes to today" && $0.translation == "你好世" } }
            session.finish()
            try await waitFor { ended }
            let last = updates.last!
            try check(last.source == "yes yes to today" && last.sourceDone, "empty End preserves accumulated repeated/prefix words")
            try check(last.translation == "你好，世界！" && last.translationDone, "non-empty End replaces provisional Chinese text cleanly")
        }

        // 5. Defensive OggS audio warning keeps subtitles running.
        do {
            var cfg = LiveTranslateConfiguration(enabled: true, language: "zh", audioOutput: true, playbackTiming: .streaming)
            cfg.catalog.use(.seedLiveInterpret(id: "v-ogg", endpoint: volcBase + "/ogg-audio"))
            let session = SeedLiveInterpretSession(client: SeedLiveInterpretClient(allowLocalhost: true))
            var ready = false, ended = false
            var warning: String?
            var finalText = ""
            session.onReady = { ready = true }
            session.onEvent = { ev in
                if case .playbackWarning(let msg) = ev { warning = msg }
                if case .update(let u) = ev, u.translationDone { finalText = u.translation }
            }
            session.onEnd = { _ in ended = true }
            try session.start(configuration: cfg, key: "mock-volc-key", sessionID: "s-ogg")
            try await waitFor { ready || ended }
            _ = session.append(Data(repeating: 1, count: 640))
            try await waitFor { warning != nil }
            session.finish()
            try await waitFor { ended }
            try check(warning?.contains("译音格式") == true && finalText == "你好，世界🌏。", "OggS triggers playback warning while subtitles finish")
        }

        // 6. Failure paths & credential non-leakage.
        for route in ["/unauthorized", "/redirect", "/http-429", "/session-failed-auth", "/session-failed-quota", "/rate-limited", "/wrong-order", "/invalid-proto", "/disconnect", "/finished-early", "/timeout"] {
            var cfg = LiveTranslateConfiguration(enabled: true, language: "zh")
            cfg.catalog.use(.seedLiveInterpret(id: "v-err", endpoint: volcBase + route))
            let client = SeedLiveInterpretClient(finishTimeout: 0.15, allowLocalhost: true)
            let session = SeedLiveInterpretSession(client: client)
            var ready = false, ended = false
            var endError: String?
            session.onReady = { ready = true }
            session.onEnd = { endError = $0; ended = true }
            try session.start(configuration: cfg, key: "mock-volc-key", sessionID: "s-err")
            try await waitFor { ready || ended }
            if ready {
                if route == "/disconnect" || route == "/finished-early" { _ = session.append(Data([0, 0])) }
                else { session.finish() }
            }
            try await waitFor { ended }
            try check(endError != nil, "volc-ast failure surfaced: \(route)")
            try check(!endError!.contains("mock-volc-key"), "volc-ast error never leaks key: \(route)")
            if route == "/rate-limited" || route == "/http-429" {
                try check(session.endKind == .rateLimited, "rate limit classified: \(route)")
            }
        }

        // 7. AppModel end-to-end with Seed-LiveInterpret 2.0 + switching Qwen <-> Seed-LiveInterpret 2.0 + session persistence.
        let volcSuite = "recorder.volc.tests.\(UUID().uuidString)"
        let volcDefaults = UserDefaults(suiteName: volcSuite)!
        defer { volcDefaults.removePersistentDomain(forName: volcSuite) }
        let qwenProfile = LiveServiceProfile(id: "qwen-1", name: "Qwen", endpoint: qwenBase + "/ok")
        let volcProfile = LiveServiceProfile.seedLiveInterpret(id: "volc-1", name: "Seed 2.0", endpoint: volcBase + "/ok", sourceLanguage: "en")
        try APIKeyStore.save("mock-only", endpoint: "livetranslate:" + qwenProfile.endpoint)
        try APIKeyStore.save("mock-volc-key", endpoint: "livetranslate:" + volcProfile.endpoint)
        var initial = LiveTranslateConfiguration(enabled: true, language: "zh")
        initial.catalog.use(qwenProfile)
        initial.catalog.use(volcProfile)
        try initial.save(defaults: volcDefaults, allowLocalhost: true)
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("volc-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        let store = SessionStore(directory: sessionDir)
        let app = AppModel(
            defaults: volcDefaults,
            integrateSystem: false,
            liveAllowLocalhost: true,
            liveClientFactory: { LiveTranslateClient(allowLocalhost: true) },
            liveKeyReader: { try APIKeyStore.read(endpoint: $0) },
            sessionStore: store
        )
        defer { app.shutdown() }
        app.audioSource = "file"; app.audioFileURL = audioURL
        // Silent connection test on Seed 2.0
        app.testLiveConnection()
        try await waitFor { !app.liveTesting }
        try check(app.liveMessage.contains("连接成功") && app.finalText.isEmpty, "AppModel testLiveConnection on volc-ast")
        // Record on Seed 2.0
        app.start()
        try await waitFor { app.finalText.count == 1 && app.state == "ready" }
        try check(app.finalText[0].text == "Hello world." && app.finalText[0].translation == "你好，世界🌏。", "AppModel Seed 2.0 recording")
        // Switch back to Qwen and record in the same session
        app.selectLiveProfile(qwenProfile.id)
        app.start()
        try await waitFor { app.finalText.count == 2 && app.state == "ready" }
        try check(store.list().singleOrNil?.rows.count == 2, "both volc-ast and Qwen recordings persisted cleanly")
        // Verify switching protocolID on liveProfile synchronously clears draft liveKeyInput.
        app.liveKeyInput = "draft-secret"
        app.liveProfile = app.liveProfile.switchingProtocol(to: LiveServiceProfile.volcAstProtocolID)
        try check(app.liveKeyInput.isEmpty, "switching protocol clears draft liveKeyInput")
        print("PASS: Seed-LiveInterpret 2.0 Protobuf codec, auth modes, S2T/S2S, OggS guard, errors, and AppModel Qwen<->Seed switching")
    }
}

private extension Array {
    var singleOrNil: Element? { count == 1 ? first : nil }
}
