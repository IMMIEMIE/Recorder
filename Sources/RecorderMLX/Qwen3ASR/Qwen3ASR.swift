import Foundation
import MLX
import MLXNN

/// A loaded Qwen3-ASR snapshot: model, tokenizer and log-mel frontend.
/// Mirrors mlx_audio's load_model + Qwen3ASRModel.generate as adapter.py calls them.
/// Not thread-safe: callers run every method on the MLX queue (MLXRuntime.run).
public final class Qwen3ASR {
    private let model: Qwen3ASRModel
    private let tokenizer: ASRTokenizer
    private let frontend: MelFrontend
    private let eosTokenIDs: Set<Int>

    /// Loads config, weights and tokenizer from a snapshot directory; heavy, run on the MLX queue.
    public init(directory: URL) throws {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let configuration = Qwen3ASRConfiguration(json: raw)
        let model = Qwen3ASRModel(configuration)
        let weights = try Qwen3ASR.loadWeights(directory: directory, tied: configuration.text.tieWordEmbeddings)
        if let q = configuration.quantization {
            // mlx_audio quantizes the text decoder only (model_quant_predicate skips audio_tower).
            let filter: (String, Module) -> (groupSize: Int, bits: Int, mode: QuantizationMode)? = { path, _ in
                guard !path.hasPrefix("audio_tower"), weights["\(path).scales"] != nil else { return nil }
                return (groupSize: q.groupSize, bits: q.bits, mode: q.mode)
            }
            quantize(model: model, filter: filter)
        }
        // Weights must be nested: a flat dotted-key ModuleParameters updates nothing and leaves the
        // model on random weights. noUnusedKeys turns any naming mismatch into a load error.
        let parameters = ModuleParameters(item: NestedItem.unflattened(weights.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        try model.update(parameters: parameters, verify: [.noUnusedKeys])
        eval(model.parameters())

        self.model = model
        tokenizer = try ASRTokenizer(directory: directory)
        frontend = MelFrontend(nMels: configuration.audio.numMelBins)
        // _eos_token_ids: tokenizer eos plus <|im_end|>/<|endoftext|>, Qwen defaults as fallback.
        var eos = Set<Int>()
        for token in [tokenizer.eosToken, "<|im_end|>", "<|endoftext|>"].compactMap({ $0 }) {
            if let id = tokenizer.tokenID(token) { eos.insert(id) }
        }
        eosTokenIDs = eos.isEmpty ? [151_645, 151_643] : eos
    }

    /// Model.sanitize: strip "thinker.", drop lm_head (tied), and move unconverted HF conv weights
    /// to MLX's channels-last layout.
    private static func loadWeights(directory: URL, tied: Bool) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".safetensors") }.sorted()
        guard !files.isEmpty else { throw Qwen3ASRError("离线资源缺失: *.safetensors 权重") }
        var raw = [String: MLXArray]()
        for file in files {
            for (key, value) in try loadArrays(url: directory.appendingPathComponent(file)) { raw[key] = value }
        }
        let formatted = !raw.keys.contains { $0.hasPrefix("thinker.") }
        var weights = [String: MLXArray]()
        for (key, value) in raw {
            let name = key.hasPrefix("thinker.") ? String(key.dropFirst("thinker.".count)) : key
            if name == "lm_head.weight" && tied { continue }
            if !formatted && name.contains("conv2d") && name.contains("weight") && value.ndim == 4 {
                weights[name] = value.transposed(0, 2, 3, 1)
            } else {
                weights[name] = value
            }
        }
        return weights
    }

    /// Transcribes 16 kHz mono float samples. `language` nil means auto-detect; otherwise one of
    /// the model's languages (e.g. "Chinese"). Returns text without surrounding whitespace.
    public func transcribe(samples input: [Float], language: String?, maxTokens: Int = 512) -> String {
        // split_audio_into_chunks: inputs shorter than min_chunk_duration (1 s) are zero-padded.
        // Backend segments never exceed max_segment_seconds (≤ 25 s), far below the 20 min
        // chunk_duration, so the audio always forms a single chunk.
        var samples = input
        if samples.count < MelFrontend.sampleRate {
            samples += [Float](repeating: 0, count: MelFrontend.sampleRate - samples.count)
        }
        let features = frontend.logMel(samples)
        let validFrames = MelFrontend.validFrames(sampleCount: samples.count)
        let audioTokens = AudioEncoder.featOutLength(validFrames)
        let audioFeatures = model.audioTower(features, validFrames: validFrames)
        eval(audioFeatures)

        let inputIDs = tokenizer.encode(prompt(audioTokens: audioTokens, language: language))
        let tokens = model.generate(audioFeatures: audioFeatures, inputIDs: inputIDs,
                                    eosTokenIDs: eosTokenIDs, maxTokens: maxTokens)
        var text = tokenizer.decode(tokens)
        if language == nil {
            text = Qwen3ASR.stripLanguage(text)
        }
        MLXRuntime.clearCache()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// _build_prompt: a fixed language is forced through the assistant prefix.
    private func prompt(audioTokens: Int, language: String?) -> String {
        var prefix = ""
        if let language {
            let supported = model.configuration.supportLanguages
            let name = supported.first { $0.lowercased() == language.lowercased() } ?? language
            prefix = "language \(name)<asr_text>"
        }
        return "<|im_start|>system\n<|im_end|>\n"
            + "<|im_start|>user\n<|audio_start|>"
            + String(repeating: "<|audio_pad|>", count: audioTokens)
            + "<|audio_end|><|im_end|>\n"
            + "<|im_start|>assistant\n\(prefix)"
    }

    /// extract_language: auto mode output reads "language X<asr_text>text".
    static func stripLanguage(_ text: String) -> String {
        guard text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") else { return text }
        return String(text[marker.upperBound...])
    }
}
