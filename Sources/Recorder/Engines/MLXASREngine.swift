#if RECORDER_INPROCESS
import Foundation
import RecorderMLX

/// Local ASR engine for BackendCore (adapter.py Adapter): one Qwen3-ASR snapshot at a time,
/// all model work serialized on the MLX queue.
final class MLXASREngine: ASREngine {
    private var runner: Qwen3ASR?
    private var language: String?  // nil = auto-detect

    var isLoaded: Bool { runner != nil }

    func load(config: ModelConfig, path: String) async throws {
        await unload()
        let directory = URL(fileURLWithPath: path)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any] ?? [:]
        guard raw["model_type"] as? String == "qwen3_asr" else {
            // The Whisper port is still pending (spikes/HANDOFF.md, Phase 3 item 3).
            throw BackendError.value("Whisper 本地识别引擎尚未接入，请等待后续版本更新或暂时使用 Qwen3-ASR")
        }
        do {
            runner = try await MLXRuntime.run { try Qwen3ASR(directory: directory) }
        } catch {
            await unload()
            if let error = error as? Qwen3ASRError { throw BackendError.value(error.description) }
            throw error
        }
        language = config.language == "auto" ? nil : config.language
    }

    /// adapter.py warmup: half a second of silence.
    func warmup() async throws {
        _ = try await transcribe(Data(count: 16000))
    }

    func unload() async {
        runner = nil
        language = nil
        // Queued behind any in-flight step, so the freed weights' buffers are actually returned
        // (Python: gc.collect(); mx.clear_cache()).
        _ = try? await MLXRuntime.run { MLXRuntime.clearCache() }
    }

    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        guard let runner else { throw BackendError.value("识别模型未加载") }
        let language = language
        // np.frombuffer(pcm, '<i2').astype(np.float32) / 32768.0
        let samples: [Float] = pcm.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let text = try await MLXRuntime.run { runner.transcribe(samples: samples, language: language) }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return (text, elapsed)
    }
}
#endif
