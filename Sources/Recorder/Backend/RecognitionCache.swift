import Foundation

/// Worker-owned inference reuse, scoped to one model and bounded to live segments.
struct RecognitionKey: Hashable {
    let session: String
    let segment: Int
    let start: Int
}

final class RecognitionCache {
    struct Entry {
        var chunks: [Int: String] = [:]
        var last: (voiced: Int?, text: String)?
    }

    private(set) var entries: [RecognitionKey: Entry] = [:]

    private func key(_ item: SegmentJob) -> RecognitionKey {
        RecognitionKey(session: item.sessionID, segment: item.segmentID, start: item.startSample)
    }

    func clear() { entries.removeAll() }

    func forget(_ item: SegmentJob) { entries.removeValue(forKey: key(item)) }

    func transcribe(_ engine: Transcriber, config: ModelConfig, item: SegmentJob,
                    obsolete: () async -> Bool = { false }) async throws -> (String, Int) {
        let k = key(item)
        var entry = entries[k] ?? Entry()
        entries[k] = entry
        if let last = entry.last, let voiced = item.lastVoicedSample, last.voiced == voiced {
            return (last.text, 0)
        }
        let chunkBytes = config.maxSegmentSeconds * Backend.rate * 2
        var text = ""
        var duration = 0
        var offset = 0
        while offset < item.pcm.count {
            if await obsolete() {
                entries[k] = entry
                return ("", duration)
            }
            let end = min(offset + chunkBytes, item.pcm.count)
            let pcm = item.pcm.subdata(in: offset..<end)
            let part: String
            if let cached = entry.chunks[offset] {
                part = cached
            } else {
                let (p, elapsed) = try await engine.transcribe(pcm)
                duration += elapsed
                if pcm.count == chunkBytes { entry.chunks[offset] = p }
                part = p
            }
            text = TranslationText.joinText(text, part)
            offset = end
        }
        if !(await obsolete()) {
            entry.last = (item.lastVoicedSample, text)
        }
        entries[k] = entry
        return (text, duration)
    }
}
