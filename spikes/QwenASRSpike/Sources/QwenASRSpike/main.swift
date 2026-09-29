import Foundation
import AVFoundation
import MLX

// Phase 0 spike: port Qwen3-ASR inference from mlx_audio (Python) to mlx-swift.
// Usage: QwenASRSpike <snapshot-dir> <audio-file> [language]
//   language: auto | Chinese | English | Cantonese | Japanese | Korean

func loadAudio16kMono(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let srcFormat = file.processingFormat
    guard let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    else { throw RuntimeError("无法创建目标音频格式") }
    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
    else { throw RuntimeError("无法创建音频转换器") }

    var samples = [Float]()
    let inCapacity = AVAudioFrameCount(16384)
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inCapacity)
    else { throw RuntimeError("无法创建音频缓冲") }
    while true {
        try file.read(into: inBuffer, frameCount: inCapacity)
        if inBuffer.frameLength == 0 { break }
        let ratio = 16000.0 / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity)
        else { throw RuntimeError("无法创建输出缓冲") }
        var fed = false
        var error: NSError? = nil
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if let error { throw RuntimeError("音频重采样失败: \(error.localizedDescription)") }
        if status == .error { throw RuntimeError("音频重采样失败") }
        if let data = outBuffer.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
        }
    }
    // EOF flush of the converter
    if let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 8192) {
        var error: NSError? = nil
        let status = converter.convert(to: outBuffer, endOfStream: true, error: &error)
        if status != .error, let data = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
        }
    }
    return samples
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: \(args[0]) <snapshot-dir> <audio-file> [language]")
    exit(2)
}
let snapshot = URL(fileURLWithPath: args[1])
let audioPath = args[2]
let language = args.count > 3 ? args[3] : "auto"
let langName: String? = language == "auto" ? nil : language

do {
    let tLoad = Date()
    let model = Qwen3ASRModel()
    let weights = try WeightLoader.load(snapshot: snapshot)
    model.update(parameters: weights, verify: [.none])
    eval(model.parameters())
    print(String(format: "模型加载: %.1fs, %d 个权重", -tLoad.timeIntervalSinceNow, weights.count))

    let tokenizer = try BPETokenizer(modelDirectory: snapshot)

    let samples = try loadAudio16kMono(audioPath)
    print("音频: \(samples.count) 样本 (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")

    let tStart = Date()
    let frontend = MelFrontend()
    let features = frontend.logMel(samples)
    let validFrames = frontend.validFrames(sampleCount: samples.count)
    let numAudioTokens = AudioEncoder.featOutLength(validFrames)
    print("有效帧: \(validFrames), 音频 token: \(numAudioTokens)")

    let audioFeatures = model.audioTower(features, validFrames: validFrames)
    eval(audioFeatures)

    // prompt: _build_prompt
    let assistantPrefix = langName.map { "language \($0)<asr_text>" } ?? ""
    let prompt =
        "<|im_start|>system\n<|im_end|>\n"
        + "<|im_start|>user\n<|audio_start|>"
        + String(repeating: "<|audio_pad|>", count: numAudioTokens)
        + "<|audio_end|><|im_end|>\n"
        + "<|im_start|>assistant\n\(assistantPrefix)"
    let inputIds = MLXArray(tokenizer.encode(prompt)).reshaped(1, -1)
    print("prompt tokens: \(inputIds.dim(1))")

    let tokens = model.generate(audioFeatures: audioFeatures, inputIds: inputIds, maxTokens: 512)
    let elapsed = -tStart.timeIntervalSinceNow

    var text = tokenizer.decode(tokens)
    // auto mode: strip "language X<asr_text>" prefix if present
    if langName == nil {
        if let asrRange = text.range(of: "<asr_text>") {
            text = String(text[asrRange.upperBound...])
        }
    }
    print("---- 转写结果 ----")
    print(text)
    print(String(format: "总耗时: %.2fs (含特征提取), 生成 %d token", elapsed, tokens.count))
} catch {
    print("错误: \(error)")
    exit(1)
}
