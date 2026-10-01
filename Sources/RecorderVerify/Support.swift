import AVFoundation
import Foundation

struct VerifyError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func monotonic() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Decodes any AVFoundation-readable file to 16 kHz mono, then quantizes to PCM16 exactly like
/// the former verify_model.py (clip * 32767 -> int16) and rescales like the engines (/ 32768).
func loadPCM16Samples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let source = file.processingFormat
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: source, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16384) else {
        throw VerifyError("无法创建音频转换器: \(path)")
    }
    var samples = [Float]()
    func drain(_ block: @escaping AVAudioConverterInputBlock, capacity: AVAudioFrameCount) throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: block)
        if let error { throw VerifyError("音频重采样失败: \(error.localizedDescription)") }
        if status == .error { throw VerifyError("音频重采样失败") }
        if let data = output.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        }
    }
    // Read exactly file.length frames: reading past EOF makes AVAudioFile.read throw.
    var remaining = Int(file.length)
    while remaining > 0 {
        try file.read(into: input, frameCount: min(16384, AVAudioFrameCount(remaining)))
        if input.frameLength == 0 { break }
        remaining -= Int(input.frameLength)
        var fed = false
        try drain({ _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }, capacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / source.sampleRate + 64))
    }
    try drain({ _, status in status.pointee = .endOfStream; return nil }, capacity: 8192)
    return samples.map { Float(Int16(max(-1, min(1, $0)) * 32767)) / 32768 }
}

/// PCM16 little-endian bytes of samples produced by loadPCM16Samples (exact multiples of 1/32768).
func pcm16Data(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let value = Int16(max(-32768, min(32767, (sample * 32768).rounded())))
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

func writeReport(_ report: [String: Any], to output: String) throws {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: output))
    print(String(decoding: data, as: UTF8.self))
}
