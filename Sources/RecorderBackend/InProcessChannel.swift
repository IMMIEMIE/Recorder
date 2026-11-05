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
    // Even Tasks created on a serial DispatchQueue can reach an actor out of order.
    // Chain every accepted operation, including stop/close, so commands cannot
    // overtake audio that the frontend has already submitted.
    private var pending: Task<Void, Never>?
    private let lock = NSLock()
    private var buffered = 0
    private var closed = false

    public var onEvent: (([String: Any]) -> Void)?
    public var onFailure: ((String) -> Void)?

    public init(core: BackendCore) {
        self.core = core
        lock.lock()
        enqueueLocked { await core.attach(self) }
        lock.unlock()
    }

    public func deliver(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    public func send(_ message: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let core = core
        enqueueLocked { await core.control(message) }
    }

    public func audio(_ pcm: Data, session: String, sequence: Int, start: Int) -> Bool {
        let meta: [String: Any] = ["session_id": session, "sequence": sequence, "start_sample": start,
                                   "sample_rate": 16000, "channels": 1, "format": "s16le"]
        guard let header = try? JSONSerialization.data(withJSONObject: meta) else { return false }
        let sizeBytes = Swift.withUnsafeBytes(of: UInt32(header.count).bigEndian) { Data($0) }
        let payload = sizeBytes + header + pcm
        lock.lock()
        defer { lock.unlock() }
        guard !closed, buffered + payload.count <= 320_000 else { return false }
        buffered += payload.count
        let core = core
        enqueueLocked { [weak self] in
            await core.audio(payload)
            self?.releaseAudio(payload.count)
        }
        return true
    }

    // Caller holds lock, making admission and ordering atomic across frontend threads.
    private func enqueueLocked(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await operation()
        }
    }

    private func releaseAudio(_ count: Int) {
        lock.lock()
        buffered -= count
        lock.unlock()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let core = core
        enqueueLocked { await core.shutdown() }
    }
}
