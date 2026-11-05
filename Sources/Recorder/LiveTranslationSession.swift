import Foundation

/// Provider-neutral cumulative text. Revisions belong to one segment within one session.
struct LiveTranslationUpdate: Equatable {
    var segmentID: String
    var startSample: Int
    var endSample: Int
    var source: String?
    var translation: String
    var revision: Int
    var sourceDone: Bool
    var translationDone: Bool
    var committed: Bool
    var incomplete = false
}

enum LiveTranslationSessionEvent {
    case update(LiveTranslationUpdate)
    case audio(Data)
    case audioPending
    case replayClip(segmentID: String, pcm: Data)
    case playbackWarning(String)
    case untranslatedAudio(startSample: Int, endSample: Int)
}

/// Control and callbacks are main-thread-owned; audio append is safe on the capture queue.
protocol LiveTranslationSession: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onEvent: ((LiveTranslationSessionEvent) -> Void)? { get set }
    var onEnd: ((String?) -> Void)? { get set }
    func start(configuration: LiveTranslateConfiguration, key: String, sessionID: String) throws
    func append(_ pcm: Data) -> Bool
    func finish()
    func cancel()
    func stopAutomaticPlayback()
}

extension LiveTranslationSession { func stopAutomaticPlayback() {} }

/// Keeps the cloud wire protocol and its source/output association rules out of AppModel.
final class QwenLiveTranslationSession: LiveTranslationSession {
    var onReady: (() -> Void)?
    var onEvent: ((LiveTranslationSessionEvent) -> Void)?
    var onEnd: ((String?) -> Void)?
    private let client: LiveTranslateClient
    private var events = LiveTranslateEvents()
    private var playback = LiveTranslatePlaybackQueue(timing: .streaming)
    private var replay = LiveTranslateReplayCache()
    private var replayed = Set<String>()
    private var revision = 0
    private var previousUpdates: [String: LiveTranslationUpdate] = [:]
    private var audioEnabled = false
    private var playbackFailed = false
    private var active = false
    private var sessionID = ""

    init(client: LiveTranslateClient = LiveTranslateClient()) { self.client = client }

    func start(configuration: LiveTranslateConfiguration, key: String, sessionID: String) throws {
        self.sessionID = sessionID; active = true; audioEnabled = configuration.audioOutput
        events = LiveTranslateEvents(); replay = LiveTranslateReplayCache(); replayed.removeAll()
        playback = LiveTranslatePlaybackQueue(timing: configuration.playbackTiming)
        playbackFailed = false; revision = 0; previousUpdates.removeAll()
        client.onReady = { [weak self] in guard let self, self.active else { return }; self.onReady?() }
        client.onEvent = { [weak self] event in self?.consume(event) }
        client.onEnd = { [weak self] message in
            guard let self, self.active else { return }
            self.publishRows()
            for (id, part) in self.events.unmatchedOutputs {
                self.revision += 1
                self.onEvent?(.update(.init(segmentID: "unmatched:" + id, startSample: 0, endSample: 0,
                    source: nil, translation: part.text, revision: self.revision, sourceDone: true,
                    translationDone: true, committed: false, incomplete: true)))
            }
            var error = message
            if error == nil, self.playback.hasIncompleteSample { error = "末段译音数据不完整，已有字幕已保留" }
            if error == nil, self.playback.hasPendingAudio { error = "部分译音未收到完整定稿，已跳过播放；已有字幕已保留" }
            if error == nil, self.events.hasUnmatchedOutput { error = "部分译文未收到对应句子信息，请重新连接服务" }
            self.active = false; self.onEnd?(error)
        }
        do { try client.connect(configuration: configuration, key: key) }
        catch { active = false; throw error }
    }

    private func consume(_ event: [String: Any]) {
        guard active else { return }
        events.apply(event)
        publishRows()
        guard audioEnabled else { return }
        replay.consume(event, transcripts: events, session: sessionID)
        for id in events.order where !replayed.contains(id) {
            if let pcm = replay.audio(for: "\(sessionID):live:\(id)") {
                replayed.insert(id); onEvent?(.replayClip(segmentID: id, pcm: pcm))
            }
        }
        guard !playbackFailed else { return }
        do {
            for pcm in try playback.consume(event, transcripts: events) { onEvent?(.audio(pcm)) }
            if playback.hasPendingAudio { onEvent?(.audioPending) }
        }
        catch { playbackFailed = true; onEvent?(.playbackWarning(error.localizedDescription)) }
    }

