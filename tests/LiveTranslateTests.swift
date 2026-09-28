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
    init(timeout: TimeInterval = 30) {
        client = LiveTranslateClient(finishTimeout: timeout)
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
        let model = AppModel(defaults: defaults, integrateSystem: false)
        defer { model.shutdown() }
        try check(model.liveEnabled && model.canStart, "Live mode starts without bundled Python or local models")
        model.load(); model.loadTranslator()
        try check(model.state == "ready", "local model load routes disabled")
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
        let mockConfig = LiveTranslateConfiguration(enabled: true, endpoint: base + "/ok")
        defaults.set(try JSONEncoder().encode(mockConfig), forKey: "livetranslate.configuration.v1")
        var clients: [LiveTranslateClient] = []
        let app = AppModel(defaults: defaults, integrateSystem: false, liveClientFactory: {
            let client = LiveTranslateClient(allowLocalhost: true); clients.append(client); return client
        }, liveKeyReader: { account in
            try check(account == mockConfig.keyAccount, "app requests only dedicated credential")
            return "mock-only"
        })
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
        app.clear()
        try check(app.finalText.isEmpty && app.exportText.isEmpty, "clear removes both languages")

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
        for route in ["/unauthorized", "/redirect", "/error", "/wrong-mode", "/disconnect", "/timeout"] {
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
        let cancel = Probe()
        try cancel.connect(base + "/ok")
        try await cancel.wait { cancel.ready }
        try check(!cancel.client.append(Data(repeating: 0, count: 320_001)), "bounded audio queue")
        cancel.client.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let callbacks = cancel.callbacks
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(cancel.callbacks == callbacks && !cancel.ended, "cancel suppresses subsequent transport callbacks")
        print("PASS: configuration, credential namespace, independent startup, model bypass, mode locks and restoration")
        print("PASS: WebSocket handshake, PCM ordering, association, duplicate events, Unicode, tail drain, empty session, cancellation, repeated sessions, errors and timeouts")
    }
}
