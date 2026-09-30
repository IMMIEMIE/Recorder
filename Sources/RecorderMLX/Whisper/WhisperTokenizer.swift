import Foundation

/// mlx_whisper tokenizer.py: tiktoken byte-level BPE over gpt2/multilingual.tiktoken plus
/// Whisper's appended special tokens. Only what transcription needs: encode for the suppression
/// lists, decode, and the special token ids.
final class WhisperTokenizer {
    /// tokenizer.LANGUAGES key order; language token ids follow it.
    static let languageCodes = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id", "hi",
        "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg", "lt", "la",
        "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy",
        "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be",
        "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]

    private let ranks: [Data: Int]
    private let decoder: [Int: Data]
    private let specialText: [Int: String]
    private let splitRegex = try! NSRegularExpression(
        pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")

    let multilingual: Bool
    let languages: [String]
    let eot: Int
    let sot: Int
    let translate: Int
    let transcribe: Int
    let sotLM: Int
    let sotPrev: Int
    let noSpeech: Int
    let noTimestamps: Int
    let timestampBegin: Int

    /// assets: directory holding gpt2.tiktoken / multilingual.tiktoken (mlx_whisper/assets).
    init(assets: URL, multilingual: Bool, numLanguages: Int) throws {
        let name = multilingual ? "multilingual" : "gpt2"
        let text = try String(contentsOf: assets.appendingPathComponent("\(name).tiktoken"), encoding: .utf8)
        var ranks = [Data: Int]()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let token = Data(base64Encoded: String(parts[0])), let rank = Int(parts[1]) else { continue }
            ranks[token] = rank
        }
        guard !ranks.isEmpty else { throw MLXModelError("Whisper 离线辅助资源缺失: \(name).tiktoken") }
        self.ranks = ranks
        var decoder = [Int: Data](minimumCapacity: ranks.count)
        for (token, rank) in ranks { decoder[rank] = token }
        self.decoder = decoder

        // get_encoding: specials are numbered from len(ranks) in this order.
        let languages = Array(Self.languageCodes.prefix(numLanguages))
        var specials = ["<|endoftext|>", "<|startoftranscript|>"] + languages.map { "<|\($0)|>" }
        specials += ["<|translate|>", "<|transcribe|>", "<|startoflm|>", "<|startofprev|>", "<|nospeech|>", "<|notimestamps|>"]
        specials += (0...1500).map { String(format: "<|%.2f|>", Double($0) * 0.02) }
        var specialText = [Int: String]()
        var specialID = [String: Int]()
        for (offset, token) in specials.enumerated() {
            specialText[ranks.count + offset] = token
            specialID[token] = ranks.count + offset
        }
        self.specialText = specialText
        self.multilingual = multilingual
        self.languages = languages
        eot = specialID["<|endoftext|>"]!
        sot = specialID["<|startoftranscript|>"]!
        translate = specialID["<|translate|>"]!
        transcribe = specialID["<|transcribe|>"]!
        sotLM = specialID["<|startoflm|>"]!
        sotPrev = specialID["<|startofprev|>"]!
        noSpeech = specialID["<|nospeech|>"]!
        noTimestamps = specialID["<|notimestamps|>"]!
        timestampBegin = specialID["<|0.00|>"]!
    }

    /// Language token ids in LANGUAGES order (all_language_tokens).
    var languageTokens: [Int] { languages.indices.map { sot + 1 + $0 } }

    /// sot_sequence: multilingual models carry language and task tokens; English-only ones only sot.
    func sotSequence(language: String?) -> [Int] {
        guard multilingual else { return [sot] }
        let index = languages.firstIndex(of: language ?? "en") ?? 0
        return [sot, sot + 1 + index, transcribe]
    }

    /// tiktoken encode of ordinary text (no special tokens).
    func encode(_ text: String) -> [Int] {
        var out = [Int]()
        for match in splitRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += bytePairEncode(Data(text[range].utf8))
        }
        return out
    }

    private func bytePairEncode(_ piece: Data) -> [Int] {
        if let rank = ranks[piece] { return [rank] }
        var parts = piece.map { Data([$0]) }
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(parts.count - 1) {
                if let rank = ranks[parts[i] + parts[i + 1]], best == nil || rank < best!.rank {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            parts[best.index] += parts[best.index + 1]
            parts.remove(at: best.index + 1)
        }
        return parts.compactMap { ranks[$0] }
    }

    /// Tokenizer.decode: timestamp tokens are dropped, other specials decode to their text,
    /// invalid UTF-8 becomes U+FFFD (tiktoken errors="replace").
    func decode(_ tokens: [Int]) -> String {
        var bytes = Data()
        for token in tokens where token < timestampBegin {
            if let data = decoder[token] {
                bytes += data
            } else if let text = specialText[token] {
                bytes += Data(text.utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// non_speech_tokens: speaker tags and sound annotations to suppress, keeping basic punctuation.
    /// For multilingual.tiktoken this yields the familiar list starting [1, 2, 7, 8, 9, 10, 14, 25, ...]
    /// and ending [..., 47425, 49870, 50254].
    var nonSpeechTokens: [Int] {
        var symbols = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map { String($0) }
        symbols += "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let miscellaneous = Set("♩♪♫♬♭♮♯".map { String($0) })
        var result = Set<Int>()
        if let dash = encode(" -").first { result.insert(dash) }
        if let quote = encode(" '").first { result.insert(quote) }
        for symbol in symbols + miscellaneous.sorted() {
            for tokens in [encode(symbol), encode(" " + symbol)] where tokens.count == 1 || miscellaneous.contains(symbol) {
                if let first = tokens.first { result.insert(first) }
            }
        }
        return result.sorted()
    }
}
