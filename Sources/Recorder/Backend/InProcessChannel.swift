import Foundation

/// Event delivery sink implemented by the frontend-side channel.
protocol BackendEventSink: AnyObject {
    func deliver(_ event: [String: Any])
}

/// Wire shape shared by Transport (dual-process) and InProcessChannel (single-process);
/// AppModel talks to the backend exclusively through this surface.
protocol BackendChannel: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func send(_ message: [String: Any])
    func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool
    func close()
}

// Transport conforms to BackendChannel via the extension in Transport.swift.

/// In-process replacement for the Unix-socket Transport: same event dictionary shapes, same
/// ordering (hello -> config + translator + status), same 320 KB audio backpressure semantics.
final class InProcessChannel: BackendChannel, BackendEventSink, @unchecked Sendable {
    private let core: BackendCore
    // Audio frames must reach the core in capture order; a serial queue spawns the actor tasks
    // in FIFO order so the actor mailbox receives them in sequence.
    private let audioQueue = DispatchQueue(label: "recorder.inprocess.audio")
    private let lock = NSLock()
    private var buffered = 0
    private var closed = false

    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?

    init(core: BackendCore) {
        self.core = core
        Task { await core.attach(self) }
    }

    func deliver(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        let core = core
        Task { await core.control(message) }
    }

    func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool {
        let meta: [String: Any] = ["session_id": session, "sequence": sequence, "start_sample": start,
                                   "sample_rate": 16000, "channels": 1, "format": "s16le"]
        guard let header = try? JSONSerialization.data(withJSONObject: meta) else { return false }
        let sizeBytes = Swift.withUnsafeBytes(of: UInt32(header.count).bigEndian) { Data($0) }
        let payload = sizeBytes + header + pcm
        guard reserveAudio(payload.count) else { return false }
        let core = core
        audioQueue.async { [weak self] in
            Task {
                await core.audio(payload)
                self?.releaseAudio(payload.count)
            }
        }
        return true
    }

    private func reserveAudio(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed || buffered + count > 320_000 { return false }
        buffered += count
        return true
    }

    private func releaseAudio(_ count: Int) {
        lock.lock()
        buffered -= count
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        let core = core
        Task { await core.shutdown() }
    }
}
