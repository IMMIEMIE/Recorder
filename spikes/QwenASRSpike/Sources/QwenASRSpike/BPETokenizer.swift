import Foundation

/// GPT-2 byte-level BPE tokenizer over vocab.json + merges.txt, plus the
/// added_tokens_decoder specials from tokenizer_config.json — enough to
/// encode Qwen3-ASR prompts and decode greedy output.
final class BPETokenizer {
    private let vocab: [String: Int]
    private let idToToken: [Int: String]
    private let mergeRanks: [String: Int]
    private let specials: [String: Int]          // special content -> id
    private let specialIds: [Int: String]        // id -> content (skip on decode)
    private let specialFlagged: Set<Int>         // ids with special=true (dropped by decode)
    private let byteEncoder: [UInt8: Character]  // raw byte -> printable unicode char
    private let byteDecoder: [Character: UInt8]

    init(modelDirectory: URL) throws {
        // vocab.json
        let vocabData = try Data(contentsOf: modelDirectory.appendingPathComponent("vocab.json"))
        guard let vocabRaw = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw RuntimeError("vocab.json 解析失败")
        }
        vocab = vocabRaw
        var idToTok = [Int: String](minimumCapacity: vocabRaw.count)
        for (tok, id) in vocabRaw { idToTok[id] = tok }
        idToToken = idToTok

        // merges.txt (skip "#version" header if present)
        let mergesText = try String(contentsOf: modelDirectory.appendingPathComponent("merges.txt"), encoding: .utf8)
        var ranks = [String: Int]()
        var rank = 0
        for line in mergesText.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            let pair = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if pair.count == 2 {
                ranks[pair[0] + " " + pair[1]] = rank
                rank += 1
            }
        }
        mergeRanks = ranks

        // added tokens from tokenizer_config.json
        var sp = [String: Int]()
        var spIds = [Int: String]()
        var flagged = Set<Int>()
        if let cfgData = try? Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer_config.json")),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
           let added = cfg["added_tokens_decoder"] as? [String: [String: Any]] {
            for (idStr, info) in added {
                if let id = Int(idStr), let content = info["content"] as? String {
                    sp[content] = id
                    spIds[id] = content
                    if (info["special"] as? Bool) == true { flagged.insert(id) }
                }
            }
        }
        specials = sp
        specialIds = spIds
        specialFlagged = flagged

        // GPT-2 bytes-to-unicode: printable bytes map to themselves, the rest
        // map to U+0100+n where n counts non-printable bytes in ascending order
        var enc = [UInt8: Character]()
        var dec = [Character: UInt8]()
        var n = 0
        for b in UInt8(0)...UInt8(255) {
            let c: Character
            switch b {
            case UInt8(33)...UInt8(126), UInt8(161)...UInt8(172), UInt8(174)...UInt8(255):
                c = Character(UnicodeScalar(b))
            default:
                c = Character(UnicodeScalar(256 + n)!)
                n += 1
            }
            enc[b] = c
            dec[c] = b
        }
        byteEncoder = enc
        byteDecoder = dec
    }

    /// debug: byte -> unicode scalar value of the mapped char
    func debugByteEncoderScalars() throws -> [String: Int] {
        var out = [String: Int]()
        for (b, c) in byteEncoder {
            out[String(b)] = Int(c.unicodeScalars.first?.value ?? 0)
        }
        return out
    }

    private let splitRegex = try! NSRegularExpression(
        pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")

    /// Split on special tokens first, then BPE each plain segment.
    func encode(_ text: String) -> [Int] {
        var ids = [Int]()
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            ids.append(contentsOf: bpeEncode(segment))
            segment = ""
        }
        var i = text.startIndex
        while i < text.endIndex {
            // longest special-token match at current position
            var matched: String? = nil
            for sp in specials.keys where !sp.isEmpty {
                if text[i...].hasPrefix(sp) && (matched == nil || sp.count > matched!.count) {
                    matched = sp
                }
            }
            if let sp = matched {
                flush()
                ids.append(specials[sp]!)
                i = text.index(i, offsetBy: sp.count)
            } else {
                segment.append(text[i])
                i = text.index(after: i)
            }
        }
        flush()
        return ids
    }

    private func bpeEncode(_ text: String) -> [Int] {
        // pre-tokenize with the GPT-2 pattern
        let ns = text as NSString
        let matches = splitRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var words = [String]()
        for m in matches {
            if let r = Range(m.range, in: text) { words.append(String(text[r])) }
        }
        var out = [Int]()
        for word in words {
            // map to unicode chars (GPT-2 byte-level: each raw byte -> printable char)
            let bytes = Array(word.utf8)
            let chars = bytes.compactMap { byteEncoder[$0] }
            var symbols = chars.map(String.init)
            while symbols.count > 1 {
                var bestRank = Int.max
                var bestIdx = -1
                for j in 0..<(symbols.count - 1) {
                    let pair = symbols[j] + " " + symbols[j + 1]
                    if let r = mergeRanks[pair], r < bestRank {
                        bestRank = r
                        bestIdx = j
                    }
                }
                if bestIdx < 0 { break }
                let merged = symbols[bestIdx] + symbols[bestIdx + 1]
                symbols.remove(at: bestIdx + 1)
                symbols[bestIdx] = merged
            }
            for s in symbols {
                if let id = vocab[s] {
                    out.append(id)
                } else {
                    fatalError("BPE 未收录 token: \(s)")
                }
            }
        }
        return out
    }

    /// Decode ids. Added tokens with special=true are dropped when skipSpecials;
    /// added-but-not-special content (e.g. <asr_text>) survives so callers can
    /// strip language prefixes, matching the Python tokenizer behavior.
    func decode(_ ids: [Int], skipSpecials: Bool = true) -> String {
        var chars = [Character]()
        for id in ids {
            if let sp = specialIds[id] {
                if skipSpecials && specialFlagged.contains(id) { continue }
                chars.append(contentsOf: sp)
                continue
            }
            guard let tok = idToToken[id] else { continue }
            for c in tok {
                if let b = byteDecoder[c] {
                    chars.append(Character(UnicodeScalar(b)))
                } else {
                    chars.append(c)
                }
            }
        }
        // chars hold raw bytes (byteDecoder maps each GPT-2 char back to one
        // byte value) — collect their scalar values directly, never re-encode
        var bytes = [UInt8]()
        for c in chars {
            if let s = c.unicodeScalars.first {
                bytes.append(UInt8(truncatingIfNeeded: s.value))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}
