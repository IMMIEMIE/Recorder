import Foundation

/// Session file v1 (docs/SESSIONS.md). One finished-text record per conversation; the format is
/// shared with the Android app. Readers ignore unknown fields.
struct SessionFile: Codable, Equatable, Identifiable {
    static let schemaVersion = 1

    struct Segment: Codable, Equatable {
        var startedAtMs: Int64
        var endedAtMs: Int64?
        var targetLanguage: String?
        /// `live_translate`, `hy_local`, `local_asr`, `api_asr` or `streaming_asr`.
        var mode: String

        enum CodingKeys: String, CodingKey {
            case startedAtMs = "started_at_ms", endedAtMs = "ended_at_ms", targetLanguage = "target_language", mode
        }
        init(startedAtMs: Int64, endedAtMs: Int64? = nil, targetLanguage: String?, mode: String) {
            self.startedAtMs = startedAtMs; self.endedAtMs = endedAtMs; self.targetLanguage = targetLanguage; self.mode = mode
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAtMs = try c.decode(Int64.self, forKey: .startedAtMs)
            endedAtMs = try c.decodeIfPresent(Int64.self, forKey: .endedAtMs)
            targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage)
            mode = try c.decode(String.self, forKey: .mode)
        }
        // Optional values are written as explicit nulls, as the spec shows.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(startedAtMs, forKey: .startedAtMs)
            try c.encode(endedAtMs, forKey: .endedAtMs)
            try c.encode(targetLanguage, forKey: .targetLanguage)
            try c.encode(mode, forKey: .mode)
        }
    }

    struct Row: Codable, Equatable {
        enum Kind: String, Codable { case text, `break` }
        var segment: Int
        var kind: Kind
        var offsetMs: Int64
        var source: String
        var translation: String

        enum CodingKeys: String, CodingKey { case segment, kind, offsetMs = "offset_ms", source, translation }
        init(segment: Int, kind: Kind = .text, offsetMs: Int64, source: String, translation: String) {
            self.segment = segment; self.kind = kind; self.offsetMs = offsetMs; self.source = source; self.translation = translation
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segment = try c.decode(Int.self, forKey: .segment)
            kind = try c.decode(Kind.self, forKey: .kind)
            offsetMs = try c.decodeIfPresent(Int64.self, forKey: .offsetMs) ?? 0
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        }
    }

    var id: String
    var title: String
    var titleEdited: Bool
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var segments: [Segment]
    var rows: [Row]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, title, titleEdited = "title_edited",
             createdAtMs = "created_at_ms", updatedAtMs = "updated_at_ms", segments, rows
    }

    enum DecodeError: Error { case unsupportedVersion(Int), invalid(String) }

    init(id: String, title: String, titleEdited: Bool = false, createdAtMs: Int64, updatedAtMs: Int64,
         segments: [Segment] = [], rows: [Row] = []) {
        self.id = id; self.title = title; self.titleEdited = titleEdited
        self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs; self.segments = segments; self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else { throw DecodeError.unsupportedVersion(version) }
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        titleEdited = try c.decodeIfPresent(Bool.self, forKey: .titleEdited) ?? false
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        updatedAtMs = try c.decode(Int64.self, forKey: .updatedAtMs)
        segments = try c.decode([Segment].self, forKey: .segments)
        rows = try c.decode([Row].self, forKey: .rows)
        guard Self.isValidID(id) else { throw DecodeError.invalid("id") }
        // Exports look up each row's segment; a dangling index is treated as a corrupt file.
        guard rows.allSatisfy({ segments.indices.contains($0.segment) }) else { throw DecodeError.invalid("segment") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(titleEdited, forKey: .titleEdited)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(segments, forKey: .segments)
        try c.encode(rows, forKey: .rows)
    }

    /// Lowercase UUIDs only: the id is also the file name, so nothing else may reach the file system.
    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased() && id.count == 36
    }
    static func newID() -> String { UUID().uuidString.lowercased() }
    static func nowMs(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func decode(_ data: Data) throws -> SessionFile { try JSONDecoder().decode(SessionFile.self, from: data) }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var hasContent: Bool { rows.contains { $0.kind == .text } }
}

