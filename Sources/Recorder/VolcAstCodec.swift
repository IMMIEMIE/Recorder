import Foundation

/// Minimal, zero-dependency Protobuf wire codec for Volcengine / BytePlus Seed-LiveInterpret 2.0
/// (`wss://openspeech.bytedance.com/api/v4/ast/v2/translate`).
///
/// Field numbers and enum values are verified against the official ByteDance `.proto` definitions
/// (`common/events.proto`, `common/rpcmeta.proto`, `products/understanding/base/au_base.proto`,
/// `products/understanding/ast/ast_service.proto`).
enum VolcAstEventType: Int32 {
    case none = 0
    case connectionStarted = 50
    case connectionFailed = 51
    case connectionFinished = 52
    case startSession = 100
    case cancelSession = 101
    case finishSession = 102
    case sessionStarted = 150
    case sessionCanceled = 151
    case sessionFinished = 152
    case sessionFailed = 153
    case usageResponse = 154
    case taskRequest = 200
    case updateConfig = 201
    case audioMuted = 250
    case ttsSentenceStart = 350
    case ttsSentenceEnd = 351
    case ttsResponse = 352
    case ttsEnded = 359
    case sourceSubtitleStart = 650
    case sourceSubtitleResponse = 651
    case sourceSubtitleEnd = 652
    case translationSubtitleStart = 653
    case translationSubtitleResponse = 654
    case translationSubtitleEnd = 655
}

enum VolcAstWireError: Error, Equatable {
    case truncated
    case invalidVarint
    case invalidWireType(UInt8)
    case depthExceeded
    case invalidLength
}

struct VolcAstProtoWriter {
    private(set) var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeTag(field: UInt32, wireType: UInt8) {
        writeVarint(UInt64((field << 3) | UInt32(wireType)))
    }

    mutating func writeInt32(field: UInt32, value: Int32, omitDefault: Bool = true) {
        if omitDefault && value == 0 { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func writeBool(field: UInt32, value: Bool, omitDefault: Bool = true) {
        if omitDefault && !value { return }
        writeTag(field: field, wireType: 0)
        writeVarint(value ? 1 : 0)
    }

    mutating func writeString(field: UInt32, value: String, omitDefault: Bool = true) {
        if omitDefault && value.isEmpty { return }
        writeBytes(field: field, value: Data(value.utf8), omitDefault: false)
    }

    mutating func writeBytes(field: UInt32, value: Data, omitDefault: Bool = true) {
        if omitDefault && value.isEmpty { return }
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeMessage(field: UInt32, encoded: Data, omitEmpty: Bool = false) {
        if omitEmpty && encoded.isEmpty { return }
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(encoded.count))
        data.append(encoded)
    }
}

struct VolcAstProtoReader {
    private let bytes: [UInt8]
    private var offset: Int
    private let end: Int
    private let depth: Int
    private static let maxDepth = 16

    init(_ data: Data, depth: Int = 0) {
        self.bytes = [UInt8](data)
        self.offset = 0
        self.end = self.bytes.count
        self.depth = depth
    }

    private init(bytes: [UInt8], start: Int, end: Int, depth: Int) {
        self.bytes = bytes
        self.offset = start
        self.end = end
        self.depth = depth
    }

    var hasMore: Bool { offset < end }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let byte = bytes[offset]
            offset += 1
            if shift == 63 && byte > 1 { throw VolcAstWireError.invalidVarint }
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { throw VolcAstWireError.invalidVarint }
        }
        throw VolcAstWireError.truncated
    }

    mutating func readTag() throws -> (field: UInt32, wireType: UInt8) {
        let raw = try readVarint()
        let field = UInt32(truncatingIfNeeded: raw >> 3)
        guard field != 0 else { throw VolcAstWireError.invalidVarint }
        return (field, UInt8(raw & 0x07))
    }

    mutating func readInt32() throws -> Int32 {
        Int32(truncatingIfNeeded: try readVarint())
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    mutating func readBytes() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(end - offset) else { throw VolcAstWireError.invalidLength }
        let count = Int(length)
        let slice = Data(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func readString() throws -> String {
        let data = try readBytes()
        return String(decoding: data, as: UTF8.self)
    }

    mutating func readSubmessage() throws -> VolcAstProtoReader {
        guard depth < Self.maxDepth else { throw VolcAstWireError.depthExceeded }
        let length = try readVarint()
        guard length <= UInt64(end - offset) else { throw VolcAstWireError.invalidLength }
        let start = offset
        offset += Int(length)
        return VolcAstProtoReader(bytes: bytes, start: start, end: offset, depth: depth + 1)
    }

    mutating func skip(wireType: UInt8) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard end - offset >= 8 else { throw VolcAstWireError.truncated }
            offset += 8
        case 2:
            let length = try readVarint()
            guard length <= UInt64(end - offset) else { throw VolcAstWireError.invalidLength }
            offset += Int(length)
        case 5:
            guard end - offset >= 4 else { throw VolcAstWireError.truncated }
            offset += 4
        default:
            throw VolcAstWireError.invalidWireType(wireType)
        }
    }
}

// MARK: - AST 2.0 Protobuf Messages

struct VolcAstRequestMeta: Equatable {
    var endpoint = ""
    var appKey = ""
    var appID = ""
    var resourceID = ""
    var connectionID = ""
    var sessionID = ""
    var sequence: Int32 = 0

