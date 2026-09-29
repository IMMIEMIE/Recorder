import Foundation
import AVFoundation
import MLX
import MLXNN

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
    // read exactly file.length frames: over-reading at EOF makes AVAudioFile.read throw nilError
    let totalFrames = Int(file.length)
    var readSoFar = 0
    while readSoFar < totalFrames {
        let toRead = min(inCapacity, AVAudioFrameCount(totalFrames - readSoFar))
        try file.read(into: inBuffer, frameCount: toRead)
        readSoFar += Int(inBuffer.frameLength)
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
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
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
    let moduleParameters = ModuleParameters(
        item: NestedItem.unflattened(weights.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
    try model.update(parameters: moduleParameters, verify: [.noUnusedKeys])
    eval(model.parameters())
    print(String(format: "模型加载: %.1fs, %d 个权重", -tLoad.timeIntervalSinceNow, weights.count))

    let tokenizer = try BPETokenizer(modelDirectory: snapshot)
    print("tokenizer ok")

    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        let bytes = try tokenizer.debugByteEncoderScalars()
        try? JSONSerialization.data(withJSONObject: bytes).write(to: URL(fileURLWithPath: "/tmp/swift_byte_map.json"))
        print("byte map dumped")
    }

    let samples = try loadAudio16kMono(audioPath)
    print("音频: \(samples.count) 样本 (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")

    let tStart = Date()
    let frontend = MelFrontend()
    let features = frontend.logMel(samples)
    let validFrames = frontend.validFrames(sampleCount: samples.count)
    let numAudioTokens = AudioEncoder.featOutLength(validFrames)
    print("有效帧: \(validFrames), 音频 token: \(numAudioTokens)")

    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        eval(features)
        let f4 = features[0, 0..<4, 0..<4].asArray(Float.self)
        print("feat[0,:4,:4] =", f4)
        print("feat mean:", features.mean().item(Float.self))
        print("samples[:6] =", Array(samples.prefix(6)))
        samples.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_samples.bin"))
        }
        // full dump for python-side diff: (128, 3000) float32
        let flat = features[0].asArray(Float.self)
        flat.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_mel.bin"))
        }
        print("mel dumped: \(flat.count) floats")
        // filterbank (128*201) + window (400) for python-side diff
        frontend.filterBank.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_fb.bin"))
        }
        frontend.window.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_win.bin"))
        }
        print("fb/window dumped")
    }

    let audioFeatures = model.audioTower(features, validFrames: validFrames)
    eval(audioFeatures)

    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        let featFlat = audioFeatures.asArray(Float.self)
        print("audioFeat shape: \(audioFeatures.dim(0)) x \(audioFeatures.dim(1))")
        print("audioFeat mean:", featFlat.reduce(0, +) / Float(featFlat.count))
        print("audioFeat frame0[:6] =", Array(featFlat.prefix(6)))
        featFlat.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_audio_feat.bin"))
        }
    }

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

    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        let ids = inputIds[0].asArray(Int32.self)
        print("ids first 12:", Array(ids.prefix(12)))
        print("ids last 8:", Array(ids.suffix(8)))
    }

    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        let cache: [KVCache?] = (0..<model.text.numHiddenLayers).map { _ in KVCache() }
        let embeds = model.buildInputsEmbeds(inputIds: inputIds, audioFeatures: audioFeatures)
        let seqLen = embeds.dim(1)
        _ = model.model(inputsEmbeds: embeds[0..., 0..<(seqLen - 1), 0...], cache: cache)
        let h = model.model(inputsEmbeds: embeds[0..., (seqLen - 1)...(seqLen - 1), 0...], cache: cache)
        let last = model.model.embedTokens.asLinear(h[0, 0, 0...])
        eval(last)
        let arr = last.asArray(Float.self)
        let top5 = arr.enumerated().sorted { $0.element > $1.element }.prefix(5)
        print("swift first token:", top5.first?.offset ?? -1,
              "top5:", top5.map { ($0.offset, $0.element) })
        arr.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_first_logits.bin"))
        }
    }

    let tokens = model.generate(audioFeatures: audioFeatures, inputIds: inputIds, maxTokens: 512)
    if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
        print("swift first 10:", Array(tokens.prefix(10)))
    }
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
    print(String(format: "GPU 峰值内存: %.0f MB", Double(Memory.peakMemory) / 1_048_576))
} catch {
    print("错误: \(error) [\(type(of: error))]")
    exit(1)
}
