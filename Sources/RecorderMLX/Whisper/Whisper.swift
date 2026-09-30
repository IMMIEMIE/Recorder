import Foundation
import MLX
import MLXNN

/// A loaded MLX Whisper snapshot, transcribing the way adapter.py calls mlx_whisper.transcribe:
/// fp16, temperature 0.0 (no fallback), condition_on_previous_text=False, word_timestamps=False,
/// sample_len=224, default no_speech_threshold 0.6 / logprob_threshold -1.0, timestamps on.
/// Not thread-safe: callers run every method on the MLX queue (MLXRuntime.run).
public final class Whisper {
    static let sampleRate = 16_000
    static let nFFT = 400
    static let hop = 160
    static let nFrames = 3000  // 30 s window
    static let nSamples = 480_000
    static let sampleLength = 224
    static let noSpeechThreshold = 0.6
    static let logprobThreshold = -1.0

    private let model: WhisperModel
    private let tokenizer: WhisperTokenizer
    private let filters: MLXArray   // (nMels, 201)
    private let window: MLXArray    // periodic hann(400), float32
    private let dtype: DType = .float16
    private let suppressTokens: [Int]
    private let blankTokens: [Int]

    /// directory: snapshot with config.json + weights.safetensors|weights.npz.
    /// assets: mlx_whisper assets (mel_filters.npz, gpt2/multilingual.tiktoken).
    public init(directory: URL, assets: URL) throws {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let dims = try WhisperDimensions(json: raw)

        // load_models.load_model: weights as stored; dtype only affects the computed
        // positional encoding and mask.
        let safetensors = directory.appendingPathComponent("weights.safetensors")
        let weights: [String: MLXArray]
        if FileManager.default.fileExists(atPath: safetensors.path) {
            weights = try loadArrays(url: safetensors)
        } else {
            weights = try NPZ.load(url: directory.appendingPathComponent("weights.npz"))
        }
        let model = WhisperModel(dims, dtype: .float16)
        if let q = raw["quantization"] as? [String: Any], let bits = (q["bits"] as? NSNumber)?.intValue {
            let groupSize = (q["group_size"] as? NSNumber)?.intValue ?? 64
            let mode = (q["mode"] as? String).flatMap(QuantizationMode.init(rawValue:)) ?? .affine
            let filter: (String, Module) -> (groupSize: Int, bits: Int, mode: QuantizationMode)? = { path, module in
                guard module is Linear || module is Embedding, weights["\(path).scales"] != nil else { return nil }
                return (groupSize: groupSize, bits: bits, mode: mode)
            }
            quantize(model: model, filter: filter)
        }
        let parameters = ModuleParameters(item: NestedItem.unflattened(weights.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        try model.update(parameters: parameters, verify: [.noUnusedKeys])
        eval(model.parameters())
        self.model = model

        let tokenizer = try WhisperTokenizer(assets: assets, multilingual: dims.isMultilingual, numLanguages: dims.numLanguages)
        self.tokenizer = tokenizer
        guard let filters = try NPZ.load(url: assets.appendingPathComponent("mel_filters.npz"))["mel_\(dims.nMels)"] else {
            throw MLXModelError("Whisper 离线辅助资源缺失: mel_filters.npz")
        }
        self.filters = filters
        // np.hanning(401)[:-1]
        window = MLXArray((0..<Self.nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nFFT))) })