    func encode() -> Data {
        var w = VolcAstProtoWriter()
        w.writeString(field: 1, value: endpoint)
        w.writeString(field: 2, value: appKey)
        w.writeString(field: 3, value: appID)
        w.writeString(field: 4, value: resourceID)
        w.writeString(field: 5, value: connectionID)
        w.writeString(field: 6, value: sessionID)
        w.writeInt32(field: 7, value: sequence)
        return w.data
    }
}

struct VolcAstResponseMeta: Equatable {
    var sessionID = ""
    var sequence: Int32 = 0
    var statusCode: Int32 = 0
    var message = ""

    static func decode(from reader: inout VolcAstProtoReader) throws -> VolcAstResponseMeta {
        var meta = VolcAstResponseMeta()
        while reader.hasMore {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2): meta.sessionID = try reader.readString()
            case (2, 0): meta.sequence = try reader.readInt32()
            case (3, 0): meta.statusCode = try reader.readInt32()
            case (4, 2): meta.message = try reader.readString()
            default: try reader.skip(wireType: wire)
            }
        }
        return meta
    }
}

struct VolcAstUser: Equatable {
    var uid = ""
    var did = ""

    func encode() -> Data {
        var w = VolcAstProtoWriter()
        w.writeString(field: 1, value: uid)
        w.writeString(field: 2, value: did)
        return w.data
    }
}

struct VolcAstAudio: Equatable {
    var format = ""
    var codec = ""
    var rate: Int32 = 0
    var bits: Int32 = 0
    var channel: Int32 = 0
    var binaryData = Data()

    func encode() -> Data {
        var w = VolcAstProtoWriter()
        w.writeString(field: 4, value: format)
        w.writeString(field: 5, value: codec)
        w.writeInt32(field: 7, value: rate)
        w.writeInt32(field: 8, value: bits)
        w.writeInt32(field: 9, value: channel)
        w.writeBytes(field: 14, value: binaryData)
        return w.data
    }
}

struct VolcAstReqParams: Equatable {
    var mode = ""
    var sourceLanguage = ""
    var targetLanguage = ""
    var speakerID = ""

    func encode() -> Data {
        var w = VolcAstProtoWriter()
        w.writeString(field: 1, value: mode)
        w.writeString(field: 2, value: sourceLanguage)
        w.writeString(field: 3, value: targetLanguage)
        w.writeString(field: 4, value: speakerID)
        return w.data
    }
}

struct VolcAstTranslateRequest: Equatable {
    var requestMeta: VolcAstRequestMeta?
    var event: VolcAstEventType = .none
    var user: VolcAstUser?
    var sourceAudio: VolcAstAudio?
    var targetAudio: VolcAstAudio?
    var request: VolcAstReqParams?
    var denoise: Bool?

    func encode() -> Data {
        var w = VolcAstProtoWriter()
        if let meta = requestMeta { w.writeMessage(field: 1, encoded: meta.encode()) }
        w.writeInt32(field: 2, value: event.rawValue)
        if let user { w.writeMessage(field: 3, encoded: user.encode()) }
        if let sourceAudio { w.writeMessage(field: 4, encoded: sourceAudio.encode()) }
        if let targetAudio { w.writeMessage(field: 5, encoded: targetAudio.encode()) }
        if let request { w.writeMessage(field: 6, encoded: request.encode()) }
        if let denoise { w.writeBool(field: 7, value: denoise, omitDefault: false) }
        return w.data
    }
}

struct VolcAstTranslateResponse: Equatable {
    var responseMeta: VolcAstResponseMeta?
    var eventRaw: Int32 = 0
    var data = Data()
    var text = ""
    var startTime: Int32 = 0
    var endTime: Int32 = 0
    var spkChg = false
    var mutedDurationMS: Int32 = 0

    var event: VolcAstEventType? { VolcAstEventType(rawValue: eventRaw) }

    static let statusSuccess: Int32 = 20_000_000
    static let statusOkAlt: Int32 = 21_000

    var hasErrorStatus: Bool {
        guard let code = responseMeta?.statusCode, code != 0 else { return false }
        return code != Self.statusSuccess && code != Self.statusOkAlt
    }

    static func decode(_ data: Data) throws -> VolcAstTranslateResponse {
        var reader = VolcAstProtoReader(data)
        var response = VolcAstTranslateResponse()
        while reader.hasMore {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                var sub = try reader.readSubmessage()
                response.responseMeta = try VolcAstResponseMeta.decode(from: &sub)
            case (2, 0): response.eventRaw = try reader.readInt32()
            case (3, 2): response.data = try reader.readBytes()
            case (4, 2): response.text = try reader.readString()
            case (5, 0): response.startTime = try reader.readInt32()
            case (6, 0): response.endTime = try reader.readInt32()
            case (7, 0): response.spkChg = try reader.readBool()
            case (8, 0): response.mutedDurationMS = try reader.readInt32()
            default: try reader.skip(wireType: wire)
            }
        }
        return response
    }
}

/// Appends pure incremental AST 2.0 subtitle deltas (`SourceSubtitleResponse` / `TranslationSubtitleResponse`).
///
/// Verified against live AST 2.0 wire captures: `Response` (651 / 654) carries incremental text pieces
/// while `End` (652 / 655) carries the authoritative complete sentence (or empty string to finalize the
/// accumulated pieces). Verbatim concatenation preserves speaker repetitions (e.g. `"yes "` + `"yes"`)
/// and short-prefix tokens (e.g. `"to "` + `"today"`, `"to"` + `"day"`) without destructive prefix guessing.
enum VolcAstSubtitleMerger {
    static func append(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        return existing + incoming
    }
}
