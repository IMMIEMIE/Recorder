import Compression
import Foundation
import MLX

/// Reader for NumPy .npz archives (mx.load of .npz in Python; mlx-swift only loads safetensors).
/// Used for mlx_whisper's mel_filters.npz and legacy weights.npz checkpoints. Entry sizes come
/// from the central directory: numpy writes local headers with zip64 placeholders.
enum NPZ {
    static func load(url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        func fail(_ what: String) -> Error { MLXModelError("无法读取 \(url.lastPathComponent): \(what)") }
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= data.count else { throw fail("文件截断") }
            return Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int { try u16(o) | u16(o + 2) << 16 }
        func u64(_ o: Int) throws -> Int { try u32(o) | u32(o + 4) << 32 }

        // End of central directory: last "PK\5\6" within the trailing 64 KiB comment window.
        var eocd = -1
        var position = data.count - 22
        while position >= max(0, data.count - 22 - 65_535) {
            if try u32(position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw fail("不是 zip 格式") }
        var entries = try u16(eocd + 10)
        var directory = try u32(eocd + 16)
        if entries == 0xFFFF || directory == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard try u32(locator) == 0x0706_4B50 else { throw fail("缺少 zip64 目录") }
            let record = try u64(locator + 8)
            guard try u32(record) == 0x0606_4B50 else { throw fail("zip64 目录损坏") }
            entries = try u64(record + 32)
            directory = try u64(record + 48)
        }

        var arrays: [String: MLXArray] = [:]
        var cursor = directory
        for _ in 0..<entries {
            guard try u32(cursor) == 0x0201_4B50 else { throw fail("中央目录损坏") }
            let method = try u16(cursor + 10)
            var compressed = try u32(cursor + 20)
            var size = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            var local = try u32(cursor + 42)
            let nameStart = data.startIndex + cursor + 46
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            // Zip64 extra field: 64-bit values replace the saturated 32-bit ones, in this order.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = try u16(extra), length = try u16(extra + 2)
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = try u64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = try u64(field); field += 8 }
                    if local == 0xFFFF_FFFF { local = try u64(field) }
                }
                extra += 4 + length
            }
            cursor = extraEnd + commentLength

            guard try u32(local) == 0x0403_4B50 else { throw fail("本地文件头损坏") }
            let start = try local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= data.count else { throw fail("文件截断") }
            let raw = data[(data.startIndex + start)..<(data.startIndex + start + compressed)]
            let payload: Data
            switch method {
            case 0:
                payload = raw
            case 8:
                payload = try inflate(raw, size: size, fail: fail)
            default:
                throw fail("不支持的压缩方式 \(method)")
            }
            let key = name.hasSuffix(".npy") ? String(name.dropLast(4)) : name
            arrays[key] = try npy(payload, fail: fail)
        }
        return arrays
    }

    /// Raw DEFLATE (zip method 8); COMPRESSION_ZLIB is headerless RFC 1951.
    private static func inflate(_ raw: Data, size: Int, fail: (String) -> Error) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw fail("解压失败") }
        return output
    }

    /// .npy v1-v3: magic, version, little-endian header length, Python-dict header, C-order data.
    private static func npy(_ payload: Data, fail: (String) -> Error) throws -> MLXArray {
        let bytes = [UInt8](payload.prefix(12))
        guard bytes.count >= 10, bytes[0] == 0x93, Array(bytes[1...5]) == Array("NUMPY".utf8) else {
            throw fail("npy 格式错误")
        }
        let headerLength: Int
        let headerStart: Int
        if bytes[6] == 1 {
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
            headerStart = 10
        } else {
            guard bytes.count >= 12 else { throw fail("npy 格式错误") }
            headerLength = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            headerStart = 12
        }
        let base = payload.startIndex
        let header = String(decoding: payload[(base + headerStart)..<(base + headerStart + headerLength)], as: UTF8.self)
        func field(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
                  let range = Range(match.range(at: 1), in: header) else { return nil }
            return String(header[range])
        }
        guard let descr = field("'descr':\\s*'([^']*)'"), let shapeText = field("'shape':\\s*\\(([^)]*)\\)") else {
            throw fail("npy 头信息错误")
        }
        if field("'fortran_order':\\s*(True|False)") == "True" { throw fail("不支持 Fortran 顺序数组") }
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let body = payload[(base + headerStart + headerLength)...]
        switch descr {
        case "<f2": return MLXArray(Data(body), shape, type: Float16.self)
        case "<f4": return MLXArray(Data(body), shape, type: Float.self)
        case "<f8": return MLXArray(Data(body), shape, type: Double.self).asType(.float32)
        case "<i4": return MLXArray(Data(body), shape, type: Int32.self)
        case "<i8": return MLXArray(Data(body), shape, type: Int64.self)
        case "<u4": return MLXArray(Data(body), shape, type: UInt32.self)
        case "|u1": return MLXArray(Data(body), shape, type: UInt8.self)
        case "|b1": return MLXArray(Data(body), shape, type: Bool.self)
        default: throw fail("不支持的数据类型 \(descr)")
        }
    }
}
