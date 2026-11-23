import Foundation

enum SessionExportFormat: String, CaseIterable, Identifiable {
    case txt, markdown
    var id: String { rawValue }
    var fileExtension: String { self == .txt ? "txt" : "md" }
    var title: String { self == .txt ? "纯文本（TXT）" : "Markdown" }
}

enum SessionExportContent: String, CaseIterable, Identifiable {
    case bilingual, source, translation
    var id: String { rawValue }
    var title: String { ["bilingual": "双语", "source": "仅原文", "translation": "仅译文"][rawValue]! }
}

/// The export format of docs/SESSIONS.md. `scripts/make_session_export_fixtures.py` is the reference
/// implementation; this port works on Unicode scalars (code points) so lengths, trimming and the
/// CR/LF rules match Python's `str` exactly. Times are formatted in the given zone.
enum SessionExport {
    static let breakMarker = "连接中断，此处内容可能有缺失"

    private enum Entry { case marker(String), row([(translation: Bool, text: String)]) }

    // MARK: Text rules

    /// Python's `str.isspace()` set, which `str.strip()` uses.
    private static let pythonSpaces: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    private static func strip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, pythonSpaces.contains(scalars[start].value) { start += 1 }
        while end > start, pythonSpaces.contains(scalars[end - 1].value) { end -= 1 }
        return Array(scalars[start..<end])
    }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView(); view.append(contentsOf: scalars); return String(view)
    }

    /// One line: `\r\n`, `\r` and `\n` each become one space, then surrounding whitespace is trimmed.
    static func clean(_ text: String) -> String { string(strip(cleanScalars(text))) }

    private static func cleanScalars(_ text: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previousCR { previousCR = false; continue }
            previousCR = scalar == "\r"
            out.append(scalar == "\r" || scalar == "\n" ? " " : scalar)
        }
        return out
    }

    private static func prefix(_ text: String, codePoints: Int) -> String { string(text.unicodeScalars.prefix(codePoints)) }

    private static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter
    }

    static func stamp(_ ms: Int64, _ pattern: String = "yyyy-MM-dd HH:mm", zone: TimeZone) -> String {
        formatter(pattern, zone).string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: Titles and file names

    /// Used until the user renames a session: time plus the first 20 code points of the first source text.
    static func defaultTitle(createdAtMs: Int64, rows: [SessionFile.Row], zone: TimeZone = .current) -> String {
        let first = rows.lazy.filter { $0.kind == .text }.map { clean($0.source) }.first { !$0.isEmpty } ?? ""
        return stamp(createdAtMs, "MM-dd HH:mm", zone: zone) + " " + (first.isEmpty ? "新会话" : prefix(first, codePoints: 20))
    }

    static func fileName(_ session: SessionFile, format: SessionExportFormat, zone: TimeZone = .current) -> String {
        let forbidden = Set("/\\:*?\"<>|".unicodeScalars)
        let replaced = string(session.title.unicodeScalars.map { forbidden.contains($0) || $0.value < 0x20 || $0.value == 0x7F ? "_" : $0 })
        let title = string(strip(Array(clean(replaced).unicodeScalars.prefix(50))))
        let date = stamp(session.createdAtMs, "yyyy-MM-dd HH-mm", zone: zone)
        return title.isEmpty ? "声笺 \(date).\(format.fileExtension)" : "声笺 \(date) \(title).\(format.fileExtension)"
    }

    // MARK: Rendering

    private static func entries(_ session: SessionFile, _ content: SessionExportContent, _ zone: TimeZone) -> [Entry] {
        var out: [Entry] = []
        var previousSegment: Int?
        for row in session.rows {
            if let previousSegment, row.segment != previousSegment, session.segments.indices.contains(row.segment) {
                out.append(.marker("继续录制 " + stamp(session.segments[row.segment].startedAtMs, zone: zone)))
            }
            previousSegment = row.segment
            if row.kind == .break { out.append(.marker(breakMarker)); continue }
            let source = clean(row.source), translation = clean(row.translation)
            var parts: [(translation: Bool, text: String)] = []
            if content != .translation && !source.isEmpty { parts.append((false, source)) }
            if content != .source && !translation.isEmpty { parts.append((true, translation)) }
            if !parts.isEmpty { out.append(.row(parts)) }
        }
        return out
    }

    static func render(_ session: SessionFile, format: SessionExportFormat, content: SessionExportContent, zone: TimeZone = .current) -> String {
        let blocks: [String] = entries(session, content, zone).map { entry in
            switch (entry, format) {
            case (.marker(let value), .txt): return "【\(value)】"
            case (.marker(let value), .markdown): return "*【\(value)】*"
            case (.row(let parts), .txt): return parts.map(\.text).joined(separator: "\n")
            case (.row(let parts), .markdown):
                // Bilingual exports set the translation in bold; single-language exports are plain.
                return parts.map { part in
                    content == .bilingual && part.translation ? "**\(markdownEscape(part.text))**" : markdownEscape(part.text)
                }.joined(separator: "  \n")
            }
        }
        let created = stamp(session.createdAtMs, zone: zone)
        let head = format == .txt ? "\(clean(session.title))\n\(created)\n" : "# \(markdownEscape(clean(session.title)))\n\n\(created)\n"
        return head + (blocks.isEmpty ? "" : "\n" + blocks.joined(separator: "\n\n") + "\n")
    }

    static func markdownEscape(_ text: String) -> String {
        let special = Set("\\`*_[]<>#|~".unicodeScalars)
        var escaped: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if special.contains(scalar) { escaped.append("\\") }
            escaped.append(scalar)
        }
        if let first = escaped.first, first == "-" || first == "+" { escaped.insert("\\", at: 0) }
        // Python's `\d` matches any Unicode decimal digit (category Nd).
        let digits = escaped.prefix { $0.properties.generalCategory == .decimalNumber }.count
        if digits > 0, digits < escaped.count, escaped[digits] == "." { escaped.insert("\\", at: digits) }
        return string(escaped)
    }
}
