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
    private let byteEncoder: [Character: Character]  // byte-as-unicode -> printable char
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
        if let cfgData = try? Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer_config.json")),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
           let added = cfg["added_tokens_decoder"] as? [String: [String: Any]] {
            for (idStr, info) in added {
                if let id = Int(idStr), let content = info["content"] as? String {
                    sp[content] = id
                    spIds[id] = content
                }
            }
        }
        specials = sp
        specialIds = spIds

        // GPT-2 bytes-to-unicode
        var enc = [Character: Character]()
        var dec = [Character: UInt8]()
        func byteChar(_ b: UInt8) -> Character {
            let scalars: [UInt8]
            switch b {
            case UInt8(33)...UInt8(126), UInt8(161)...UInt8(172), UInt8(174)...UInt8(255):
                scalars = [b]
            default:
                let n = 256 + Int(b)
                scalars = [UInt8(n >> 6 | 0b11000000), UInt8(n & 0x3F | 0b10000000)]
            }
            return Character(String(decoding: scalars, as: UTF8.self))
        }
        for b in UInt8(0)...UInt8(255) {
            let c = byteChar(b)
            enc[c] = Character(UnicodeScalar(b))
            dec[c] = b
        }
        byteEncoder = enc
        byteDecoder = dec
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
            // map to unicode chars
            let bytes = Array(word.utf8)
            let chars = bytes.compactMap { byteEncoder[Character(UnicodeScalar($0))] }
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

    /// Decode ids; skip special (added) tokens when skipSpecials.
    func decode(_ ids: [Int], skipSpecials: Bool = true) -> String {
        var chars = [Character]()
        for id in ids {
            if let sp = specialIds[id] {
                if !skipSpecials { chars.append(contentsOf: sp) }
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
        var bytes = [UInt8]()
        for c in chars {
            if let s = c.unicodeScalars.first, s.isASCII {
                bytes.append(UInt8(s.value))
            } else {
                bytes.append(contentsOf: String(c).utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}
