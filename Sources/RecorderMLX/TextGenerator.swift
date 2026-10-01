import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// A loaded mlx-lm text model for local translation (translation.py Translator via mlx_lm.load).
/// Not thread-safe: the backend worker serializes every call.
public final class MLXTextGenerator {
    /// config.json model_type (qwen3, hunyuan_v1_dense, ...), which selects the prompt shape.
    public let architecture: String
    private let context: ModelContext
    private let stopTokenIDs: Set<Int>

    private init(architecture: String, context: ModelContext) {
        self.architecture = architecture
        self.context = context
        // mlx_lm stops on the tokenizer eos plus config/generation_config eos ids.
        var stop = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stop.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stop.insert(id) }
        }
        stopTokenIDs = stop
    }

    /// Loads weights and tokenizer from a local snapshot; never touches the network.
    public static func load(directory: URL) async throws -> MLXTextGenerator {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let context = try await LLMModelFactory.shared.load(from: directory, using: TransformersTokenizerLoader())
        return MLXTextGenerator(architecture: raw["model_type"] as? String ?? "", context: context)
    }

    /// Prepares greedy generation for chat messages. Qwen3 templates get enable_thinking=False,
    /// matching translation.py. Nothing runs until the session's first step.
    public func session(messages: [[String: String]], maxTokens: Int) throws -> MLXGenerationSession {
        let options: [String: any Sendable]? = architecture == "qwen3" ? ["enable_thinking": false] : nil
        let prompt = try context.tokenizer.applyChatTemplate(
            messages: messages.map { $0 as [String: any Sendable] }, tools: nil, additionalContext: options)
        return MLXGenerationSession(context: context, prompt: prompt, stopTokenIDs: stopTokenIDs, maxTokens: maxTokens)
    }
}

/// Pull-based generation: each step decodes at most one token, so a caller that stops pulling
/// leaves the GPU idle (the Python worker suspended its stream_generate generator the same way).
/// Dropping the session releases its KV cache.
public final class MLXGenerationSession {
    private let context: ModelContext
    private let prompt: [Int]
    private let stopTokenIDs: Set<Int>
    private let maxTokens: Int
    private var iterator: TokenIterator?
    private var tokens: [Int] = []
    private var emitted = ""
    private var finished = false

    init(context: ModelContext, prompt: [Int], stopTokenIDs: Set<Int>, maxTokens: Int) {
        self.context = context
        self.prompt = prompt
        self.stopTokenIDs = stopTokenIDs
        self.maxTokens = maxTokens
    }

    /// Advances one token and returns the cumulative translation, or nil once generation ended.
    /// The first call also prefills the prompt.
    public func step() throws -> String? {
        if finished { return nil }
        if iterator == nil {
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            iterator = try TokenIterator(input: LMInput(tokens: MLXArray(prompt.map { Int32($0) })),
                                         model: context.model, parameters: parameters)
        }
        guard let token = iterator!.next(), !stopTokenIDs.contains(token) else {
            finished = true
            iterator = nil
            // Flush a tail that was withheld as an incomplete UTF-8 sequence.
            let text = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true)
            guard text != emitted else { return nil }
            emitted = text
            return text
        }
        tokens.append(token)
        let text = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true)
        // A trailing U+FFFD means the token ended mid-character; repeat the last complete text.
        if !text.hasSuffix("\u{FFFD}") { emitted = text }
        return emitted
    }
}

/// Adapts swift-transformers tokenizers to mlx-swift-lm (the MLXHuggingFace macro expansion,
/// written out so the build needs no macro plugin or Hub client).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
