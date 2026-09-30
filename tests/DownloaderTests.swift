import CryptoKit
import Foundation

// ModelDownloader against tests/mock_hub_server.py (scripts/test_download.sh), plus a layout check
// against a real Hugging Face cache written by the Python build (`hub` mode).

struct TestFailure: Error { let message: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}

let mockURL = ProcessInfo.processInfo.environment["RECORDER_MOCK_URL"] ?? ""
let mockSHA = "0123456789abcdef0123456789abcdef01234567"
let included = ["config.json", "tokenizer_config.json", "chat_template.jinja", "nested/merges.txt", "model.safetensors"]

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(detail: String, completed: Int64, total: Int64)] = []
    var all: [(detail: String, completed: Int64, total: Int64)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
    func record(_ detail: String, _ completed: Int64, _ total: Int64) {
        lock.lock(); items.append((detail, completed, total)); lock.unlock()
    }
}

func tempCache() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-hub-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func mockLog() async throws -> [[String: Any]] {
    let (data, _) = try await URLSession.shared.data(from: URL(string: mockURL + "/__log")!)
    return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
}

func resetLog() async throws {
    var request = URLRequest(url: URL(string: mockURL + "/__reset")!)
    request.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: request)
}

func fileSHA256(_ url: URL) throws -> String {
    var hash = SHA256()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Relative path -> "dir" | "link:<target>" | "file:<sha256>", the byte-level shape of a cache folder.
func tree(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let manager = FileManager.default
    guard let names = manager.enumerator(atPath: root.path) else { return result }
    for case let name as String in names {
        let path = root.appendingPathComponent(name).path
        let type = try manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            result[name] = "link:" + (try manager.destinationOfSymbolicLink(atPath: path))
        } else if type == .typeDirectory {
            result[name] = "dir"
        } else {
            result[name] = "file:" + (try fileSHA256(URL(fileURLWithPath: path)))
        }
    }
    return result
}

func download(_ model: String, revision: String = "", cache: URL, log: ProgressLog? = nil) async throws -> (path: String, revision: String) {
    try await HubDownloader(endpoint: mockURL).download(modelID: model, revision: revision, cache: cache) { detail, completed, total in
        log?.record(detail, completed, total)
    }
}

func expectError(_ kind: String, containing text: String, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as BackendError {
        try expect(error.kind == kind && error.message.contains(text), "unexpected error \(error)")
        return
    }
    throw TestFailure(message: "expected \(kind)")
}

// MARK: - Mock hub

func testLayoutMatchesHubCache() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let log = ProgressLog()
    let result = try await download("mock/tiny", cache: cache, log: log)
    let repo = cache.appendingPathComponent("models--mock--tiny")
    try expect(result.revision == mockSHA, "resolved commit")
    try expect(result.path == repo.appendingPathComponent("snapshots/\(mockSHA)").path, "snapshot folder holds config.json")
    let (_, files) = try await HubDownloader(endpoint: mockURL).modelInfo(modelID: "mock/tiny", revision: "")
    let entries = try tree(repo)
    for file in files {
        let pointer = "snapshots/\(mockSHA)/\(file.name)"
        guard included.contains(file.name) else {
            try expect(entries[pointer] == nil && entries["blobs/\(file.etag)"] == nil, "\(file.name) filtered out")
            continue
        }
        let depth = file.name.split(separator: "/").count
        try expect(entries[pointer] == "link:" + String(repeating: "../", count: depth + 1) + "blobs/\(file.etag)", "relative symlink for \(file.name): \(entries[pointer] ?? "nil")")
        let blob = repo.appendingPathComponent("blobs/\(file.etag)")
        var hash = ContentHash(file: file)
        hash.update(try Data(contentsOf: blob))
        try expect(hash.hex() == file.etag, "blob named by its etag: \(file.name)")
        let mode = (try FileManager.default.attributesOfItem(atPath: blob.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try expect(mode & 0o044 == 0o044, "blob readable like huggingface_hub's umask-probed mode")
    }
    try expect(!entries.keys.contains { $0.hasSuffix(".incomplete") }, "no partial files left")
    try expect(!entries.keys.contains { $0.hasPrefix("refs") }, "a SHA revision writes no refs entry")
    try expect(entries.keys.filter { $0.hasPrefix("blobs/") }.count == included.count, "one blob per included file")
    let tag = try String(contentsOf: cache.appendingPathComponent("CACHEDIR.TAG"), encoding: .utf8)
    try expect(tag == HubDownloader.cacheDirTag, "CACHEDIR.TAG")
    // Resolvable offline by the same algorithm both builds use.
    let resolved = try ModelCache.resolve(modelID: "mock/tiny", revision: mockSHA, cache: cache) { _ in }
    try expect(resolved.revision == mockSHA, "ModelCache resolves the download")

    let events = log.all
    let total = files.filter { included.contains($0.name) }.reduce(Int64(0)) { $0 + $1.size }
    let aggregate = events.filter { $0.total == total }
    try expect(aggregate.map(\.detail) == included, "one aggregate event per file, in listing order: \(aggregate.map(\.detail))")
    try expect(aggregate.first?.completed == 0 && aggregate.map(\.completed) == aggregate.map(\.completed).sorted(), "aggregate is cumulative")
    try expect(events.last { $0.detail == "model.safetensors" && $0.total == 3_145_728 }?.completed == 3_145_728, "per-file progress ends at the file size")
}

func testCachedFilesSkipNetwork() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    _ = try await download("mock/tiny", cache: cache)
    try await resetLog()
    _ = try await download("mock/tiny", cache: cache)
    var paths = try await mockLog().compactMap { $0["path"] as? String }
    try expect(paths == ["/api/models/mock/tiny"], "only model_info on a cached snapshot: \(paths)")
    // A missing pointer with its blob present is relinked without a transfer.
    let pointer = cache.appendingPathComponent("models--mock--tiny/snapshots/\(mockSHA)/model.safetensors")
    try FileManager.default.removeItem(at: pointer)
    try await resetLog()
    _ = try await download("mock/tiny", revision: mockSHA, cache: cache)
    paths = try await mockLog().compactMap { $0["path"] as? String }
    try expect(paths == ["/api/models/mock/tiny/revision/\(mockSHA)"], "blob reused: \(paths)")
    try expect(FileManager.default.fileExists(atPath: pointer.path), "pointer restored")
}

