#if RECORDER_INPROCESS
import Foundation
import RecorderMLX

/// Local translation engine for BackendCore (translation.py Translator).
final class MLXTranslatorEngine: TranslatorEngine {
    private var generator: MLXTextGenerator?
    private(set) var modelID = ""

    var isLoaded: Bool { generator != nil }

    func load(config: TranslationConfig, path: String) async throws {
        await unload()
        do {
            generator = try await MLXTextGenerator.load(directory: URL(fileURLWithPath: path))
            modelID = config.modelID
        } catch {
            await unload()
            throw error
        }
    }

    func warmup() async throws {
        for try await _ in stream("Good morning.", target: "简体中文", context: []) {}
    }

    func unload() async {
        generator = nil
        modelID = ""
        _ = try? await MLXRuntime.run { MLXRuntime.clearCache() }
    }

    /// Yields the cumulative translation, one token per pull. BackendCore stops pulling while ASR
    /// jobs are queued, which leaves the GPU to them; dropping the iterator releases the KV cache.
    func stream(_ text: String, target: String, context: [(String, String)]) -> AsyncThrowingStream<String, Error> {
        guard let generator else {
            return AsyncThrowingStream { $0.finish(throwing: BackendError.value("翻译模型未加载")) }
        }
        let messages = TranslationText.buildMessages(architecture: generator.architecture, text: text,
                                                     target: target, context: context)
        let maxTokens = TranslationText.maxTokens(text)
        let state = GenerationState()
        return AsyncThrowingStream(unfolding: {
            try await MLXRuntime.run {
                if state.session == nil {
                    state.session = try generator.session(messages: messages, maxTokens: maxTokens)
                }
                return try state.session?.step()
            }
        })
    }
}

/// Holds the lazily created session; only touched on the MLX queue.
private final class GenerationState: @unchecked Sendable {
    var session: MLXGenerationSession?
}
#endif
