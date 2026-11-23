import Foundation

struct Failure: Error, CustomStringConvertible { let description: String }
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    checks += 1
    if !condition() { throw Failure(description: message) }
}
func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

@main struct SessionTests {
    static let fixtures = URL(fileURLWithPath: "tests/fixtures/session_export")
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    static func main() throws {
        do {
            try exports()
            try referenceCases()
            try store()
            try groups()
            print("session tests passed (\(checks) checks)")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func exports() throws {
        let session = try SessionFile.decode(Data(contentsOf: fixtures.appendingPathComponent("session.json")))
        try check(session.segments.count == 2 && session.rows.count == 9 && session.rows[4].kind == .break, "fixture decodes, unknown field ignored")
        try check(session.segments[0].targetLanguage == "zh" && session.segments[1].mode == "live_translate", "segment fields")
        for content in SessionExportContent.allCases {
            for format in SessionExportFormat.allCases {
                let name = "\(content.rawValue).\(format.fileExtension)"
                let expected = try Data(contentsOf: fixtures.appendingPathComponent("expected/\(name)"))
                let actual = Data(SessionExport.render(session, format: format, content: content, zone: shanghai).utf8)
                if actual != expected {
                    FileHandle.standardError.write(Data("--- \(name) actual:\n".utf8) + actual)
                }
                try check(actual == expected, "export \(name) matches the fixture byte for byte")
            }
        }
        let dialogueDirectory = fixtures.appendingPathComponent("dialogue")
        let dialogue = try SessionFile.decode(Data(contentsOf: dialogueDirectory.appendingPathComponent("session.json")))
        let roundTrip = try SessionFile.decode(dialogue.encoded())
        try check(roundTrip == dialogue && dialogue.rows[2].languages == .init(target: "ja", source: "zh", speaker: "A"),
                  "dialogue metadata round trips at row level")
        for content in SessionExportContent.allCases {
            for format in SessionExportFormat.allCases {
                let name = "\(content.rawValue).\(format.fileExtension)"
                let expected = try Data(contentsOf: dialogueDirectory.appendingPathComponent("expected/\(name)"))
                let output = SessionExport.render(dialogue, format: format, content: content, zone: shanghai)
                try check(Data(output.utf8) == expected, "dialogue export " + name)
            }
        }
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected/meta.json"))) as! [String: Any]
        try check(meta["zone"] as? String == "Asia/Shanghai", "fixture zone")
        let names = meta["file_names"] as! [String: String]
        try check(SessionExport.fileName(session, format: .txt, zone: shanghai) == names["txt"], "txt file name")
        try check(SessionExport.fileName(session, format: .markdown, zone: shanghai) == names["md"], "md file name")
        for (index, item) in (meta["default_titles"] as! [[String: Any]]).enumerated() {
            let rows = try JSONDecoder().decode([SessionFile.Row].self, from: JSONSerialization.data(withJSONObject: item["rows"]!))
            let title = SessionExport.defaultTitle(createdAtMs: (item["created_at_ms"] as! NSNumber).int64Value, rows: rows, zone: shanghai)
            try check(title == item["expected"] as? String, "default title \(index): \(title)")
        }
        // An empty session has only the header.
        let empty = SessionFile(id: SessionFile.newID(), title: "", createdAtMs: session.createdAtMs, updatedAtMs: session.createdAtMs)
        try check(SessionExport.render(empty, format: .txt, content: .bilingual, zone: shanghai) == "\n2026-11-23 14:05\n", "empty txt")
        try check(SessionExport.render(empty, format: .markdown, content: .source, zone: shanghai) == "# \n\n2026-11-23 14:05\n", "empty md")
        try check(SessionExport.fileName(empty, format: .txt, zone: shanghai) == "声笺 2026-11-23 14-05.txt", "untitled file name")
    }

    /// Cases computed by scripts/make_session_export_fixtures.py in scripts/test_sessions.sh.
    static func referenceCases() throws {
        guard let path = ProcessInfo.processInfo.environment["RECORDER_SESSION_CASES"] else {
            throw Failure(description: "RECORDER_SESSION_CASES is not set; run scripts/test_sessions.sh")
        }
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: [[String]]]
        for pair in cases["clean"]! { try check(SessionExport.clean(pair[0]) == pair[1], "clean \(pair[0].debugDescription)") }
        for pair in cases["md_escape"]! {
            try check(SessionExport.markdownEscape(SessionExport.clean(pair[0])) == pair[1], "markdown escape \(pair[0].debugDescription) → \(pair[1])")
        }
        let created: Int64 = 1795413900000
        for pair in cases["file_names"]! {
            let file = SessionFile(id: SessionFile.newID(), title: pair[0], createdAtMs: created, updatedAtMs: created)
            try check(SessionExport.fileName(file, format: .txt, zone: shanghai) == pair[1], "file name \(pair[0].debugDescription)")
        }
        for pair in cases["titles"]! {
            let rows = [SessionFile.Row(segment: 0, offsetMs: 0, source: pair[0], translation: "")]
            try check(SessionExport.defaultTitle(createdAtMs: created, rows: rows, zone: shanghai) == pair[1], "title \(pair[0].debugDescription)")
        }
    }

    static func store() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        try check(store.list().isEmpty, "missing directory lists nothing")

        let fixture = try SessionFile.decode(Data(contentsOf: fixtures.appendingPathComponent("session.json")))
        try store.save(fixture)
        try check(mode(store.directory.path) == 0o700, "directory is 0700")
        let path = store.directory.appendingPathComponent(fixture.id + ".json").path
        try check(mode(path) == 0o600, "file is 0600")
        try check(store.load(id: fixture.id) == fixture, "round trip")
        let json = try String(contentsOfFile: path, encoding: .utf8)
        try check(json.contains("\"schema_version\" : 1") && json.contains("\"title_edited\" : true"), "schema fields written")

        var open = SessionFile(id: SessionFile.newID(), title: "t", createdAtMs: 1000, updatedAtMs: 2000,
                               segments: [.init(startedAtMs: 1000, targetLanguage: nil, mode: "local_asr")])
        try store.save(open)
        let openJSON = try String(contentsOf: store.directory.appendingPathComponent(open.id + ".json"), encoding: .utf8)
        try check(openJSON.contains("\"ended_at_ms\" : null") && openJSON.contains("\"target_language\" : null"), "nulls are explicit")
        open.rows.append(.init(segment: 0, offsetMs: 500, source: "你好", translation: ""))
        open.updatedAtMs = 3000
        try store.save(open)
        try check(store.load(id: open.id) == open, "overwrite in place")
        try check(store.list().map(\.id) == [fixture.id, open.id], "list sorted by last update, newest first")

        // Skipped, never deleted: corrupt JSON, a newer schema, a dangling segment, an id/file mismatch, a non-UUID name.
        let future = SessionFile.newID(), corrupt = SessionFile.newID(), dangling = SessionFile.newID(), mismatch = SessionFile.newID()
        var futureObject = try JSONSerialization.jsonObject(with: open.encoded()) as! [String: Any]
        futureObject["schema_version"] = 2; futureObject["id"] = future
        var danglingObject = try JSONSerialization.jsonObject(with: open.encoded()) as! [String: Any]
        danglingObject["id"] = dangling; danglingObject["rows"] = [["segment": 3, "kind": "text", "offset_ms": 0, "source": "x", "translation": ""]]
        let writes: [(String, Data)] = [
            (future, try JSONSerialization.data(withJSONObject: futureObject)),
            (corrupt, Data("{\"schema_version\": 1, \"id\": ".utf8)),
            (dangling, try JSONSerialization.data(withJSONObject: danglingObject)),
            (mismatch, try open.encoded()),
            ("notes", Data("{}".utf8)),
        ]
        for (name, data) in writes { try data.write(to: store.directory.appendingPathComponent(name + ".json")) }
        try check(store.list().map(\.id) == [fixture.id, open.id], "unreadable files are skipped")
        try check(store.load(id: future) == nil && store.load(id: mismatch) == nil, "future and mismatched files do not load")
        for (name, _) in writes {
            try check(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name + ".json").path), "\(name) is kept")
        }
        try check(store.load(id: "../escape") == nil && store.load(id: fixture.id.uppercased()) == nil, "only lowercase UUID ids")

        let renamed = try store.rename(id: open.id, title: "新标题", nowMs: 1_900_000_000_000)
        try check(renamed?.title == "新标题" && renamed?.titleEdited == true && store.load(id: open.id)?.updatedAtMs == 1_900_000_000_000, "rename")
        try check(store.list().first?.id == open.id, "rename moves the session up")
        try store.delete(id: open.id)
        try store.delete(id: open.id)
        try check(store.load(id: open.id) == nil && store.list().map(\.id) == [fixture.id], "delete is idempotent")
        try store.deleteAll()
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        try check(left.isEmpty, "delete all removes every session file: \(left)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
        try check(leftovers.isEmpty, "no temporary files")
    }

    static func groups() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = shanghai
        let now = Date(timeIntervalSince1970: 1795413900) // 2026-11-23 14:05 +08:00
        func ms(_ text: String) -> Int64 {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = shanghai; formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return SessionFile.nowMs(formatter.date(from: text)!)
        }
        let cases: [(String, SessionGroup)] = [
            ("2026-11-23 00:00", .today), ("2026-11-23 13:00", .today), ("2026-11-22 23:59", .yesterday),
            ("2026-11-22 00:00", .yesterday), ("2026-11-21 23:59", .week), ("2026-11-17 00:00", .week),
            ("2026-11-16 23:59", .earlier),
        ]
        for (text, group) in cases {
            try check(SessionGroup.of(updatedAtMs: ms(text), now: now, calendar: calendar) == group, "group of \(text)")
        }
    }
}
