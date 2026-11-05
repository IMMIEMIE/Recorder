import AVFoundation
import Foundation

/// Injectable speech device. Public methods and completions use the main thread.
protocol LocalSpeechQueue: AnyObject {
    func enqueue(text: String, language: String, volume: Double, rate: Float, completion: @escaping () -> Void) throws
    func stop()
}

/// Main-thread timer abstraction allows elapsed-time limits to be tested without sleeping.
protocol LocalSpeechScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void)
    func cancel()
}

private final class LocalSpeechTimer: LocalSpeechScheduling {
    private var work: DispatchWorkItem?
    func schedule(after seconds: TimeInterval, _ callback: @escaping () -> Void) {
        cancel()
        let work = DispatchWorkItem(block: callback)
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func cancel() { work?.cancel(); work = nil }
    deinit { cancel() }
}

protocol LocalSpeechOutputting: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var onPlayingChange: ((Bool) -> Void)? { get set }
    var isPlaying: Bool { get }
    func start(session: String, language: String, volume: Double, timing: LiveTranslatePlaybackTiming, enabled: Bool)
    func consume(session: String, itemID: String, text: String, committed: Bool, final: Bool)
    func finish(completion: @escaping () -> Void)
    func stop()
    func replay(text: String, language: String, volume: Double, completion: @escaping () -> Void)
}

/// System voices read committed translation only. Provisional revisions never enter the device.
/// Committed model turns are assembled into phrases; a turn final is not a sentence boundary.
final class LocalSpeechOutput: LocalSpeechOutputting {
    var onFailure: ((String) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { onPlayingChange?(isPlaying) } }
    }
    private struct Item {
        var submitted = ""
        var complete = false
        var suppressed = false
    }
    private let queue: any LocalSpeechQueue
    private let now: () -> TimeInterval
    private let timer: any LocalSpeechScheduling
    private var generation = UUID()
    private var session = ""
    private var language = "en"
    private var volume = 0.8
    private var timing: LiveTranslatePlaybackTiming = .streaming
    private var enabled = false
    private var inputFinished = false
    private var phraseBuffer = ""
    private var lastPhraseItem: String?
    private var items: [String: Item] = [:]
    private var completedIDs: Set<String> = []
    private var itemOrder: [String] = []
    private var pendingCharacters = 0
    private var pending: [(id: UUID, enqueuedAt: TimeInterval)] = []
    private var drained: (() -> Void)?
    private static let maximumQueuedCharacters = 8_000
    private static let maximumPendingAge: TimeInterval = 30
    private static let maximumRememberedItems = 512

    init(queue: (any LocalSpeechQueue)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         timer: (any LocalSpeechScheduling)? = nil) {
        assert(Thread.isMainThread)
        self.queue = queue ?? SystemSpeechQueue()
        self.now = now; self.timer = timer ?? LocalSpeechTimer()
    }

    func start(session: String, language: String, volume: Double,
               timing: LiveTranslatePlaybackTiming, enabled: Bool) {
        assert(Thread.isMainThread)
        stop()
        self.session = session; self.language = language
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0.8
        self.timing = timing; self.enabled = enabled
    }

    func consume(session: String, itemID: String, text: String, committed: Bool, final: Bool) {
        assert(Thread.isMainThread)
        guard enabled, !inputFinished, session == self.session, committed, !itemID.isEmpty,
              !completedIDs.contains(itemID) else { return }
        guard checkQueueAge() else { return }
        if timing == .afterFinal && !final { return }
        var item = items[itemID] ?? Item()
        guard !item.complete, !item.suppressed else { return }
        if items[itemID] == nil { itemOrder.append(itemID) }
        // A committed prefix should never be revised. If a producer does revise it, avoid reading
        // corrected text twice; subtitle handling remains independent and authoritative.
        guard text.hasPrefix(item.submitted) else {
            item.suppressed = true; items[itemID] = item
            return
        }
        let remaining = String(text.dropFirst(item.submitted.count))
        if !remaining.isEmpty {
            item.submitted = text
            items[itemID] = item
            appendCommitted(remaining, itemID: itemID)
            guard enabled else { return }
        }
        item.complete = final
        if final { completedIDs.insert(itemID) }
        items[itemID] = item
        // Retain completed IDs for duplicate suppression, but release their translated text.
        while itemOrder.count > Self.maximumRememberedItems, let first = itemOrder.first,
              items[first]?.complete == true {
            itemOrder.removeFirst(); items.removeValue(forKey: first)
        }
    }

    private func appendCommitted(_ text: String, itemID: String) {
        var separator = ""
        if lastPhraseItem != itemID, let left = phraseBuffer.last, let right = text.first,
           left.isASCII, right.isASCII, (left.isLetter || left.isNumber || ",;:".contains(left)),
           (right.isLetter || right.isNumber) {
            separator = " "
        }
        guard pendingCharacters + phraseBuffer.count + separator.count + text.count <= Self.maximumQueuedCharacters else {
            fail("本地译音播放跟不上翻译，已停止本次译音；字幕继续更新")
            return
        }
        phraseBuffer += separator + text; lastPhraseItem = itemID
        while enabled {
            let amount = Self.phraseLength(in: phraseBuffer, clauses: timing == .streaming)
            guard amount > 0 else { return }
            let phrase = String(phraseBuffer.prefix(amount))
            phraseBuffer.removeFirst(amount)
            speak(phrase)
        }
    }

    /// Streaming reads clauses; after-final reads sentences. Never split decimal numbers or
    /// thousands separators. A model segment ending alone does not flush an unfinished phrase.
    private static func phraseLength(in text: String, clauses: Bool) -> Int {
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let decimal = index > 0 && index + 1 < characters.count &&
                characters[index - 1].isNumber && characters[index + 1].isNumber
            let sentence = "。！？!?\n".contains(character) ||
                (character == "." && !decimal && (index + 1 == characters.count || characters[index + 1].isWhitespace))
            let clause = clauses && ("，；;".contains(character) || (character == "," && !decimal))
            if sentence || clause { return index + 1 }
        }
        return 0
    }

    /// At the default rate a system voice reads continuous translation at about real time (60 s of
    /// speech: 58 s English, 59–71 s Chinese), so any backlog would only grow towards the age limit.
    private var rate: Float {
        let backlog = Double(pendingCharacters) / (language.hasPrefix("zh") ? 5 : 15)
        return backlog > 8 ? 0.6 : backlog > 3 ? 0.55 : AVSpeechUtteranceDefaultSpeechRate
    }

    private func speak(_ raw: String) {
        guard checkQueueAge() else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard pendingCharacters + text.count <= Self.maximumQueuedCharacters else {
            fail("本地译音播放跟不上翻译，已停止本次译音；字幕继续更新")
            return
        }
        let id = generation, utteranceID = UUID(), rate = rate
        pendingCharacters += text.count; pending.append((utteranceID, now())); isPlaying = true
        do {
            try queue.enqueue(text: text, language: language, volume: volume, rate: rate) { [weak self] in
                guard let self, self.generation == id,
                      let index = self.pending.firstIndex(where: { $0.id == utteranceID }) else { return }
                self.pendingCharacters -= text.count; self.pending.remove(at: index)
                self.isPlaying = !self.pending.isEmpty
                self.armQueueTimer()
                if !self.isPlaying { let done = self.drained; self.drained = nil; done?() }
            }
            armQueueTimer()
        } catch { fail("本地译音不可用：\(error.localizedDescription)。字幕继续更新") }
    }

    /// Bound the actual age of the oldest unfinished utterance, even if no new text arrives.
    /// Completion advances the deadline to the next utterance's original enqueue time.
    private func checkQueueAge() -> Bool {
        guard let oldest = pending.first else { return true }
        guard now() - oldest.enqueuedAt < Self.maximumPendingAge else {
            fail("本地译音等待超过 30 秒，已停止本次译音；字幕继续更新")
            return false
        }
        return true
    }

    private func armQueueTimer() {
        timer.cancel()
        guard let oldest = pending.first else { return }
        let id = generation
        let remaining = max(0, Self.maximumPendingAge - (now() - oldest.enqueuedAt))
        timer.schedule(after: remaining) { [weak self] in
            guard let self, self.generation == id else { return }
            if self.checkQueueAge() { self.armQueueTimer() }
        }
    }

    func finish(completion: @escaping () -> Void) {
        assert(Thread.isMainThread)
        guard checkQueueAge() else { completion(); return }
        if !inputFinished {
            inputFinished = true
            let tail = phraseBuffer; phraseBuffer = ""
            if enabled { speak(tail) }
        }
        if pending.isEmpty { completion() } else { drained = completion }
    }

    func stop() {
        assert(Thread.isMainThread)
        generation = UUID(); enabled = false; session = ""
        inputFinished = false; phraseBuffer = ""; lastPhraseItem = nil
        timer.cancel(); queue.stop(); pendingCharacters = 0; pending.removeAll(); isPlaying = false
        items.removeAll(); itemOrder.removeAll(); completedIDs.removeAll()
        let done = drained; drained = nil; done?()
    }

    func replay(text: String, language: String, volume: Double, completion: @escaping () -> Void) {
        start(session: UUID().uuidString, language: language, volume: volume, timing: .afterFinal, enabled: true)
        speak(text)
        finish(completion: completion)
    }

    private func fail(_ message: String) { stop(); onFailure?(message) }
}