func testCancelKeepsPartialAndResumes() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (_, files) = try await HubDownloader(endpoint: mockURL).modelInfo(modelID: "mock/slow", revision: "")
    let weights = files.first { $0.name == "model.safetensors" }!
    let partial = cache.appendingPathComponent("models--mock--slow/blobs/\(weights.etag).incomplete")
    let task = Task { try await download("mock/slow", cache: cache) }
    var size: Int64 = 0
    for _ in 0..<400 {
        size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > 256 * 1024 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try expect(size > 0, "transfer started")
    task.cancel()
    do {
        _ = try await task.value
        throw TestFailure(message: "cancelled download finished")
    } catch is CancellationError {
    } catch let error as URLError where error.code == .cancelled {
    }
    try expect(FileManager.default.fileExists(atPath: partial.path), "partial blob kept for resume")
    try expect(!FileManager.default.fileExists(atPath: partial.deletingPathExtension().path), "no blob from a cancelled transfer")
    try await resetLog()
    _ = try await download("mock/slow", cache: cache)
    let ranges = try await mockLog().filter { ($0["path"] as? String)?.hasPrefix("/cdn/") == true }.compactMap { $0["range"] as? String }
    try expect(ranges.count == 1 && ranges[0] != "bytes=0-" && ranges[0].hasPrefix("bytes="), "resumed with a Range across the CDN redirect: \(ranges)")
    let blob = partial.deletingPathExtension()
    try expect(try fileSHA256(blob) == weights.etag, "resumed blob intact")
}

func testServerIgnoringRangeRestartsFile() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let (_, files) = try await HubDownloader(endpoint: mockURL).modelInfo(modelID: "mock/norange", revision: "")
    let weights = files.first { $0.name == "model.safetensors" }!
    let blobs = cache.appendingPathComponent("models--mock--norange/blobs")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try Data(repeating: 0xAA, count: 1000).write(to: blobs.appendingPathComponent("\(weights.etag).incomplete"))
    _ = try await download("mock/norange", cache: cache)
    try expect(try fileSHA256(blobs.appendingPathComponent(weights.etag)) == weights.etag, "200 answer rewrites the partial file")
}

func testCorruptBlobRejected() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    try await expectError("OSError", containing: "文件校验失败") { _ = try await download("mock/corrupt", cache: cache) }
    let repo = cache.appendingPathComponent("models--mock--corrupt")
    let entries = try tree(repo)
    try expect(!entries.keys.contains { $0.hasSuffix(".incomplete") }, "corrupt partial removed")
    try expect(entries["snapshots/\(mockSHA)/model.safetensors"] == nil, "no pointer to a corrupt blob")
}

func testErrorsMatchDownloadPy() async throws {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    try await expectError("ValueError", containing: "模型缺少 config.json") { _ = try await download("mock/noconfig", cache: cache) }
    try await expectError("RepositoryNotFoundError", containing: "401") { _ = try await download("nobody/none", cache: cache) }
    try await expectError("RevisionNotFoundError", containing: "404") { _ = try await download("mock/tiny", revision: "v9", cache: cache) }
}

func testUnsafeNamesRejected() throws {
    for name in ["../escape.json", "a/../../b.json", "/abs.json", "a\\b.json", "a//b.json", ""] {
        do {
            try HubDownloader.validateRelative(name)
            throw TestFailure(message: "accepted \(name)")
        } catch is BackendError {}
    }
    try HubDownloader.validateRelative("nested/merges.txt")
    try expect(HubDownloader.displayName(String(repeating: "a", count: 41)) == "(…)" + String(repeating: "a", count: 40), "tqdm desc truncation")
}

