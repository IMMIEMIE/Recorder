import AVFoundation
import Foundation
import RecorderBackend
import RecorderMLX

// Explicit verification of the model layer and the whole in-process backend with real models,
// never used by the app. Run it through scripts/verify_inprocess.sh, which builds it and the Metal
// kernels (scripts/build_metallib.sh).
//
//   RecorderVerify asr --model <snapshot> [--language auto|Chinese|...] [--assets assets/whisper] [--output file.json] audio...
//     (Qwen3-ASR or MLX Whisper, chosen by config.json model_type; --assets only matters for Whisper)
//   RecorderVerify translate --model <snapshot> [--target 简体中文] [--output file.json] text...
//   RecorderVerify pipeline [--models models] [--asr <owner/model|snapshot>] [--translator <owner/model>|none]
//                           [--switch <owner/model|snapshot>] [--language auto] [--endpoint smart|fixed]
//                           [--assets assets/whisper] [--output file.json] [fixture.aiff...]
//     (paced PCM through BackendCore: the former verify_pipeline.py, verify_translation.py and
//      verify_switching.py, see Pipeline.swift)
// Common: --metallib <path/to/mlx.metallib>

func translate(_ generator: MLXTextGenerator, _ text: String, target: String) throws -> (text: String, firstTokenMS: Double, tokens: Int) {
    let session = try generator.session(messages: TranslationText.buildMessages(architecture: generator.architecture, text: text,
                                                                               target: target, context: []),
                                        maxTokens: TranslationText.maxTokens(text))
    let start = monotonic()
    var first = 0.0
    var steps = 0
    var result = ""
    while let cumulative = try session.step() {
        if steps == 0 { first = (monotonic() - start) * 1000 }
        steps += 1
        result = cumulative
    }
    return (result.trimmingCharacters(in: .whitespacesAndNewlines), first, steps)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["asr", "translate", "pipeline"].contains(command) else {
    print("用法: RecorderVerify asr|translate --model <snapshot> [选项] 输入... | RecorderVerify pipeline [选项] [fixture...]")
    exit(2)
}
arguments.removeFirst()
var options: [String: String] = [:]
var inputs: [String] = []
while !arguments.isEmpty {
    let item = arguments.removeFirst()
    if item.hasPrefix("--"), !arguments.isEmpty {
        options[String(item.dropFirst(2))] = arguments.removeFirst()
    } else {
        inputs.append(item)
    }
}
MLXRuntime.configure(metallib: options["metallib"].map { URL(fileURLWithPath: $0) })
var host = utsname()
uname(&host)
let machine = withUnsafeBytes(of: &host.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
if command == "pipeline" {
    do {
        let failed = try await runPipeline(options: options, fixtures: inputs, machine: machine)
        exit(failed ? 1 : 0)
    } catch {
        print("错误: \(error)")
        exit(1)
    }
}
guard let modelPath = options["model"] else {
    print("缺少 --model <snapshot>")
    exit(2)
}
let snapshot = URL(fileURLWithPath: modelPath)

do {
    if command == "asr" {
        let language = options["language"].flatMap { $0 == "auto" ? nil : $0 }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("config.json"))) as? [String: Any] ?? [:]
        let transcribe: ([Float]) -> String
        var start = monotonic()
        if config["model_type"] as? String == "whisper" {
            // adapter.py WHISPER_LANGUAGES; Whisper codes pass through unchanged.
            let codes = ["Chinese": "zh", "English": "en", "Cantonese": "yue", "Japanese": "ja", "Korean": "ko"]
            let code = language.map { codes[$0] ?? $0 }
            let assets = URL(fileURLWithPath: options["assets"] ?? "assets/whisper")
            let model = try MLXRuntime.sync { try Whisper(directory: snapshot, assets: assets) }
            transcribe = { samples in MLXRuntime.sync { model.transcribe(samples: samples, language: code) } }
        } else {
            let model = try MLXRuntime.sync { try Qwen3ASR(directory: snapshot) }
            transcribe = { samples in MLXRuntime.sync { model.transcribe(samples: samples, language: language) } }
        }
        let load = monotonic() - start
        start = monotonic()
        _ = transcribe([Float](repeating: 0, count: 8000))
        let warmup = monotonic() - start
        var results: [[String: Any]] = []
        for path in inputs {
            let samples = try loadPCM16Samples(path)
            start = monotonic()
            let text = transcribe(samples)
            results.append(["file": URL(fileURLWithPath: path).lastPathComponent, "audio_seconds": Double(samples.count) / 16000,
                            "elapsed_ms": (monotonic() - start) * 1000, "text": text])
        }
        try writeReport(["platform": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": machine,
                         "model_path": modelPath, "revision": snapshot.lastPathComponent, "language": language ?? "auto",
                         "model_type": config["model_type"] as? String ?? "",
                         "load_seconds": load, "warmup_seconds": warmup, "mlx_peak_bytes": MLXRuntime.peakMemory,
                         "implementation": "mlx-swift", "results": results],
                        to: options["output"] ?? "docs/model-verification-swift.json")
    } else {
        let target = options["target"] ?? "简体中文"
        var start = monotonic()
        let generator = try await MLXTextGenerator.load(directory: snapshot)
        let load = monotonic() - start
        start = monotonic()
        _ = try MLXRuntime.sync { try translate(generator, "Good morning.", target: "简体中文") }
        let warmup = monotonic() - start
        var results: [[String: Any]] = []
        for text in inputs {
            start = monotonic()
            let result = try MLXRuntime.sync { try translate(generator, text, target: target) }
            let elapsed = monotonic() - start
            results.append(["source": text, "text": result.text, "first_token_ms": result.firstTokenMS,
                            "tokens": result.tokens, "elapsed_ms": elapsed * 1000,
                            "tokens_per_second": elapsed > 0 ? Double(result.tokens) / elapsed : 0])
        }
        try writeReport(["platform": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": machine,
                         "model_path": modelPath, "revision": snapshot.lastPathComponent, "model_type": generator.architecture,
                         "target_language": target, "load_seconds": load, "warmup_seconds": warmup,
                         "mlx_peak_bytes": MLXRuntime.peakMemory, "implementation": "mlx-swift", "results": results],
                        to: options["output"] ?? "docs/translation-verification-swift.json")
    }
} catch {
    print("错误: \(error)")
    exit(1)
}
