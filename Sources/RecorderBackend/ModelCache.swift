import Foundation

/// Resolve offline Hub snapshots (model_cache.py). The cache directory layout
/// `models/models--<owner>--<model>/snapshots/<sha>` must stay byte-compatible with the Python build.
enum ModelCache {
    static func resolve(modelID: String, revision: String, cache: URL,
                        validate: (URL) throws -> Void,
                        missing: String = "模型尚未下载完整，请点击「下载模型」。") throws -> (path: String, revision: String) {
        let repo = cache.appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        let snapshots = repo.appendingPathComponent("snapshots")
        func validateSnapshot(_ dir: URL) -> Bool {
            guard FileManager.default.fileExists(atPath: dir.path) else { return false }
            do { try validate(dir); return true } catch { return false }
        }
        if !revision.isEmpty {
            // Explicit revisions must never silently resolve to another version.
            let dir = snapshots.appendingPathComponent(revision)
            if validateSnapshot(dir) { return (dir.path, dir.lastPathComponent) }
            throw BackendError.value("本地缺少模型或版本 \(revision)，请先下载。")
        }
        // Empty revision: the Python path resolves refs/main first, then falls back to an mtime scan.
        if let sha = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8) {
            let dir = snapshots.appendingPathComponent(sha.trimmingCharacters(in: .whitespacesAndNewlines))
            if validateSnapshot(dir) { return (dir.path, dir.lastPathComponent) }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: keys)) ?? []
        let candidates = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .map { url -> (url: URL, mtime: Int64, name: String) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (url, Int64((date?.timeIntervalSince1970 ?? 0) * 1_000_000_000), url.lastPathComponent)
            }
            .sorted { left, right in
                if left.mtime != right.mtime { return left.mtime > right.mtime }
                return left.name > right.name
            }
        for candidate in candidates {
            if validateSnapshot(candidate.url) { return (candidate.url.path, candidate.url.lastPathComponent) }
        }
        throw BackendError.value(missing)
    }
}