        // DecodingTask._get_suppress_tokens (suppress_tokens="-1") and SuppressBlank.
        var suppress = Set(tokenizer.nonSpeechTokens)
        suppress.formUnion([tokenizer.transcribe, tokenizer.translate, tokenizer.sot, tokenizer.sotPrev, tokenizer.sotLM, tokenizer.noSpeech])
        suppressTokens = suppress.sorted()
        blankTokens = tokenizer.encode(" ") + [tokenizer.eot]
    }

    /// language: a Whisper code ("zh", "en", ...) or nil to detect it from the first 30 s.
    /// Returns the transcript without surrounding whitespace.
    public func transcribe(samples: [Float], language: String?) -> String {
        // log_mel_spectrogram(audio, padding=N_SAMPLES): 30 s of silence appended for slicing.
        let mel = logMel(samples + [Float](repeating: 0, count: Self.nSamples))
        let contentFrames = mel.dim(0) - Self.nFrames

        var language = language
        if !tokenizer.multilingual {
            language = "en"
        } else if language == nil {
            language = detectLanguage(padOrTrim(mel[0..<min(mel.dim(0), Self.nFrames)]))
        }

        let inputStride = Self.nFrames / model.dims.nAudioCtx
        let timePrecision = Double(inputStride * Self.hop) / Double(Self.sampleRate)
        let timestampBegin = tokenizer.timestampBegin
        var allTokens = [Int]()
        var seek = 0
        while seek < contentFrames {
            let timeOffset = Double(seek * Self.hop) / Double(Self.sampleRate)
            let segmentSize = min(Self.nFrames, contentFrames - seek)
            let result = decode(padOrTrim(mel[seek..<(seek + segmentSize)]), language: language)
            let previousSeek = seek

            // No voice activity: skip the window unless the tokens are confident enough.
            if result.noSpeechProb > Self.noSpeechThreshold && !(result.avgLogprob > Self.logprobThreshold) {
                seek += segmentSize
                continue
            }

            let tokens = result.tokens
            let isTimestamp = tokens.map { $0 >= timestampBegin }
            let singleTimestampEnding = isTimestamp.count >= 2 && Array(isTimestamp.suffix(2)) == [false, true]
            var consecutive = [Int]()
            for i in 0..<max(0, isTimestamp.count - 1) where isTimestamp[i] && isTimestamp[i + 1] {
                consecutive.append(i + 1)
            }
            var segments: [(start: Double, end: Double, tokens: [Int])] = []
            if !consecutive.isEmpty {
                var slices = consecutive
                if singleTimestampEnding { slices.append(tokens.count) }
                var lastSlice = 0
                for current in slices {
                    let sliced = Array(tokens[lastSlice..<current])
                    segments.append((timeOffset + Double(sliced[0] - timestampBegin) * timePrecision,
                                     timeOffset + Double(sliced[sliced.count - 1] - timestampBegin) * timePrecision,
                                     sliced))
                    lastSlice = current
                }
                if singleTimestampEnding {
                    seek += segmentSize
                } else {
                    seek += (tokens[lastSlice - 1] - timestampBegin) * inputStride
                }
            } else {
                var duration = Double(segmentSize * Self.hop) / Double(Self.sampleRate)
                if let last = tokens.last(where: { $0 >= timestampBegin }), last != timestampBegin {
                    duration = Double(last - timestampBegin) * timePrecision
                }
                segments.append((timeOffset, timeOffset + duration, tokens))
                seek += segmentSize
            }
            // Python would loop forever on a window ending at <|0.00|>; always make progress.
            if seek <= previousSeek { seek = previousSeek + segmentSize }

            // Instantaneous or empty segments contribute no tokens.
            for segment in segments {
                let text = tokenizer.decode(segment.tokens.filter { $0 < tokenizer.eot })
                if segment.start == segment.end || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                allTokens += segment.tokens
            }
        }
        return tokenizer.decode(allTokens).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio

    /// audio.log_mel_spectrogram in the same float32 MLX ops: reflect-padded STFT (hop 160),
    /// last frame dropped, |X|^2 @ filters.T, log10 floor 1e-10, clamp to max-8, (x+4)/4.
    /// Returns (frames, nMels).
    private func logMel(_ audio: [Float]) -> MLXArray {
        let padding = Self.nFFT / 2
        var padded = [Float]()
        padded.reserveCapacity(audio.count + 2 * padding)
        padded += audio[1...padding].reversed()
        padded += audio
        padded += audio[(audio.count - padding - 1)..<(audio.count - 1)].reversed()
        let x = MLXArray(padded)
        let frames = (padded.count - Self.nFFT + Self.hop) / Self.hop
        let strided = asStrided(x, [frames, Self.nFFT], strides: [Self.hop, 1])
        let spectrum = MLXFFT.rfft(strided * window)
        let magnitudes = spectrum[0..<(frames - 1)].abs().square()
        let melSpec = matmul(magnitudes, filters.T)
        var logSpec = maximum(melSpec, Float(1e-10)).log10()
        logSpec = maximum(logSpec, logSpec.max() - Float(8))
        let out = (logSpec + Float(4)) / Float(4)
        eval(out)
        return out
    }

    /// pad_or_trim(mel, N_FRAMES, axis=-2), then the fp16 cast DecodingTask applies. Returns (1, 3000, nMels).
    private func padOrTrim(_ mel: MLXArray) -> MLXArray {
        var segment = mel
        if segment.dim(0) < Self.nFrames {
            segment = concatenated([segment, MLXArray.zeros([Self.nFrames - segment.dim(0), segment.dim(1)], dtype: segment.dtype)], axis: 0)
        }
        return segment.asType(dtype).expandedDimensions(axis: 0)
    }

    // MARK: - Decoding

    /// decoding.detect_language: the most likely language token after <|startoftranscript|>.
    private func detectLanguage(_ mel: MLXArray) -> String {
        let features = model.encoder(mel)
        let (logits, _) = model.decoder(MLXArray([Int32(tokenizer.sot)]).reshaped(1, 1), xa: features, cache: nil)
        let row = logits[0, 0].asType(.float32)
        eval(row)
        let values = row.asArray(Float.self)
        let tokens = tokenizer.languageTokens
        var best = 0
        for (i, token) in tokens.enumerated() where values[token] > values[tokens[best]] {
            best = i
        }
        return tokenizer.languages[best]
    }

    private struct DecodingResult {
        var tokens: [Int]
        var avgLogprob: Double
        var noSpeechProb: Double
    }

    /// DecodingTask.run for one window with greedy decoding: returns sampled tokens (without the
    /// sot sequence and final EOT), their average log-probability and the no-speech probability.
    private func decode(_ mel: MLXArray, language: String?) -> DecodingResult {
        let features = model.encoder(mel)
        let initial = tokenizer.sotSequence(language: language)
        let sampleBegin = initial.count
        let sotIndex = initial.firstIndex(of: tokenizer.sot) ?? 0
        let eot = tokenizer.eot

        var tokens = initial
        var cache: [WhisperLayerCache]? = nil
        var sumLogprob = 0.0
        var noSpeechProb = Double.nan
        var completed = false
        for step in 0..<Self.sampleLength {
            if step > 0 && (completed || tokens.count > model.dims.nTextCtx) { break }
            let inputs = step == 0 ? tokens : [tokens[tokens.count - 1]]
            let (output, nextCache) = model.decoder(MLXArray(inputs.map { Int32($0) }).reshaped(1, -1), xa: features, cache: cache)
            cache = nextCache
            let logitsArray = output[0, output.dim(1) - 1].asType(.float32)
            if step == 0 {
                let probs = softmax(output[0, sotIndex].asType(.float32), axis: -1)
                eval(logitsArray, probs)
                noSpeechProb = Double(probs[tokenizer.noSpeech].item(Float.self))
            } else {
                eval(logitsArray)
            }
            var logits = logitsArray.asArray(Float.self)
            applyFilters(&logits, tokens: tokens, sampleBegin: sampleBegin)

            // GreedyDecoder.update
            var next = 0
            for i in 1..<logits.count where logits[i] > logits[next] { next = i }
            let lastToken = tokens[tokens.count - 1]
            if lastToken != eot {
                sumLogprob += Double(logits[next] - Self.logSumExp(logits))
            } else {
                next = eot
            }
            tokens.append(next)
            completed = next == eot
        }
        // finalize: slice after the sot sequence, up to the first EOT.
        var sampled = Array(tokens[sampleBegin...])
        if let end = sampled.firstIndex(of: eot) { sampled = Array(sampled[..<end]) }
        return DecodingResult(tokens: sampled, avgLogprob: sumLogprob / Double(sampled.count + 1), noSpeechProb: noSpeechProb)
    }

    /// SuppressBlank, SuppressTokens and ApplyTimestampRules, in DecodingTask order.
    private func applyFilters(_ logits: inout [Float], tokens: [Int], sampleBegin: Int) {
        let eot = tokenizer.eot
        let begin = tokenizer.timestampBegin
        let atStart = tokens.count == sampleBegin
        if atStart {
            for token in blankTokens { logits[token] = -.infinity }
        }
        for token in suppressTokens { logits[token] = -.infinity }

        // ApplyTimestampRules. Its "timestamps shouldn't decrease" rule is a no-op in
        // mlx-whisper 0.4.3 (it masks [timestamp_begin, index) with a sequence index, an empty
        // range), so it is intentionally not reproduced.
        var mask = [Float](repeating: 0, count: logits.count)
        mask[tokenizer.noTimestamps] = -.infinity
        let sequence = tokens[sampleBegin...]
        let lastWasTimestamp = sequence.count >= 1 && sequence.last! >= begin
        let penultimateWasTimestamp = sequence.count < 2 || sequence[sequence.endIndex - 2] >= begin
        if lastWasTimestamp {
            if penultimateWasTimestamp {
                for i in begin..<mask.count { mask[i] = -.infinity }
            } else {
                for i in 0..<eot { mask[i] = -.infinity }
            }
        }
        if atStart {
            for i in 0..<begin { mask[i] = -.infinity }
            // max_initial_timestamp 1.0 s at 30 / n_audio_ctx seconds per timestamp step.
            let maxInitial = Int((1.0 / (30.0 / Double(model.dims.nAudioCtx))).rounded())
            let lastAllowed = begin + maxInitial
            if lastAllowed + 1 < mask.count {
                for i in (lastAllowed + 1)..<mask.count { mask[i] = -.infinity }
            }
        }
        // If timestamps are jointly more likely than any text token, force a timestamp.
        let total = Self.logSumExp(logits)
        let timestampLogprob = Self.logSumExp(logits[begin...].map { $0 - total })
        let maxTextLogprob = (logits[..<begin].max() ?? -.infinity) - total
        if timestampLogprob > maxTextLogprob {
            for i in 0..<begin { mask[i] = -.infinity }
        }
        for i in 0..<logits.count { logits[i] += mask[i] }
    }

    private static func logSumExp<C: Collection>(_ values: C) -> Float where C.Element == Float {
        guard let peak = values.max(), peak > -.infinity else { return -.infinity }
        var sum: Float = 0
        for v in values { sum += Foundation.exp(v - peak) }
        return peak + Foundation.log(sum)
    }
}
