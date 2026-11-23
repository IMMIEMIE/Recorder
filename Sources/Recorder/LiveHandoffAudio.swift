import Foundation

/// PCM16 mono at 16 kHz. One instance per lane, used on its serialized capture path.
struct LiveHandoffAudio {
    enum Reason { case recovery, languageSwitch }
    let reason: Reason
    private let capacity: Int
    private var bytes = Data()
    private var nextSendMs: Int64 = 0

    init(_ reason: Reason) {
        self.reason = reason
        capacity = (reason == .recovery ? 1_000 : 5_000) * 32
    }

    mutating func append(_ pcm: Data) {
        precondition(pcm.count.isMultiple(of: 2))
        if pcm.count >= capacity {
            bytes = Data(pcm.suffix(capacity))
        } else {
            let excess = bytes.count + pcm.count - capacity
            if excess > 0 { bytes.removeFirst(excess) }
            bytes.append(pcm)
        }
    }

    /// #25 permits the recent second at attach. A planned handoff sends up to 100 ms at a time
    /// at 1.25x; a delayed timer tick never releases a five-second burst.
    mutating func poll(nowMs: Int64) -> Data? {
        guard !bytes.isEmpty, reason == .recovery || nowMs >= nextSendMs else { return nil }
        let count = reason == .recovery ? bytes.count : min(bytes.count, 3_200)
        let audio = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        if reason == .languageSwitch { nextSendMs = nowMs + Int64((count + 39) / 40) }
        return audio
    }
}
