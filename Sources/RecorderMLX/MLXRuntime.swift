import Foundation
import MLX

/// Process-wide MLX plumbing shared by the ASR and translation engines.
///
/// All model work (load, warmup, inference, token steps, unload) runs on one serial queue:
/// MLX evaluation is synchronous and long-running, so it must not occupy Swift's cooperative
/// thread pool, and serializing it mirrors the single Python worker thread that owned every model.
public enum MLXRuntime {
    private static let queue = DispatchQueue(label: "recorder.mlx", qos: .userInitiated)
    private static let lock = NSLock()
    private static var configured = false

    /// Points MLX at the bundled Metal kernel library. SwiftPM builds of mlx-swift ship no
    /// metallib, so the app bundles one (Contents/Resources/mlx.metallib). Must run before any
    /// MLX operation; later calls are ignored.
    public static func configure(metallib: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard !configured else { return }
        configured = true
        if let metallib, FileManager.default.fileExists(atPath: metallib.path) {
            GPU.metallib = metallib
        }
    }

    /// Runs `body` on the MLX queue and resumes the caller with its result.
    public static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool { try body() } })
            }
        }
    }

    /// Synchronous variant for callers that are already off the cooperative pool (the verify CLI).
    public static func sync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync { try autoreleasepool { try body() } }
    }

    /// Returns freed Metal buffers to the system (Python: mx.clear_cache()).
    public static func clearCache() {
        Memory.clearCache()
    }

    public static var peakMemory: Int { Memory.peakMemory }
}

/// Model-layer failures, with Chinese messages the app surfaces verbatim.
public struct MLXModelError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}