    private func publishRows() {
        for id in events.order {
            guard let row = events.rows[id] else { continue }
            let translated = events.translation(for: row)
            guard !row.source.text.isEmpty || !translated.text.isEmpty else { continue }
            var update = LiveTranslationUpdate(segmentID: id, startSample: Int(row.seconds * 16000), endSample: 0,
                source: row.source.text, translation: translated.text, revision: 0,
                sourceDone: row.source.done, translationDone: translated.done, committed: translated.done)
            guard previousUpdates[id] != update else { continue }
            previousUpdates[id] = update; revision += 1; update.revision = revision
            onEvent?(.update(update))
        }
    }

    func append(_ pcm: Data) -> Bool { client.append(pcm) }
    func finish() { client.finish() }
    func cancel() { active = false; client.cancel() }
    func stopAutomaticPlayback() {
        playbackFailed = true
        playback = LiveTranslatePlaybackQueue(timing: .streaming)
    }
}

/// Hy commits a few words per model turn, every couple of seconds. The transcript and the
/// subtitles read those as sentences: later turns join the row until its translation ends one.
struct LiveSentenceRows {
    struct Placement: Equatable {
        var row: String
        var source: String
        var translation: String
        var startSample: Int
        var endSample: Int
    }
    private struct OpenRow { var row: String; var source: String; var translation: String; var startSample: Int; var endSample: Int }
    private var rows: [String: String] = [:]
    private var starts: [String: Int] = [:]
    private var open: OpenRow?
    private static let maximumRowCharacters = 400
    private static let maximumGapSamples = 3 * 16000

    mutating func place(_ update: LiveTranslationUpdate) -> Placement {
        if rows[update.segmentID] == nil {
            if let current = open, update.startSample - current.endSample > Self.maximumGapSamples { open = nil }
            let row = open?.row ?? update.segmentID
            rows[update.segmentID] = row
            if starts[row] == nil { starts[row] = update.startSample }
        }
        let row = rows[update.segmentID]!
        let prefix = open?.row == row ? open : nil
        let source = (prefix?.source ?? "") + (update.source ?? "")
        let translation = (prefix?.translation ?? "") + update.translation
        let placed = Placement(row: row, source: source, translation: translation,
                               startSample: starts[row] ?? update.startSample, endSample: update.endSample)
        if update.committed {
            let finished = Self.endsSentence(translation) || source.count + translation.count >= Self.maximumRowCharacters
            open = finished ? nil : OpenRow(row: row, source: source, translation: translation,
                                            startSample: placed.startSample, endSample: update.endSample)
        }
        return placed
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。！？.!?".contains(last)
    }
}

enum LiveReplayContent {
    case pcm(Data)
    case speech(text: String, language: String)
    var bytes: Int {
        switch self { case .pcm(let data): return data.count; case .speech(let text, _): return text.utf8.count }
    }
}

/// Both providers keep replay material only in bounded memory, across recording sessions.
struct LiveSessionReplayCache {
    private var clips: [String: LiveReplayContent] = [:]
    private var order: [String] = []
    private var bytes = 0
    private(set) var revision = 0
    let capacity = 128 * 1024 * 1024
    func content(for id: String) -> LiveReplayContent? { clips[id] }
    mutating func insert(_ content: LiveReplayContent, for id: String) {
        guard content.bytes <= capacity else { return }
        if let previous = clips.removeValue(forKey: id) { bytes -= previous.bytes; order.removeAll { $0 == id } }
        while bytes + content.bytes > capacity, !order.isEmpty { bytes -= clips.removeValue(forKey: order.removeFirst())?.bytes ?? 0 }
        clips[id] = content; order.append(id); bytes += content.bytes; revision += 1
    }
    mutating func clear() { clips.removeAll(); order.removeAll(); bytes = 0; revision += 1 }
}
