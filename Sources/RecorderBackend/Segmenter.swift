import Foundation

func sentenceComplete(_ raw: String) -> Bool {
    /// Conservative terminal punctuation hint, never a semantic guarantee.
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = text.last, "”’\"'」』）)]".contains(last) { text.removeLast() }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty || text.hasSuffix("...") || text.hasSuffix("…") { return false }
    if ["。", "！", "？", "!", "?"].contains(where: { text.hasSuffix($0) }) { return true }
    if !text.hasSuffix(".") { return false }
    // Avoid numeric endings, initials, dotted abbreviations and common honorifics.
    guard let word = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) else { return false }
    if text.range(of: "\\d\\.$", options: .regularExpression) != nil || word.filter({ $0 == "." }).count > 1 { return false }
    if word.range(of: "^[A-Za-z]\\.$", options: .regularExpression) != nil { return false }
    return !["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "etc.", "vs.", "e.g.", "i.e."].contains(word.lowercased())
}

/// Port of core.py Segmenter. The caller serializes feed/accept/flush (Python used one shared lock;
/// here the BackendCore actor provides the same mutual exclusion).
final class Segmenter {
    let config: ModelConfig
    let emit: (SegmentJob) -> Void

    // preroll keeps up to 12 frames (240 ms) of silence to prepend when speech starts.
    private var preroll: [(offset: Int, pcm: Data)] = []
    private var frames: [Data] = []
    private(set) var position = 0
    private(set) var start = 0
    private(set) var segment = 0
    private(set) var revision = 0
    private var silent = 0
    private var voiced = 0
    private var lastPreview = 0
    private var lastVoiced = 0
    private var snapshotVoiced = 0
    private var results: [PreviewResult] = []

    struct PreviewResult {
        var revision: Int
        var lastVoicedSample: Int
        var text: String
    }

    init(config: ModelConfig, emit: @escaping (SegmentJob) -> Void) {
        self.config = config
        self.emit = emit
    }

    func feed(_ pcm: Data, _ voiced: Bool) throws {
        guard pcm.count == Backend.frame * 2 else { throw BackendError.value("VAD 要求 20 ms PCM16 音频帧") }
        let at = position
        position += Backend.frame
        if frames.isEmpty {
            if !voiced {
                if preroll.count == 12 { preroll.removeFirst() }
                preroll.append((at, pcm))
                return
            }
            start = preroll.first?.offset ?? at
            frames = preroll.map(\.pcm)
            preroll.removeAll()
            segment += 1
            revision = 0
            results = []
        }
        frames.append(pcm)
        if voiced { self.voiced += 1 }
        if voiced { lastVoiced = position }
        silent = voiced ? 0 : silent + 1
        if silent * 20 >= threshold() {
            finish()
        } else if self.voiced >= 3 && lastVoiced > snapshotVoiced &&
                    frames.count * 20 - lastPreview >= config.previewIntervalMS {
            snapshot(false)
            snapshotVoiced = lastVoiced
            lastPreview = frames.count * 20
        }
    }

    func threshold() -> Int {
        if config.endpointMode == "fixed" { return config.endpointSilenceMS }
        guard let latest = results.last else { return 1800 }
        if latest.lastVoicedSample != lastVoiced || !sentenceComplete(latest.text) { return 1800 }
        if results.count == 1 { return 1000 }
        return results[results.count - 2].text == latest.text ? 500 : 1800
    }

    func acceptPreview(item: SegmentJob, text: String) {
        if frames.isEmpty || item.segmentID != segment || item.startSample != start ||
            (!results.isEmpty && item.revision <= results.last!.revision) { return }
        results.append(PreviewResult(revision: item.revision, lastVoicedSample: item.lastVoicedSample ?? 0,
                                     text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        if results.count > 2 { results.removeFirst(results.count - 2) }
        if silent * 20 >= threshold() { finish() }
    }

    private func snapshot(_ final: Bool) {
        revision += 1
        var job = SegmentJob()
        job.segmentID = segment
        job.revision = revision
        job.startSample = start
        job.endSample = position
        job.lastVoicedSample = lastVoiced
        job.final = final
        job.forcedCut = false
        job.pcm = Data(frames.flatMap { $0 })
        emit(job)
    }

    func finish() {
        if !frames.isEmpty && voiced >= 2 { snapshot(true) }
        frames = []
        results = []
        silent = 0
        voiced = 0
        lastPreview = 0
        lastVoiced = 0
        snapshotVoiced = 0
    }

    func flush() {
        finish()
        preroll.removeAll()
    }
}
