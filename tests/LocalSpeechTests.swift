import Foundation

struct LocalFeatureTestFailure: Error { let message: String }
func assertLocal(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw LocalFeatureTestFailure(message: message) }
}

final class FakeSpeechQueue: LocalSpeechQueue {
    struct Entry {
        let text: String; let language: String; let volume: Double; let rate: Float; let completion: () -> Void
    }
    var entries: [Entry] = []
    var stops = 0
    var fail = false
    func enqueue(text: String, language: String, volume: Double, rate: Float, completion: @escaping () -> Void) throws {
        if fail { throw LocalFeatureTestFailure(message: "unavailable voice") }
        entries.append(Entry(text: text, language: language, volume: volume, rate: rate, completion: completion))
    }
    func stop() { stops += 1 }
}

final class FakeSpeechTimer: LocalSpeechScheduling {
    private(set) var delay: TimeInterval?
    private(set) var callback: (() -> Void)?
    func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void) {
        delay = seconds; self.callback = callback
    }
    func cancel() { delay = nil; callback = nil }
    func fire() { let action = callback; callback = nil; delay = nil; action?() }
}

actor FakeHyStorage: HyModelStoring {
    var path: URL?
    var continuation: CheckedContinuation<URL, Never>?
    var downloading = false
    init(path: URL? = nil) { self.path = path }
    nonisolated func hasCachedFile(in cache: URL) -> Bool { false }
    func verifiedFile(in cache: URL) async throws -> URL? { path }
    func download(to cache: URL, progress: @escaping @Sendable (String, Int64, Int64) async -> Void) async throws -> URL {
        downloading = true
        await progress("fixture", 50, 100)
        // Deliberately ignore cancellation to verify stale completion isolation in the store.
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ file: URL) { continuation?.resume(returning: file); continuation = nil }
}

