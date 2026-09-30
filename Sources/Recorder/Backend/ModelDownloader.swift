import CryptoKit
import Foundation

/// Progress callback: (detail, completed, total). Awaited in order, so the core sees events in sequence.
typealias DownloadProgress = @Sendable (String, Int64, Int64) async -> Void

/// download.py: fetch one pinned Hub snapshot into the shared HF cache.
protocol ModelDownloading: AnyObject, Sendable {
    /// Returns the snapshot folder that holds config.json and the resolved commit SHA.
    func download(modelID: String, revision: String, cache: URL,
                  progress: @escaping DownloadProgress) async throws -> (path: String, revision: String)
}

/// One file of a repo revision (HfApi.model_info(files_metadata=True) siblings).
struct HubFile: Equatable {
    let name: String
    let size: Int64
    /// Blob name in the cache: the LFS sha256, else the git blob id (the ETag huggingface_hub stores under).
    let etag: String
    let lfs: Bool
}

/// Port of download.py on top of the huggingface_hub 1.30 cache layout, written without the Python
/// package: `<cache>/models--<owner>--<name>/blobs/<etag>` plus relative symlinks in
/// `snapshots/<sha>/`, pinned to the commit SHA so no `refs/` entry is written (hf_hub_download with a
/// SHA revision does the same). Both builds therefore read each other's cache.
///
/// Differences from the Python path, none visible in the resulting layout: partial LFS blobs are kept
/// as `blobs/<etag>.incomplete` and resumed with a Range request (huggingface_hub 1.30 restarts each
/// file from zero), and every file is checked against its sha256 / git blob id before it is moved into
/// place. No `.locks/` directory is created; only one download runs at a time.
final class HubDownloader: ModelDownloading, @unchecked Sendable {
    /// download.py's filter; `.jinja` must stay, or translation models lose their chat template.
    static let extensions = [".json", ".safetensors", ".txt", ".model", ".tiktoken", ".npz", ".jinja"]
    static let cacheDirTag = "Signature: 8a477f597d28d172789f06886806bc55\n"
        + "# This file is a cache directory tag created by huggingface_hub.\n"
        + "# For information about cache directory tags, see:\n"
        + "#\thttps://bford.info/cachedir/\n"

    let endpoint: String
    private let session: URLSession

    /// `HF_ENDPOINT` is honoured like huggingface_hub does (mirrors, and the mock hub in tests).
    init(endpoint: String? = nil) {
        let value = endpoint ?? ProcessInfo.processInfo.environment["HF_ENDPOINT"] ?? "https://huggingface.co"
        var trimmed = value
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.endpoint = trimmed
        session = URLSession(configuration: HubDownloader.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "LocalRecorder"]
        return configuration
    }

    func download(modelID: String, revision: String, cache: URL,
                  progress: @escaping DownloadProgress) async throws -> (path: String, revision: String) {
        let (sha, siblings) = try await modelInfo(modelID: modelID, revision: revision)
        let files = siblings.filter { file in Self.extensions.contains { file.name.hasSuffix($0) } }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        var folder: String?
        for file in files {
            await progress(file.name, done, total)
            let pointer = try await fetch(modelID: modelID, sha: sha, file: file, cache: cache, progress: progress)
            if file.name == "config.json" { folder = pointer.deletingLastPathComponent().path }
            done += file.size
        }
        guard let folder else { throw BackendError.value("模型缺少 config.json") }
        return (folder, sha)
    }

    // MARK: - Hub API

    func modelInfo(modelID: String, revision: String) async throws -> (sha: String, files: [HubFile]) {
        var path = "\(endpoint)/api/models/\(Self.quotePath(modelID))"
        if !revision.isEmpty {
            path += "/revision/" + Self.quote(revision, safe: "")
        }
        guard let url = URL(string: path + "?blobs=true") else { throw BackendError.value("模型 ID 无效") }
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String, let siblings = json["siblings"] as? [[String: Any]] else {
            throw BackendError(kind: "FileMetadataError", message: "模型信息格式无效：\(url.absoluteString)")
        }
        guard Self.isHex(sha, length: 40) else {
            throw BackendError(kind: "FileMetadataError", message: "模型版本号无效：\(sha)")
        }
        var files: [HubFile] = []
        for sibling in siblings {
            guard let name = sibling["rfilename"] as? String else { continue }
            let lfs = sibling["lfs"] as? [String: Any]
            let etag = (lfs?["sha256"] as? String) ?? (sibling["blobId"] as? String) ?? ""
            let size = (sibling["size"] as? NSNumber)?.int64Value ?? (lfs?["size"] as? NSNumber)?.int64Value ?? 0
            files.append(HubFile(name: name, size: size, etag: etag.lowercased(), lfs: lfs != nil))
        }
        return (sha, files)
    }

