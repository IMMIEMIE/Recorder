import Foundation

/// One explicitly selected, immutable Hub artifact. Unlike a model snapshot download this does
/// not fetch sibling quantizations or require a Transformers config.json.
public struct PinnedModelArtifact: Sendable {
    public let modelID: String
    public let revision: String
    public let filename: String
    public let size: Int64
    public let sha256: String

    public init(modelID: String, revision: String, filename: String, size: Int64, sha256: String) {
        self.modelID = modelID; self.revision = revision; self.filename = filename
        self.size = size; self.sha256 = sha256
    }

    public func fileURL(in cache: URL) -> URL {
        cache.appendingPathComponent(HubDownloader.repoFolder(modelID))
            .appendingPathComponent("snapshots").appendingPathComponent(revision).appendingPathComponent(filename)
    }

    private func validateMetadata() throws {
        guard validModelID(modelID), HubDownloader.isHex(revision, length: 40),
              HubDownloader.isHex(sha256, length: 64), size > 0 else {
            throw BackendError.value("固定模型的版本或校验信息无效")
        }
        try HubDownloader.validateRelative(filename)
    }

    /// The expected file is present at full size. This does not prove its bytes; see `verifiedFile`.
    public func hasCompleteFile(in cache: URL) -> Bool {
        let path = fileURL(in: cache).resolvingSymlinksInPath().path
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value == size
    }

    /// Always verifies the bytes, including already-cached snapshots; never contacts the Hub.
    public func verifiedFile(in cache: URL) async throws -> URL? {
        try validateMetadata()
        let file = fileURL(in: cache)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try await verify(file)
    }

    private func verify(_ file: URL) async throws -> URL {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path)
            guard (attributes[.size] as? NSNumber)?.int64Value == size else {
                throw BackendError.value("本地模型大小校验失败，请重新下载模型")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = ContentHash(file: HubFile(name: filename, size: size, etag: sha256, lfs: true))
            while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data)
            }
            guard hash.hex() == sha256 else {
                throw BackendError.value("本地模型 SHA-256 校验失败，请重新下载模型")
            }
            return file
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Uses the existing resumable downloader and HF blob/snapshot layout for exactly this file.
    /// An explicit download repairs a damaged copy of this pinned artifact only.
    public func download(to cache: URL, endpoint: String? = nil,
                         progress: @escaping @Sendable (String, Int64, Int64) async -> Void) async throws -> URL {
        try validateMetadata()
        let pointer = fileURL(in: cache)
        let blob = cache.appendingPathComponent(HubDownloader.repoFolder(modelID))
            .appendingPathComponent("blobs").appendingPathComponent(sha256)
        do {
            if let cached = try await verifiedFile(in: cache) { return cached }
            // A removed snapshot pointer must not hide a damaged blob from the repair path.
            // fetch() reuses existing blobs without hashing them, so validate before relinking.
            if FileManager.default.fileExists(atPath: blob.path) { _ = try await verify(blob) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // removeItem unlinks symlinks themselves; it does not remove an external link target.
            try? FileManager.default.removeItem(at: pointer)
            try? FileManager.default.removeItem(at: blob)
        }
        try Task.checkCancellation()
        let file = HubFile(name: filename, size: size, etag: sha256, lfs: true)
        let downloaded = try await HubDownloader(endpoint: endpoint).fetch(
            modelID: modelID, sha: revision, file: file, cache: cache, progress: progress)
        try Task.checkCancellation()
        return try await verify(downloaded)
    }
}
