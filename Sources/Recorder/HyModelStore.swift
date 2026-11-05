import Combine
import Foundation
#if canImport(RecorderBackend)
import RecorderBackend
#endif

protocol HyModelStoring: Sendable {
    /// Presence and size only; never reads the weights.
    func hasCachedFile(in cache: URL) -> Bool
    func verifiedFile(in cache: URL) async throws -> URL?
    func download(to cache: URL, progress: @escaping @Sendable (String, Int64, Int64) async -> Void) async throws -> URL
}

struct HyPinnedModelStorage: HyModelStoring {
    static let artifact = PinnedModelArtifact(
        modelID: "tencent/Hy-SimulMT-30B-A3B-Interleave-GGUF",
        revision: "2aae4719eb91c1e6990c9386f70b2610f106b97e",
        filename: "Hy-SimulMT-30B-A3B-Interleave-Q4_K_M.gguf",
        size: 19_746_809_728,
        sha256: "26c87f0a5f6409f3a57f8c4d2a49d58ad0f5c0753141643789e73564339cedbc")

    func hasCachedFile(in cache: URL) -> Bool { Self.artifact.hasCompleteFile(in: cache) }
    func verifiedFile(in cache: URL) async throws -> URL? { try await Self.artifact.verifiedFile(in: cache) }
    func download(to cache: URL, progress: @escaping @Sendable (String, Int64, Int64) async -> Void) async throws -> URL {
        try await Self.artifact.download(to: cache, progress: progress)
    }
}

/// Owns disk readiness only. The local translation session separately owns loaded GPU resources.
/// Public synchronous methods are called on the main thread, matching AppModel. Async callbacks
/// explicitly return to the main actor; hashing and transfers run outside it.
final class HyModelStore: ObservableObject {
    @Published private(set) var state = "missing"
    @Published private(set) var detail = "请下载 Hy-SimulMT Q4_K_M 模型（约 19.75 GB）"
    @Published private(set) var progress = 0.0
    @Published private(set) var modelPath: String?
    var modelDirectory: String? { modelPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } }
    var isBusy: Bool { state == "checking" || state == "downloading" }
    let root: URL
    private let storage: any HyModelStoring
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(root: URL? = nil, storage: any HyModelStoring = HyPinnedModelStorage()) {
        assert(Thread.isMainThread)
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalRecorder/models")
        self.storage = storage
    }

    var hasCachedFile: Bool { modelPath != nil || storage.hasCachedFile(in: root) }

    /// What the settings page shows before a load. Hashing 19.75 GB waits until the model is used.
    func inspectCache() {
        assert(Thread.isMainThread)
        guard !isBusy, modelPath == nil else { return }
        if storage.hasCachedFile(in: root) { state = "missing"; detail = "Hy-SimulMT Q4_K_M 已下载 · 加载时校验" }
        else if state != "error" { state = "missing"; detail = "请下载 Hy-SimulMT Q4_K_M 模型（约 19.75 GB）" }
    }

    /// Full local validation before model use; no network or automatic download.
    /// A load that arrives during a running check waits for that check instead of failing on it.
    func refresh() async {
        let task = await MainActor.run { () -> Task<Void, Never>? in
            if self.state == "checking" { return self.operation }
            guard !self.isBusy else { return nil }
            let id = UUID(); self.generation = id
            self.state = "checking"; self.detail = "正在校验本地 Hy-SimulMT 模型…"
            self.modelPath = nil; self.progress = 0
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let file = try await self.storage.verifiedFile(in: self.root)
                    guard self.generation == id, !Task.isCancelled else { return }
                    self.operation = nil
                    if let file { self.ready(file) }
                    else { self.state = "missing"; self.detail = "请下载 Hy-SimulMT Q4_K_M 模型（约 19.75 GB）" }
                } catch {
                    guard self.generation == id else { return }
                    self.operation = nil; self.failed(error)
                }
            }
            self.operation = task
            return task
        }
        await task?.value
    }

    func download() {
        assert(Thread.isMainThread)
        guard !isBusy else { return }
        let id = UUID(); generation = id
        state = "downloading"; detail = "正在下载 Hy-SimulMT Q4_K_M…"; progress = 0; modelPath = nil
        let storage = storage, root = root
        operation = Task { @MainActor [weak self] in
            do {
                let file = try await storage.download(to: root) { [weak self] name, done, total in
                    await self?.update(id: id, name: name, done: done, total: total)
                }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.operation = nil; self.ready(file)
            } catch {
                guard let self, self.generation == id else { return }
                self.operation = nil; self.failed(error)
            }
        }
    }

    func cancel() {
        assert(Thread.isMainThread)
        generation = UUID(); operation?.cancel(); operation = nil
        modelPath = nil; state = "missing"; progress = 0
        detail = "下载或校验已取消；已下载内容可继续使用"
    }
    func cancelDownload() { cancel() }

    @MainActor private func update(id: UUID, name: String, done: Int64, total: Int64) {
        guard generation == id else { return }
        progress = total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
        detail = done == total ? "下载完成，正在校验模型…" : "\(name) · \(Int(progress * 100))%"
    }
    private func ready(_ file: URL) {
        modelPath = file.path; progress = 1; state = "ready"; detail = "Hy-SimulMT Q4_K_M 已校验 · 可离线加载"
    }
    private func failed(_ error: Error) {
        modelPath = nil; state = "error"; progress = 0
        detail = "Hy-SimulMT 模型不可用：\(backendErrorMessage(error))"
    }
}
