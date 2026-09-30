import Foundation
import RecorderBackend
import RecorderMLX

/// Local ASR engine for BackendCore (adapter.py Adapter): one Qwen3-ASR or Whisper snapshot at a
/// time, all model work serialized on the MLX queue.
public final class MLXASREngine: ASREngine {
    /// adapter.py WHISPER_LANGUAGES (nil = detect).
    static let whisperLanguages: [String: String?] = [
        "auto": nil, "Chinese": "zh", "English": "en", "Cantonese": "yue", "Japanese": "ja", "Korean": "ko",
    ]

    private enum Runner {
        case qwen(Qwen3ASR)
        case whisper(Whisper)
    }

    private var runner: Runner?
    private var language: String?  // model-specific language name or code; nil = auto-detect

    public init() {}

    public var isLoaded: Bool { runner != nil }

    public func load(config: ModelConfig, path: String) async throws {
        await unload()
        let directory = URL(fileURLWithPath: path)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any] ?? [:]
        let architecture = raw["model_type"] as? String
        do {
            switch architecture {
            case "whisper":
                guard let assets = ASRValidation.whisperAssets else {
                    throw BackendError.value("Whisper 运行环境缺失，请重新安装应用")
                }
                runner = .whisper(try await MLXRuntime.run { try Whisper(directory: directory, assets: assets) })
                language = Self.whisperLanguages[config.language] ?? nil
            case "qwen3_asr":
                runner = .qwen(try await MLXRuntime.run { try Qwen3ASR(directory: directory) })
                language = config.language == "auto" ? nil : config.language
            default:
                throw BackendError.value("仅支持 MLX Qwen3-ASR 和 MLX Whisper 架构")
            }
        } catch {
            await unload()
            if let error = error as? MLXModelError { throw BackendError.value(error.description) }
            throw error
        }
    }

    /// adapter.py warmup: half a second of silence.
    public func warmup() async throws {
        _ = try await transcribe(Data(count: 16000))
    }

    public func unload() async {
        runner = nil
        language = nil
        // Queued behind any in-flight step, so the freed weights' buffers are actually returned
        // (Python: gc.collect(); mx.clear_cache(); the mlx_whisper ModelHolder is cleared too).
        _ = try? await MLXRuntime.run { MLXRuntime.clearCache() }
    }

    public func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        guard let runner else { throw BackendError.value("识别模型未加载") }
        let language = language
        // np.frombuffer(pcm, '<i2').astype(np.float32) / 32768.0
        let samples: [Float] = pcm.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let text: String
        switch runner {
        case .qwen(let model):
            text = try await MLXRuntime.run { model.transcribe(samples: samples, language: language) }
        case .whisper(let model):
            text = try await MLXRuntime.run { model.transcribe(samples: samples, language: language) }
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return (text, elapsed)
    }
}
