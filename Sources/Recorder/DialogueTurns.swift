import Foundation
import NaturalLanguage

/// Finalized text from one lane, with its onset on the common capture clock.
struct DialogueUtterance {
    let startMs: Int64
    let source: String
    let translation: String
    let sourceLanguage: String?
}

struct DialogueTurn: Equatable {
    let startMs: Int64
    let speaker: String
    let source: String
    let sourceLanguage: String?
    let translation: String
    let targetLanguage: String?
}

enum DialogueTurns {
    /// Gradually extend the settled window; start a new one whenever the A/B language pair changes.
    static func align(_ a: [DialogueUtterance], _ b: [DialogueUtterance], languageA: String, languageB: String) -> [DialogueTurn] {
        precondition(languageA != languageB)
        let left = a.sorted { $0.startMs < $1.startMs }
        let right = b.sorted { $0.startMs < $1.startMs }
        var i = 0, j = 0
        var turns: [DialogueTurn] = []
        while i < left.count || j < right.count {
            let x = i < left.count ? left[i] : nil
            let y = j < right.count ? right[j] : nil
            let takeLeft = y == nil || (x != nil && x!.startMs <= y!.startMs)
            let first = takeLeft ? x! : y!
            let other = takeLeft ? y : x
            let next = takeLeft ? left.dropFirst(i + 1).first : right.dropFirst(j + 1).first
            let match = other.map { other in
                let distance = other.startMs - first.startMs
                return distance <= 250 && (next.map { abs($0.startMs - other.startMs) >= distance } ?? true)
            } ?? false
            let fromA = takeLeft || match ? x : nil
            let fromB = !takeLeft || match ? y : nil
            let languages = Set([fromA?.sourceLanguage, fromB?.sourceLanguage].compactMap { $0 })
            let language = languages.count == 1 ? languages.first : nil
            let speaker = language == languageA ? "A" : language == languageB ? "B" : "unknown"
            let own = speaker == "B" ? fromB : fromA
            let source = [own, fromA, fromB].compactMap { $0?.source }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let receiving = speaker == "A" ? fromB : speaker == "B" ? fromA : nil
            let target = speaker == "A" ? languageB : speaker == "B" ? languageA : nil
            turns.append(.init(startMs: first.startMs, speaker: speaker, source: source, sourceLanguage: language,
                               translation: receiving?.translation ?? "", targetLanguage: target))
            if fromA != nil { i += 1 }
            if fromB != nil { j += 1 }
        }
        return turns
    }

    static func detectLanguage(_ source: String) -> String? {
        guard source.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        return best.key.rawValue.components(separatedBy: "-").first
    }
}