/// `~/Library/Application Support/LocalRecorder/sessions/<id>.json`: directory 0700, files 0600, atomic writes.
/// Unreadable, corrupt or newer-version files are skipped, never deleted (except by `deleteAll`).
struct SessionStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalRecorder", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(directory: URL = SessionStore.defaultDirectory) { self.directory = directory }

    private func url(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    /// Valid sessions, most recently updated first.
    func list() -> [SessionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            load(id: String(name.dropLast(5)))
        }.sorted { $0.updatedAtMs == $1.updatedAtMs ? $0.id < $1.id : $0.updatedAtMs > $1.updatedAtMs }
    }

    func load(id: String) -> SessionFile? {
        guard SessionFile.isValidID(id), let data = try? Data(contentsOf: url(for: id)),
              let file = try? SessionFile.decode(data), file.id == id else { return nil }
        return file
    }

    func save(_ file: SessionFile) throws {
        guard SessionFile.isValidID(file.id) else { throw SessionFile.DecodeError.invalid("id") }
        try prepareDirectory()
        let data = try file.encoded()
        let target = url(for: file.id)
        let temporary = directory.appendingPathComponent(".\(file.id).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // createFile's mode is subject to the umask; make sure it is exactly 0600 before the rename publishes it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if Darwin.rename(temporary.path, target.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    @discardableResult
    func rename(id: String, title: String, nowMs: Int64 = SessionFile.nowMs()) throws -> SessionFile? {
        guard var file = load(id: id) else { return nil }
        file.title = title; file.titleEdited = true; file.updatedAtMs = max(file.updatedAtMs, nowMs)
        try save(file)
        return file
    }

    func delete(id: String) throws {
        guard SessionFile.isValidID(id) else { return }
        do { try FileManager.default.removeItem(at: url(for: id)) }
        catch CocoaError.fileNoSuchFile {}
    }

    /// Removes every session file, including ones this version cannot read.
    func deleteAll() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") || name.hasSuffix(".tmp") {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

/// Sidebar groups by last update: 今天 / 昨天 / 7 天内 / 更早.
enum SessionGroup: Int, CaseIterable, Comparable {
    case today, yesterday, week, earlier

    var title: String { ["今天", "昨天", "7 天内", "更早"][rawValue] }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// "7 天内" covers the five calendar days before yesterday (seven days including today).
    static func of(updatedAtMs: Int64, now: Date = Date(), calendar: Calendar = .current) -> SessionGroup {
        let date = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -6, to: today), date >= week { return .week }
        return .earlier
    }
}

struct SessionSummary: Identifiable, Equatable {
    var id: String
    var title: String
    var createdAtMs: Int64
    var updatedAtMs: Int64
    init(_ file: SessionFile) { id = file.id; title = file.title; createdAtMs = file.createdAtMs; updatedAtMs = file.updatedAtMs }
}

/// All session reads and writes go through here. With persistence off (or no store, as in tests) changes stay
/// in memory for this run only; existing files can still be read, exported and deleted, but nothing is written.
final class SessionLibrary {
    private let store: SessionStore?
    var persist: Bool
    private var memory: [String: SessionFile] = [:]
    private var disk: [String: SessionSummary] = [:]
    private(set) var summaries: [SessionSummary] = []

    init(store: SessionStore?, persist: Bool) {
        self.store = store; self.persist = persist
        reload()
    }

    var writesToDisk: Bool { persist && store != nil }

    func reload() {
        disk = Dictionary(uniqueKeysWithValues: (store?.list() ?? []).map { ($0.id, SessionSummary($0)) })
        publish()
    }

    private func publish() {
        var all = disk
        for (id, file) in memory { all[id] = SessionSummary(file) }
        summaries = all.values.sorted { $0.updatedAtMs == $1.updatedAtMs ? $0.id < $1.id : $0.updatedAtMs > $1.updatedAtMs }
    }

    func load(id: String) -> SessionFile? { memory[id] ?? store?.load(id: id) }
    func contains(id: String) -> Bool { memory[id] != nil || disk[id] != nil }

    func save(_ file: SessionFile) throws {
        if writesToDisk, let store {
            try store.save(file)
            memory[file.id] = nil; disk[file.id] = SessionSummary(file)
        } else { memory[file.id] = file }
        publish()
    }

    @discardableResult
    func rename(id: String, title: String) throws -> SessionFile? {
        guard var file = load(id: id) else { return nil }
        file.title = title; file.titleEdited = true; file.updatedAtMs = max(file.updatedAtMs, SessionFile.nowMs())
        try save(file)
        return file
    }

    /// Deleting is allowed with persistence off: it only removes data.
    func delete(id: String) throws {
        memory[id] = nil; disk[id] = nil
        defer { publish() }
        try store?.delete(id: id)
    }

    func deleteAll() throws {
        memory.removeAll(); disk.removeAll()
        defer { publish() }
        try store?.deleteAll()
    }
}