    /// hf_raise_for_status: map Hub error codes onto the exception names download.py reported.
    static func check(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        let status = http.statusCode
        guard !(200..<300).contains(status) else { return }
        let code = http.value(forHTTPHeaderField: "X-Error-Code") ?? ""
        let text = "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status)) for url: \(url.absoluteString)"
        switch code {
        case "RepoNotFound": throw BackendError(kind: "RepositoryNotFoundError", message: text)
        case "RevisionNotFound": throw BackendError(kind: "RevisionNotFoundError", message: text)
        case "EntryNotFound": throw BackendError(kind: "RemoteEntryNotFoundError", message: text)
        case "GatedRepo": throw BackendError(kind: "GatedRepoError", message: text)
        default:
            throw BackendError(kind: status == 401 ? "RepositoryNotFoundError" : "HfHubHTTPError", message: text)
        }
    }

    // MARK: - Cache layout (_hf_hub_download_to_cache_dir)

    static func repoFolder(_ modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }

    /// Returns the snapshot pointer path (the symlink hf_hub_download returns).
    func fetch(modelID: String, sha: String, file: HubFile, cache: URL,
               progress: @escaping DownloadProgress) async throws -> URL {
        try Self.validateRelative(file.name)
        let storage = cache.appendingPathComponent(Self.repoFolder(modelID))
        let pointer = storage.appendingPathComponent("snapshots").appendingPathComponent(sha).appendingPathComponent(file.name)
        let manager = FileManager.default
        // A SHA revision with the file already on disk short-circuits everything (follows the symlink).
        if manager.fileExists(atPath: pointer.path) { return pointer }
        guard Self.isHex(file.etag, length: file.lfs ? 64 : 40) else {
            throw BackendError(kind: "FileMetadataError", message: "缺少文件校验信息：\(file.name)")
        }
        let blob = storage.appendingPathComponent("blobs").appendingPathComponent(file.etag)
        try manager.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tag = cache.appendingPathComponent("CACHEDIR.TAG")
        if !manager.fileExists(atPath: tag.path) { try? Data(Self.cacheDirTag.utf8).write(to: tag) }
        if !manager.fileExists(atPath: blob.path) {
            guard let url = URL(string: "\(endpoint)/\(Self.quotePath(modelID))/resolve/\(sha)/\(Self.quotePath(file.name))") else {
                throw BackendError.value("模型文件名无效：\(file.name)")
            }
            try await fetchBlob(url: url, blob: blob, file: file, progress: progress)
        }
        try Self.link(blob: blob, pointer: pointer, depth: file.name.split(separator: "/").count)
        return pointer
    }

    /// _create_symlink: relative target (`../../blobs/<etag>`, one more `../` per subdirectory).
    static func link(blob: URL, pointer: URL, depth: Int) throws {
        let target = String(repeating: "../", count: depth + 1) + "blobs/" + blob.lastPathComponent
        try? FileManager.default.removeItem(at: pointer)
        try FileManager.default.createSymbolicLink(atPath: pointer.path, withDestinationPath: target)
    }

    /// tqdm's desc in http_get: long names keep their tail.
    static func displayName(_ name: String) -> String {
        let characters = Array(name)
        return characters.count > 40 ? "(…)" + String(characters.suffix(40)) : name
    }

