import Foundation

@main
struct SharedBackendTests {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "tests/shared/backend-cases.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for item in root["sentence_cases"] as! [[String: Any]] {
            guard sentenceComplete(item["text"] as! String) == item["complete"] as! Bool else { throw BackendError.value("共享句末样例失败: \(item)") }
        }
        for item in root["segment_cases"] as! [[String: Any]] {
            let config = try ModelConfig.parse(item["config"] as! [String: Any])
            var jobs: [SegmentJob] = []
            let segmenter = Segmenter(config: config) { jobs.append($0) }
            for action in item["actions"] as! [[String: Any]] {
                if let frames = action["frames"] as? Int {
                    for _ in 0..<frames { try segmenter.feed(Data(repeating: 0, count: 640), action["voiced"] as! Bool) }
                }
                if let feedback = action["feedback"] as? String { segmenter.acceptPreview(item: jobs.last(where: { !$0.final })!, text: feedback) }
                if action["flush"] as? Bool == true { segmenter.flush() }
            }
            let finals = jobs.filter { $0.final }
            let actual = finals.map { [$0.startSample, $0.endSample] }
            guard actual == item["finals"] as! [[Int]], finals.allSatisfy({ !$0.forcedCut }) else { throw BackendError.value("共享分段样例失败: \(item["name"]!) \(actual)") }
            print("PASS: shared \(item["name"]!)")
        }
        print("ALL SHARED BACKEND CHECKS PASSED")
    }
}
