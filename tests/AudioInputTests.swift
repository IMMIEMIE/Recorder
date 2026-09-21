import Foundation
import AVFoundation

final class Result: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var ended = false
    var error = ""
    func append(_ pcm: Data) { lock.lock(); data.append(pcm); lock.unlock() }
    func finish() { lock.lock(); ended = true; lock.unlock() }
    func fail(_ message: String) { lock.lock(); error = message; lock.unlock() }
    func snapshot() -> (Int, Bool, String) { lock.lock(); defer { lock.unlock() }; return (data.count / 2, ended, error) }
}
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AudioInputTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@main struct AudioInputTests {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames: AVAudioFrameCount = 14400  // Includes a short final read, not a whole 100 ms block.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.25 } }
            try file.write(from: buffer)
        }
        let input = AdditionalAudioInput(), result = Result()
        input.onPCM = { pcm, _ in result.append(pcm) }
        input.onEnd = { result.finish() }
        input.onFailure = { result.fail($0) }
        try input.startFile(url)
        for _ in 0..<200 {
            if result.snapshot().1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let complete = result.snapshot()
        try check(complete.1 && complete.2.isEmpty, "File must finish without errors")
        try check(abs(complete.0 - Int(Double(frames) * 16000 / 44100)) <= 2, "16 kHz mono sample count must include converter tail: \(complete.0)")
        input.stop()
        try check(result.snapshot().0 == complete.0, "Stop after EOF must not duplicate tail")
        let second = Result()
        input.onPCM = { pcm, _ in second.append(pcm) }
        input.onEnd = { second.finish() }
        try input.startFile(url)
        try await Task.sleep(nanoseconds: 130_000_000)
        input.stop()
        let stopped = second.snapshot()
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(second.snapshot().0 == stopped.0 && !second.snapshot().1, "Stopped file must not keep emitting or finish a later session")
        do { try input.startFile(url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).wav")); throw NSError(domain: "Missing file accepted", code: 1) }
        catch let error as NSError { try check(error.domain != "Missing file accepted", "Missing file must fail") }
        print("PASS: stereo 44.1 kHz file → mono PCM16 16 kHz, paced reading, EOF tail, stop, restart and missing file")
    }
}