@main struct LocalSpeechTests {
    @MainActor static func main() async throws {
        let queue = FakeSpeechQueue()
        let speech = LocalSpeechOutput(queue: queue)
        var playing: [Bool] = []
        speech.onPlayingChange = { playing.append($0) }
        speech.start(session: "one", language: "zh", volume: 0.4, timing: .streaming, enabled: true)
        speech.consume(session: "one", itemID: "a", text: "还会改变。", committed: false, final: false)
        speech.consume(session: "one", itemID: "a", text: "你好", committed: true, final: false)
        try assertLocal(queue.entries.isEmpty, "provisional text and unclosed committed phrase wait")
        speech.consume(session: "one", itemID: "a", text: "你好。", committed: true, final: false)
        speech.consume(session: "one", itemID: "a", text: "你好。下一句", committed: true, final: false)
        speech.consume(session: "one", itemID: "a", text: "你好。下一句。", committed: true, final: true)
        speech.consume(session: "one", itemID: "a", text: "你好。下一句。", committed: true, final: true)
        try assertLocal(queue.entries.map(\.text) == ["你好。", "下一句。"], "cumulative revisions read committed phrases only once")
        try assertLocal(queue.entries.allSatisfy { $0.language == "zh" && $0.volume == 0.4 }, "language and volume applied")
        speech.consume(session: "one", itemID: "b", text: "你好。", committed: true, final: true)
        try assertLocal(queue.entries.count == 3, "real repeated speech in a distinct item is kept")
        var drained = false
        speech.finish { drained = true }
        try assertLocal(!drained, "finish drains queued speech")
        queue.entries.forEach { $0.completion() }
        try assertLocal(drained && !speech.isPlaying && playing == [true, false], "completion updates playing state and drain")

        speech.start(session: "two", language: "en", volume: 1, timing: .afterFinal, enabled: true)
        let before = queue.entries.count
        speech.consume(session: "two", itemID: "a", text: "Wait. A revision.", committed: true, final: false)
        try assertLocal(queue.entries.count == before, "after-final timing waits despite sentence boundaries")
        speech.consume(session: "two", itemID: "a", text: "Final translation.", committed: true, final: true)
        try assertLocal(queue.entries.last?.text == "Final translation.", "after-final timing reads final full text")
        let old = queue.entries.last!.completion
        speech.stop()
        speech.start(session: "three", language: "en", volume: 0.6, timing: .streaming, enabled: true)
        speech.consume(session: "two", itemID: "late", text: "Stale.", committed: true, final: true)
        speech.consume(session: "three", itemID: "c", text: "Current.", committed: true, final: true)
        old()
        try assertLocal(speech.isPlaying && queue.entries.last?.text == "Current.", "stale speech callbacks cannot finish new playback")
        speech.stop()
        speech.consume(session: "three", itemID: "after-stop", text: "No sound.", committed: true, final: true)
        try assertLocal(queue.entries.last?.text == "Current.", "stop suppresses future packets from that session")
        var replayDone = false
        speech.replay(text: "保存的译文", language: "zh", volume: 0.2) { replayDone = true }
        try assertLocal(queue.entries.last?.language == "zh", "replay uses retained target language")
        queue.entries.last?.completion()
        try assertLocal(replayDone, "replay completes")
        queue.fail = true
        var failure: String?
        speech.onFailure = { failure = $0 }
        speech.replay(text: "Read me", language: "en", volume: 1) {}
        try assertLocal(failure?.contains("字幕继续更新") == true && !speech.isPlaying, "voice failure stops sound without affecting captions")
        queue.fail = false
        speech.start(session: "off", language: "en", volume: 1, timing: .streaming, enabled: false)
        let offCount = queue.entries.count
        speech.consume(session: "off", itemID: "a", text: "Silent.", committed: true, final: true)
        try assertLocal(queue.entries.count == offCount, "disabled speech makes no device calls")
        print("PASS: committed speech, timing, revisions, repeated text, stale callbacks, replay, failures and opt-out")

        let paced = FakeSpeechQueue()
        let pacedSpeech = LocalSpeechOutput(queue: paced)
        pacedSpeech.start(session: "pace", language: "zh", volume: 1, timing: .streaming, enabled: true)
        func sentence(_ id: String, _ length: Int) {
            pacedSpeech.consume(session: "pace", itemID: id, text: String(repeating: "译", count: length) + "。", committed: true, final: true)
        }
        sentence("a", 14)
        try assertLocal(paced.entries.last?.rate == 0.5, "an empty queue reads at the normal rate")
        sentence("b", 14)
        try assertLocal(paced.entries.last?.rate == 0.5, "under three seconds of backlog stays at the normal rate")
        sentence("c", 14)
        try assertLocal(paced.entries.last?.rate == 0.55, "a growing backlog speeds up the next phrase")
        for id in ["d", "e", "f"] { sentence(id, 14) }
        try assertLocal(paced.entries.last?.rate == 0.6, "a long backlog speeds up further")
        paced.entries.forEach { $0.completion() }
        sentence("g", 14)
        try assertLocal(paced.entries.last?.rate == 0.5, "the normal rate returns once caught up")
        let pacedEnglish = FakeSpeechQueue()
        let englishSpeech = LocalSpeechOutput(queue: pacedEnglish)
        englishSpeech.start(session: "pace", language: "en", volume: 1, timing: .streaming, enabled: true)
        for id in ["a", "b"] {
            englishSpeech.consume(session: "pace", itemID: id, text: String(repeating: "word ", count: 6) + "end.", committed: true, final: true)
        }
        try assertLocal(pacedEnglish.entries.last?.rate == 0.5, "the same text is less backlog in English, which reads three times the characters per second")
        print("PASS: reading rate follows the backlog and returns to normal")

        let clauses = FakeSpeechQueue(), sentences = FakeSpeechQueue()
        let streamingSpeech = LocalSpeechOutput(queue: clauses), finalSpeech = LocalSpeechOutput(queue: sentences)
        streamingSpeech.start(session: "phrases", language: "en", volume: 1, timing: .streaming, enabled: true)
        finalSpeech.start(session: "phrases", language: "en", volume: 1, timing: .afterFinal, enabled: true)
        func emitTurn(_ id: String, _ text: String) {
            for output in [streamingSpeech, finalSpeech] {
                output.consume(session: "phrases", itemID: id, text: text, committed: true, final: true)
            }
        }
        emitTurn("1", "Hello")
        try assertLocal(clauses.entries.isEmpty && sentences.entries.isEmpty, "final model turn containing one word is buffered in both modes")
        emitTurn("2", "world,")
        try assertLocal(clauses.entries.map(\.text) == ["Hello world,"] && sentences.entries.isEmpty, "streaming reads committed clause while after-final waits for sentence end")
        emitTurn("3", "we")
        emitTurn("4", "are ready.")
        try assertLocal(clauses.entries.map(\.text) == ["Hello world,", "we are ready."], "streaming assembles words from separate committed turns")
        try assertLocal(sentences.entries.map(\.text) == ["Hello world, we are ready."], "after-final reads the whole assembled sentence")
        emitTurn("4", "are ready.")
        emitTurn("5", "Last")
        emitTurn("6", "words")
        try assertLocal(clauses.entries.count == 2 && sentences.entries.count == 1, "duplicate final and unfinished tail do not produce speech")
        var clausesFinished = false, sentencesFinished = false
        streamingSpeech.finish { clausesFinished = true }
        finalSpeech.finish { sentencesFinished = true }
        try assertLocal(clauses.entries.last?.text == "Last words" && sentences.entries.last?.text == "Last words", "session finish flushes assembled tail without punctuation")
        clauses.entries.forEach { $0.completion() }; sentences.entries.forEach { $0.completion() }
        try assertLocal(clausesFinished && sentencesFinished, "finish waits for tail playback completion")
        let finishedCount = sentences.entries.count
        finalSpeech.finish {}
        finalSpeech.consume(session: "phrases", itemID: "late", text: "Late.", committed: true, final: true)
        try assertLocal(sentences.entries.count == finishedCount, "repeated finish and late input cannot replay flushed tail")
        finalSpeech.start(session: "cancel-tail", language: "zh", volume: 1, timing: .afterFinal, enabled: true)
        finalSpeech.consume(session: "cancel-tail", itemID: "a", text: "未读尾句", committed: true, final: true)
        finalSpeech.stop(); finalSpeech.finish {}
        try assertLocal(sentences.entries.count == finishedCount, "stop discards an unspoken buffered tail")
        let numbers = FakeSpeechQueue(), numberSpeech = LocalSpeechOutput(queue: numbers)
        numberSpeech.start(session: "numbers", language: "en", volume: 1, timing: .streaming, enabled: true)
        numberSpeech.consume(session: "numbers", itemID: "a", text: "Value 3.14, total 1,000; done.", committed: true, final: true)
        try assertLocal(numbers.entries.map(\.text) == ["Value 3.14,", "total 1,000;", "done."], "clause boundaries preserve decimals and thousands separators")
        print("PASS: cross-turn clause/sentence aggregation, distinct playback modes, natural word joining and final tail drain")

        let installedVoices = [(id: "cartoon", language: "en-US"), (id: "system-default", language: "en-US"),
                               (id: "chinese", language: "zh-CN")]
        try assertLocal(LocalSpeechVoiceSelection.languageCode("en") == "en-US", "English resolves to a concrete locale")
        try assertLocal(LocalSpeechVoiceSelection.identifier(code: "en-US", preferred: "system-default", available: installedVoices) == "system-default", "installed system default takes priority over first available novelty voice")
        try assertLocal(LocalSpeechVoiceSelection.identifier(code: "en-US", preferred: "not-installed", available: installedVoices) == "cartoon", "uninstalled preferred voice is never selected")
        try assertLocal(LocalSpeechVoiceSelection.identifier(code: "ja-JP", preferred: nil, available: installedVoices) == nil, "no voice for requested language stays unavailable")
        print("PASS: English locale and installed system voice preference")

        let timedQueue = FakeSpeechQueue(), timer = FakeSpeechTimer()
        var instant: TimeInterval = 0
        let timed = LocalSpeechOutput(queue: timedQueue, now: { instant }, timer: timer)
        var timeoutErrors: [String] = []
        timed.onFailure = { timeoutErrors.append($0) }
        timed.start(session: "timed", language: "en", volume: 1, timing: .streaming, enabled: true)
        timed.consume(session: "timed", itemID: "first", text: "First.", committed: true, final: true)
        try assertLocal(timer.delay == 30, "first pending utterance arms a thirty-second timer")
        instant = 10
        timed.consume(session: "timed", itemID: "second", text: "Second.", committed: true, final: true)
        try assertLocal(timer.delay == 20, "new speech cannot postpone oldest pending deadline")
        instant = 29
        timedQueue.entries.first?.completion()
        try assertLocal(timer.delay == 11, "completing first speech retains second speech original enqueue age")
        var timeoutDrained = false
        timed.finish { timeoutDrained = true }
        instant = 40
        timer.fire()
        try assertLocal(timeoutErrors.count == 1 && timeoutErrors[0].contains("30 秒") && !timed.isPlaying && timeoutDrained,
                        "timer stops stale audio and completes drain even with no incoming packets")
        try assertLocal(timer.callback == nil, "timeout cancels timer")
        let countAfterTimeout = timedQueue.entries.count
        timed.consume(session: "timed", itemID: "late", text: "Too late.", committed: true, final: true)
        try assertLocal(timedQueue.entries.count == countAfterTimeout, "timed-out session remains muted")

        timed.start(session: "old-timer", language: "en", volume: 1, timing: .streaming, enabled: true)
        timed.consume(session: "old-timer", itemID: "a", text: "Old.", committed: true, final: true)
        let oldTimer = timer.callback
        timed.stop()
        try assertLocal(timer.callback == nil, "explicit stop cancels scheduled check")
        instant = 100
        timed.start(session: "new-timer", language: "en", volume: 1, timing: .streaming, enabled: true)
        timed.consume(session: "new-timer", itemID: "a", text: "New.", committed: true, final: true)
        oldTimer?()
        try assertLocal(timed.isPlaying && timeoutErrors.count == 1 && timer.delay == 30, "cancelled older-generation timer cannot stop new session")
        instant = 131
        timed.consume(session: "new-timer", itemID: "b", text: "No more backlog.", committed: true, final: true)
        try assertLocal(!timed.isPlaying && timeoutErrors.count == 2 && timedQueue.entries.last?.text == "New.",
                        "incoming text enforces deadline even if main timer delivery was delayed")
        print("PASS: thirty-second backlog timer, original enqueue ages, drain, stop, stale generations and delayed timer delivery")

        let storage = FakeHyStorage()
        let store = HyModelStore(root: URL(fileURLWithPath: "/tmp/unused-test-cache"), storage: storage)
        await store.refresh()
        try assertLocal(store.state == "missing" && store.modelPath == nil, "missing local cache is never downloaded automatically")
        store.download()
        for _ in 0..<100 {
            if await storage.downloading, store.progress > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try assertLocal(store.state == "downloading" && store.progress == 0.5, "main-thread observable download progress")
        store.cancel()
        await storage.complete(URL(fileURLWithPath: "/tmp/stale.gguf"))
        await Task.yield()
        try assertLocal(store.state == "missing" && store.modelPath == nil, "cancelled download cannot mark stale model ready")
        let ready = HyModelStore(storage: FakeHyStorage(path: URL(fileURLWithPath: "/tmp/snapshot/model.gguf")))
        await ready.refresh()
        try assertLocal(ready.state == "ready" && ready.modelPath == "/tmp/snapshot/model.gguf" && ready.modelDirectory == "/tmp/snapshot", "verified cache exposes file and snapshot directory")
        print("PASS: model store offline readiness, progress and cancellation isolation")
    }
}
