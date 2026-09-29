import Foundation

/// GPT-2 byte-level BPE over vocab.json + merges.txt plus the added tokens from
/// tokenizer_config.json: enough to encode Qwen3-ASR prompts and decode greedy output.
final class ASRTokenizer {
    private let vocab: [String: Int]
    private let idToToken: [Int: String]
    private let mergeRanks: [String: Int]
    private let added: [String: Int]           // added-token content -> id
    private let addedIDs: [Int: String]
    private let specialIDs: Set<Int>           // special=true ids, dropped by decode
    private let byteEncoder: [UInt8: Character]
    private let byteDecoder: [Character: UInt8]
    let eosToken: String?

    private let splitRegex = try! NSRegularExpression(
        pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")

    init(directory: URL) throws {
        let vocabData = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        guard let vocabRaw = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw Qwen3ASRError("vocab.json 解析失败")
        }
        vocab = vocabRaw
        var idToTok = [Int: String](minimumCapacity: vocabRaw.count)
        for (tok, id) in vocabRaw { idToTok[id] = tok }
        idToToken = idToTok

        let mergesText = try String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8)
        var ranks = [String: Int]()
        var rank = 0
        for line in mergesText.split(separator: "\n") where !line.hasPrefix("#") {
            let pair = line.split(separator: " ", omittingEmptySubsequences: false)
            if pair.count == 2 {
                ranks[String(pair[0]) + " " + String(pair[1])] = rank
                rank += 1
            }
        }
        mergeRanks = ranks

        var addedTokens = [String: Int]()
        var addedByID = [Int: String]()
        var special = Set<Int>()
        let configData = try Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        for (idString, info) in config["added_tokens_decoder"] as? [String: [String: Any]] ?? [:] {
            guard let id = Int(idString), let content = info["content"] as? String else { continue }
            addedTokens[content] = id
            addedByID[id] = content
            if (info["special"] as? Bool) == true { special.insert(id) }
        }
        added = addedTokens
        addedIDs = addedByID
        specialIDs = special
        eosToken = (config["eos_token"] as? String) ?? ((config["eos_token"] as? [String: Any])?["content"] as? String)

        // bytes_to_unicode: printable bytes map to themselves, the rest to U+0100 + n where n
        // counts the non-printable bytes in ascending order.
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

    func tokenID(_ content: String) -> Int? { added[content] ?? vocab[content] }

    /// Splits on added tokens first (longest match), then BPE-encodes each plain run.
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
            var matched: String?
            for token in added.keys where !token.isEmpty && text[i...].hasPrefix(token) {
                if matched == nil || token.count > matched!.count { matched = token }
            }
            if let token = matched {
                flush()
                ids.append(added[token]!)
                i = text.index(i, offsetBy: token.count)
            } else {
                segment.append(text[i])
                i = text.index(after: i)
            }
        }
        flush()
        return ids
    }

    private func bpeEncode(_ text: String) -> [Int] {
        let ns = text as NSString
        var out = [Int]()
        for match in splitRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { continue }
            var symbols = text[range].utf8.compactMap { byteEncoder[$0] }.map(String.init)
            while symbols.count > 1 {
                var bestRank = Int.max
                var bestIndex = -1
                for j in 0..<(symbols.count - 1) {
                    if let r = mergeRanks[symbols[j] + " " + symbols[j + 1]], r < bestRank {
                        bestRank = r
                        bestIndex = j
                    }
                }
                if bestIndex < 0 { break }
                symbols[bestIndex] += symbols[bestIndex + 1]
                symbols.remove(at: bestIndex + 1)
            }
            // Every single byte is in a byte-level vocabulary, so lookups only fail on a corrupt vocab.
            out.append(contentsOf: symbols.compactMap { vocab[$0] })
        }
        return out
    }

    /// decode(skip_special_tokens=True): special added tokens are dropped, while added tokens
    /// with special=false (such as <asr_text>) survive so the language prefix can be stripped.
    func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        for id in ids {
            if let content = addedIDs[id] {
                if specialIDs.contains(id) { continue }
                bytes.append(contentsOf: Array(content.utf8))
                continue
            }
            guard let token = idToToken[id] else { continue }
            for c in token {
                if let b = byteDecoder[c] {
                    bytes.append(b)
                } else {
                    bytes.append(contentsOf: Array(String(c).utf8))
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct Qwen3ASRError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}
