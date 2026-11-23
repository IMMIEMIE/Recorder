import Foundation

@main struct DialogueTests {
    static func main() {
        let left = [DialogueUtterance(startMs: 930, source: "短句", translation: "短句", sourceLanguage: "zh"),
                    .init(startMs: 1000, source: "你好", translation: "你好", sourceLanguage: "zh"),
                    .init(startMs: 5000, source: "42", translation: "四十二", sourceLanguage: nil)]
        let right = [DialogueUtterance(startMs: 4020, source: "こんにちは", translation: "こんにちは", sourceLanguage: "ja"),
                     .init(startMs: 1010, source: "您好", translation: "こんにちは", sourceLanguage: "zh"),
                     .init(startMs: 5050, source: "42", translation: "四十二", sourceLanguage: nil)]
        let turns = DialogueTurns.align(left, right, languageA: "zh", languageB: "ja")
        precondition(turns.map(\.startMs) == [930, 1000, 4020, 5000])
        precondition(turns.map(\.speaker) == ["A", "A", "B", "unknown"])
        precondition(turns.map(\.source) == ["短句", "你好", "こんにちは", "42"])
        precondition(turns.map(\.translation) == ["", "こんにちは", "", ""])
        let disputed = DialogueTurns.align([left[0]], [.init(startMs: 950, source: "こんにちは", translation: "", sourceLanguage: "ja")],
                                          languageA: "zh", languageB: "ja")
        precondition(disputed.count == 1 && disputed[0].speaker == "unknown")
        let swapped = DialogueTurns.align(right, left, languageA: "ja", languageB: "zh")
        precondition(swapped.map(\.speaker) == ["B", "B", "A", "unknown"])
        precondition(swapped.map(\.translation) == turns.map(\.translation))
        precondition(DialogueTurns.detectLanguage("The meeting will start tomorrow morning.") == "en")
        precondition(DialogueTurns.detectLanguage("今日は駅の近くで友達と会う予定です。") == "ja")
        precondition(DialogueTurns.detectLanguage("42") == nil)
        var planned = LiveHandoffAudio(.languageSwitch), recovery = LiveHandoffAudio(.recovery)
        for n in 0..<60 {
            let audio = Data(repeating: UInt8(n), count: 3200)
            planned.append(audio)
            recovery.append(audio)
        }
        let recent = recovery.poll(nowMs: 0)!
        precondition(recent.count == 32_000 && recent.first == 50 && recent.last == 59)
        precondition(recovery.poll(nowMs: 0) == nil)
        var now: Int64 = 0
        for n in 10..<60 {
            let chunk = planned.poll(nowMs: now)!
            precondition(chunk.count == 3200 && chunk.first == UInt8(n))
            precondition(planned.poll(nowMs: now) == nil)
            now += n == 15 ? 2000 : 80
        }
        precondition(planned.poll(nowMs: now) == nil)
        print("dialogue alignment, routing, system language recognition and paced handoff passed")
    }
}