/// scripts/test_download.sh runs backend/download.py against the same mock first when the Python
/// environment is present; both builds must leave byte-identical cache folders.
func testPythonParity() async throws {
    guard let reference = ProcessInfo.processInfo.environment["RECORDER_PYTHON_CACHE"] else {
        print("SKIP python parity (no .venv with huggingface_hub)")
        return
    }
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    _ = try await download("mock/tiny", cache: cache)
    let python = try tree(URL(fileURLWithPath: reference).appendingPathComponent("models--mock--tiny"))
    let swift = try tree(cache.appendingPathComponent("models--mock--tiny"))
    let differences = Set(python.keys).union(swift.keys).filter { python[$0] != swift[$0] }.sorted()
    try expect(differences.isEmpty, "cache folders differ: \(differences.map { "\($0): python=\(python[$0] ?? "-") swift=\(swift[$0] ?? "-")" })")
    let tag = try String(contentsOf: URL(fileURLWithPath: reference).appendingPathComponent("CACHEDIR.TAG"), encoding: .utf8)
    try expect(tag == HubDownloader.cacheDirTag, "CACHEDIR.TAG matches huggingface_hub")
}

// MARK: - Real hub (`hub <model_id> <cache> [--full]`)

/// Compares the layout the Swift downloader would write against a cache the Python build downloaded:
/// every snapshot pointer must link to `blobs/<etag>` by the same relative path, with the same size.
/// `--full` also downloads the model into a scratch cache and diffs the two folders byte for byte.
func checkRealHub(modelID: String, reference: URL, full: Bool) async throws {
    let downloader = HubDownloader()
    let repo = reference.appendingPathComponent(HubDownloader.repoFolder(modelID))
    let snapshots = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("snapshots").path)
    var checked = 0
    for sha in snapshots where HubDownloader.isHex(sha, length: 40) {
        let (_, files) = try await downloader.modelInfo(modelID: modelID, revision: sha)
        for file in files where HubDownloader.extensions.contains(where: { file.name.hasSuffix($0) }) {
            let pointer = repo.appendingPathComponent("snapshots/\(sha)/\(file.name)")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: pointer.path) else {
                print("  missing in reference: \(sha)/\(file.name)")
                continue
            }
            let expected = String(repeating: "../", count: file.name.split(separator: "/").count + 1) + "blobs/\(file.etag)"
            // attributesOfItem does not traverse the last symlink (it would return the link string's length).
            let size = (try FileManager.default.attributesOfItem(atPath: pointer.resolvingSymlinksInPath().path)[.size] as? NSNumber)?.int64Value
            try expect(target == expected, "\(file.name): python links \(target), swift would link \(expected)")
            try expect(size == file.size, "\(file.name): size \(size ?? -1) vs \(file.size)")
            checked += 1
        }
    }
    try expect(checked > 0, "no cached snapshot of \(modelID) under \(reference.path)")
    print("layout OK: \(checked) files of \(modelID) link to the blobs the Swift downloader would write")
    guard full else { return }
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache) }
    let started = Date()
    let result = try await downloader.download(modelID: modelID, revision: snapshots.sorted().first ?? "", cache: cache) { _, _, _ in }
    print("downloaded \(result.revision) in \(String(format: "%.0fs", -started.timeIntervalSinceNow))")
    let python = try tree(repo)
    let swift = try tree(cache.appendingPathComponent(HubDownloader.repoFolder(modelID)))
    let differences = Set(swift.keys).filter { python[$0] != swift[$0] }.sorted()
    try expect(differences.isEmpty, "differs from the Python cache: \(differences)")
    print("byte-identical: \(swift.count) entries")
}

@main struct DownloaderTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count >= 4, arguments[1] == "hub" {
            do {
                try await checkRealHub(modelID: arguments[2], reference: URL(fileURLWithPath: arguments[3]),
                                       full: arguments.contains("--full"))
            } catch {
                print("FAIL \(error)")
                exit(1)
            }
            return
        }
        let started = Date()
        var failures = 0
        var passed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                passed += 1
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        await run("layout matches hub cache", testLayoutMatchesHubCache)
        await run("cached files skip network", testCachedFilesSkipNetwork)
        await run("cancel keeps partial + resumes", testCancelKeepsPartialAndResumes)
        await run("range ignored restarts", testServerIgnoringRangeRestartsFile)
        await run("corrupt blob rejected", testCorruptBlobRejected)
        await run("errors match download.py", testErrorsMatchDownloadPy)
        await run("unsafe names rejected", testUnsafeNamesRejected)
        await run("python parity", testPythonParity)
        print("\(passed) passed, \(failures) failed in \(String(format: "%.1fs", -started.timeIntervalSinceNow))")
        if failures > 0 { exit(1) }
    }
}