    private func fetchBlob(url: URL, blob: URL, file: HubFile, progress: @escaping DownloadProgress) async throws {
        let manager = FileManager.default
        let partial = URL(fileURLWithPath: blob.path + ".incomplete")
        let display = Self.displayName(file.name)
        var retries = 5
        while true {
            // Only LFS blobs resume: small git files may arrive gzip-encoded and are cheap to refetch.
            var offset: Int64 = 0
            if file.lfs, let size = (try? manager.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber {
                offset = size.int64Value
            }
            if offset > file.size || !file.lfs {
                try? manager.removeItem(at: partial)
                offset = 0
            }
            let fresh = ContentHash(file: file)
            var hash = fresh
            if offset > 0 { try hash.update(contentsOf: partial) }
            var written = offset
            if offset < file.size || !manager.fileExists(atPath: partial.path) {
                var request = URLRequest(url: url)
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                let transfer = FileTransfer(request: request, file: partial, offset: offset, hash: hash, fresh: fresh)
                do {
                    for try await bytes in transfer.start() {
                        await progress(display, bytes, file.size)
                    }
                    try Task.checkCancellation()
                    (hash, written) = transfer.result
                } catch TransferRestart.range {
                    try? manager.removeItem(at: partial)
                    continue
                } catch let error as URLError where Self.transient(error) && !Task.isCancelled && retries > 0 {
                    // http_get: resume a few times after a dropped connection; progress resets the budget.
                    retries = transfer.result.written > offset ? 5 : retries - 1
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            }
            guard written == file.size else {
                try? manager.removeItem(at: partial)
                throw BackendError(kind: "OSError", message: "文件大小校验失败：\(display) 应为 \(file.size) 字节，实际 \(written) 字节（多为网络中断，可重试）")
            }
            guard hash.hex() == file.etag else {
                try? manager.removeItem(at: partial)
                throw BackendError(kind: "OSError", message: "文件校验失败：\(display) 内容与模型仓库记录不一致，请重试")
            }
            guard rename(partial.path, blob.path) == 0 else {
                throw BackendError(kind: "OSError", message: "无法写入模型缓存：\(String(cString: strerror(errno)))")
            }
            return
        }
    }

    static func transient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
         .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    /// _validate_relative_filename: repo file names must stay inside the snapshot folder.
    static func validateRelative(_ name: String) throws {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        if name.isEmpty || name.hasPrefix("/") || name.contains("\\") ||
            parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) {
            throw BackendError.value("模型文件名不安全：\(name)")
        }
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// urllib.parse.quote: ASCII letters, digits, `_.-~` and `safe` stay; everything else is escaped.
    static func quote(_ value: String, safe: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        allowed.insert(charactersIn: safe)
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func quotePath(_ value: String) -> String { quote(value, safe: "/") }
}

/// The checksum huggingface_hub's cache verification uses: sha256 for LFS files, git blob sha1 otherwise.
struct ContentHash {
    private var sha256: SHA256?
    private var sha1: Insecure.SHA1?

    init(file: HubFile) {
        if file.lfs {
            sha256 = SHA256()
        } else {
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(file.size)\0".utf8))
            sha1 = hash
        }
    }

    mutating func update(_ data: Data) {
        sha256?.update(data: data)
        sha1?.update(data: data)
    }

    mutating func update(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            update(chunk)
        }
    }

    func hex() -> String {
        let bytes: [UInt8] = sha256.map { Array($0.finalize()) } ?? sha1.map { Array($0.finalize()) } ?? []
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum TransferRestart: Error {
    /// 416, or a 206 that does not continue where the partial file ends: start the file over.
    case range
}

/// One GET streamed into a file; yields the file's byte count (throttled) while it grows.
private final class FileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let file: URL
    private let offset: Int64
    private let fresh: ContentHash
    private let lock = NSLock()
    // Mutated on the serial delegate queue; read by the consumer after the stream finishes.
    private var hash: ContentHash
    private var written: Int64
    private var handle: FileHandle?
    private var failure: Error?
    private var stopped = false
    private var lastYield = 0.0
    private var continuation: AsyncThrowingStream<Int64, Error>.Continuation?

    init(request: URLRequest, file: URL, offset: Int64, hash: ContentHash, fresh: ContentHash) {
        self.request = request
        self.file = file
        self.offset = offset
        self.fresh = fresh
        self.hash = hash
        written = offset
    }

    var result: (hash: ContentHash, written: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (hash, written)
    }

    func start() -> AsyncThrowingStream<Int64, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: HubDownloader.configuration(), delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            continuation.onTermination = { [weak self] _ in
                self?.stop()
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The Hub redirects LFS files to a CDN; the resume offset must survive the hop.
        var next = newRequest
        if let range = request.value(forHTTPHeaderField: "Range") { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        do {
            if status == 206 && offset > 0 {
                let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(offset)-") else { throw TransferRestart.range }
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                self.handle = handle
            } else if status == 416 {
                throw TransferRestart.range
            } else if (200..<300).contains(status) {
                // Full body: the server ignored the Range (or none was sent), so start the file over.
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                    throw BackendError(kind: "OSError", message: "无法写入模型缓存：\(file.path)")
                }
                handle = try FileHandle(forWritingTo: file)
                lock.lock()
                written = 0
                hash = fresh
                lock.unlock()
            } else if let url = response.url {
                try HubDownloader.check(response, url: url)
                throw BackendError(kind: "HfHubHTTPError", message: "\(status) for url: \(url.absoluteString)")
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        lock.lock()
        hash.update(data)
        written += Int64(data.count)
        let count = written
        lock.unlock()
        let now = backendNow()
        if now - lastYield >= 0.1 {
            lastYield = now
            continuation?.yield(count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let failure {
            continuation?.finish(throwing: failure)
        } else if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.yield(result.written)
            continuation?.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
