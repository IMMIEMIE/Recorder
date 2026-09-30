import Foundation

/// Event delivery sink implemented by the frontend-side channel.
public protocol BackendEventSink: AnyObject {
    func deliver(_ event: [String: Any])
}

/// The surface AppModel talks to the backend through (formerly shared with the Unix-socket Transport
/// of the Python sidecar; event dictionaries keep the protocol_version 1 wire shapes).
public protocol BackendChannel: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func send(_ message: [String: Any])
    func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool
    func close()
}

/// In-process replacement for the former Unix-socket Transport: same event dictionary shapes, same
/// ordering (hello -> config + translator + status), same 320 KB audio backpressure semantics.
public final class InProcessChannel: BackendChannel, BackendEventSink, @unchecked Sendable {
    private let core: BackendCore
    // Audio frames must reach the core in capture order; a serial queue spawns the actor tasks
    // in FIFO order so the actor mailbox receives them in sequence.
    private let audioQueue = DispatchQueue(label: "recorder.inprocess.audio")
    private let lock = NSLock()
    private var buffered = 0
    private var closed = false

    public var onEvent: (([String: Any]) -> Void)?
    public var onFailure: ((String) -> Void)?

    public init(core: BackendCore) {
        self.core = core
        Task { await core.attach(self) }
    }

    public func deliver(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    public func send(_ message: [String: Any]) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        let core = core
        Task { await core.control(message) }
    }

    public func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool {
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

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        let core = core
        Task { await core.shutdown() }
    }
}