enum LocalSpeechVoiceSelection {
    static func languageCode(_ language: String) -> String {
        ["zh": "zh-CN", "en": "en-US", "简体中文": "zh-CN", "繁體中文": "zh-TW", "English": "en-US",
         "日本語": "ja-JP", "한국어": "ko-KR", "Français": "fr-FR", "Deutsch": "de-DE",
         "Español": "es-ES", "Русский": "ru-RU"][language] ?? language
    }

    static func identifier(code: String, preferred: String?, available: [(id: String, language: String)]) -> String? {
        if let preferred, available.contains(where: { $0.id == preferred }) { return preferred }
        return available.first(where: { $0.language == code })?.id ??
            available.first(where: { $0.language.split(separator: "-").first == code.split(separator: "-").first })?.id
    }
}

private struct LocalSpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// All mutable state is main-thread confined; delegate callbacks explicitly hop to MainActor.
private final class SystemSpeechQueue: NSObject, LocalSpeechQueue, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    override init() { super.init(); synthesizer.delegate = self }

    func enqueue(text: String, language: String, volume: Double, rate: Float, completion: @escaping () -> Void) throws {
        let code = LocalSpeechVoiceSelection.languageCode(language)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let identifier = LocalSpeechVoiceSelection.identifier(code: code,
            preferred: AVSpeechSynthesisVoice(language: code)?.identifier,
            available: voices.map { (id: $0.identifier, language: $0.language) })
        guard let identifier, let voice = voices.first(where: { $0.identifier == identifier }) else {
            throw LocalSpeechError(message: "系统未安装 \(language) 语音，请在系统设置中添加语音")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.volume = Float(volume); utterance.rate = rate
        completions[ObjectIdentifier(utterance)] = completion
        synthesizer.speak(utterance)
    }
    func stop() { completions.removeAll(); synthesizer.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.completions.removeValue(forKey: id)?() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.completions.removeValue(forKey: id)?() }
    }
}
