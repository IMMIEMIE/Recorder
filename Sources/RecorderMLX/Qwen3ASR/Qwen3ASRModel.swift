import Foundation
import MLX
import MLXNN

// Qwen3-ASR port of mlx_audio/stt/models/qwen3_asr/qwen3_asr.py (mlx-audio 0.5.1): the parts the
// 声笺 backend uses (single input, greedy decoding, fixed language or auto). Module keys mirror the
// Python tree so the safetensors load directly. Verified against Python in docs/SPIKE-RESULTS.md.

/// Unbounded KV cache with mlx_lm KVCache semantics: (batch, kvHeads, seq, headDim).
final class ASRKVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        if let ks = keys, let vs = values {
            keys = concatenated([ks, newKeys], axis: 2)
            values = concatenated([vs, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        offset += newKeys.dim(2)
        return (keys!, values!)
    }
}

// MARK: - Configuration (config.py; HF configs nest both parts under thinker_config)

struct Qwen3ASRConfiguration {
    struct Audio {
        var numMelBins = 128
        var encoderLayers = 24
        var encoderAttentionHeads = 16
        var encoderFFNDim = 4096
        var dModel = 1024
        var maxSourcePositions = 1500
        var nWindow = 50
        var outputDim = 2048
        var nWindowInfer = 800
        var downsampleHiddenSize = 480
    }

    struct Text {
        var vocabSize = 151_936
        var hiddenSize = 2048
        var intermediateSize = 6144
        var numHiddenLayers = 28
        var numAttentionHeads = 16
        var numKeyValueHeads = 8
        var headDim = 128
        var rmsNormEps: Float = 1e-6
        var ropeTheta: Float = 1_000_000
        var tieWordEmbeddings = true
    }

    struct Quantization {
        var groupSize: Int
        var bits: Int
        var mode: QuantizationMode
    }

    var audio = Audio()
    var text = Text()
    var audioTokenID = 151_676
    var audioStartTokenID = 151_669
    var audioEndTokenID = 151_670
    var supportLanguages: [String] = []
    var quantization: Quantization?

    init(json raw: [String: Any]) {
        var params = raw
        if let thinker = raw["thinker_config"] as? [String: Any] {
            for key in ["audio_config", "text_config", "audio_token_id", "audio_start_token_id", "audio_end_token_id"] {
                if let value = thinker[key] { params[key] = value }
            }
        }
        func int(_ dict: [String: Any], _ key: String, _ fallback: Int) -> Int {
            (dict[key] as? NSNumber)?.intValue ?? fallback
        }
        func float(_ dict: [String: Any], _ key: String, _ fallback: Float) -> Float {
            (dict[key] as? NSNumber)?.floatValue ?? fallback
        }
        if let a = params["audio_config"] as? [String: Any] {
            audio.numMelBins = int(a, "num_mel_bins", audio.numMelBins)
            audio.encoderLayers = int(a, "encoder_layers", audio.encoderLayers)
            audio.encoderAttentionHeads = int(a, "encoder_attention_heads", audio.encoderAttentionHeads)
            audio.encoderFFNDim = int(a, "encoder_ffn_dim", audio.encoderFFNDim)
            audio.dModel = int(a, "d_model", audio.dModel)
            audio.maxSourcePositions = int(a, "max_source_positions", audio.maxSourcePositions)
            audio.nWindow = int(a, "n_window", audio.nWindow)
            audio.outputDim = int(a, "output_dim", audio.outputDim)
            audio.nWindowInfer = int(a, "n_window_infer", audio.nWindowInfer)
            audio.downsampleHiddenSize = int(a, "downsample_hidden_size", audio.downsampleHiddenSize)
        }
        if let t = params["text_config"] as? [String: Any] {
            text.vocabSize = int(t, "vocab_size", text.vocabSize)
            text.hiddenSize = int(t, "hidden_size", text.hiddenSize)
            text.intermediateSize = int(t, "intermediate_size", text.intermediateSize)
            text.numHiddenLayers = int(t, "num_hidden_layers", text.numHiddenLayers)
            text.numAttentionHeads = int(t, "num_attention_heads", text.numAttentionHeads)
            text.numKeyValueHeads = int(t, "num_key_value_heads", text.numKeyValueHeads)
            text.headDim = int(t, "head_dim", text.headDim)
            text.rmsNormEps = float(t, "rms_norm_eps", text.rmsNormEps)
            text.ropeTheta = float(t, "rope_theta", text.ropeTheta)
            text.tieWordEmbeddings = (t["tie_word_embeddings"] as? Bool) ?? text.tieWordEmbeddings
        }
        audioTokenID = int(params, "audio_token_id", audioTokenID)
        audioStartTokenID = int(params, "audio_start_token_id", audioStartTokenID)
        audioEndTokenID = int(params, "audio_end_token_id", audioEndTokenID)
        supportLanguages = params["support_languages"] as? [String] ?? []
        if let q = raw["quantization"] as? [String: Any], let bits = (q["bits"] as? NSNumber)?.intValue {
            quantization = Quantization(
                groupSize: (q["group_size"] as? NSNumber)?.intValue ?? 64, bits: bits,
                mode: (q["mode"] as? String).flatMap(QuantizationMode.init(rawValue:)) ?? .affine)
        }
    }
}

// MARK: - Audio encoder

final class AudioAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scaling: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(dModel: Int, heads: Int) {
        embedDim = dModel
        numHeads = heads
        headDim = dModel / heads
        scaling = 1 / sqrt(Float(headDim))
        _qProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _kProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _vProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _outProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let (bsz, seqLen) = (x.dim(0), x.dim(1))
        var q = qProj(x) * scaling
        var k = kProj(x)
        var v = vProj(x)
        q = q.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        k = k.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        v = v.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        var out = MLX.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0, mask: mask)
        out = out.transposed(0, 2, 1, 3).reshaped(bsz, seqLen, embedDim)
        return outProj(out)
    }
}

final class AudioEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: AudioAttention
    @ModuleInfo(key: "self_attn_layer_norm") var attnNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm

    init(dModel: Int, ffnDim: Int, heads: Int) {
        _selfAttn.wrappedValue = AudioAttention(dModel: dModel, heads: heads)
        _attnNorm.wrappedValue = LayerNorm(dimensions: dModel)
        _fc1.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: ffnDim, bias: true)
        _fc2.wrappedValue = Linear(inputDimensions: ffnDim, outputDimensions: dModel, bias: true)
        _finalNorm.wrappedValue = LayerNorm(dimensions: dModel)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        var h = x
        var residual = h
        h = attnNorm(h)
        h = selfAttn(h, mask: mask)
        h = residual + h
        residual = h
        h = finalNorm(h)
        h = MLXNN.gelu(fc1(h))
        h = fc2(h)
        return residual + h
    }
}

final class AudioEncoder: Module {
    let config: Qwen3ASRConfiguration.Audio
    @ModuleInfo(key: "conv2d1") var conv1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [AudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear
    let positionalEmbedding: MLXArray  // (maxPositions, dModel); not in the checkpoint

    init(config: Qwen3ASRConfiguration.Audio) {
        self.config = config
        let hidden = config.downsampleHiddenSize
        _conv1.wrappedValue = Conv2d(inputChannels: 1, outputChannels: hidden,
                                     kernelSize: [3, 3], stride: [2, 2], padding: [1, 1])
        _conv2.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden,
                                     kernelSize: [3, 3], stride: [2, 2], padding: [1, 1])
        _conv3.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden,
                                     kernelSize: [3, 3], stride: [2, 2], padding: [1, 1])
        let freqAfterConv = ((((config.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(inputDimensions: hidden * freqAfterConv,
                                       outputDimensions: config.dModel, bias: false)
        positionalEmbedding = AudioEncoder.sinusoidal(length: config.maxSourcePositions, channels: config.dModel)
        _layers.wrappedValue = (0..<config.encoderLayers).map { _ in
            AudioEncoderLayer(dModel: config.dModel, ffnDim: config.encoderFFNDim, heads: config.encoderAttentionHeads)
        }
        _lnPost.wrappedValue = LayerNorm(dimensions: config.dModel)
        _proj1.wrappedValue = Linear(inputDimensions: config.dModel, outputDimensions: config.dModel, bias: true)
        _proj2.wrappedValue = Linear(inputDimensions: config.dModel, outputDimensions: config.outputDim, bias: true)
        super.init()
    }

    /// SinusoidalPositionEmbedding: concat[sin(scaled), cos(scaled)] along channels.
    static func sinusoidal(length: Int, channels: Int) -> MLXArray {
        let half = channels / 2
        let logInc = log(10000.0) / Double(half - 1)
        var data = [Float](repeating: 0, count: length * channels)
        for pos in 0..<length {
            for i in 0..<half {
                let scaled = Double(pos) * exp(-logInc * Double(i))
                data[pos * channels + i] = Float(sin(scaled))
                data[pos * channels + half + i] = Float(cos(scaled))
            }
        }
        return MLXArray(data).reshaped(length, channels)
    }

    /// _get_feat_extract_output_lengths with Python floor semantics: intermediates can go negative,
    /// where Swift's `/` would truncate toward zero, so arithmetic shifts do the halving.
    static func featOutLength(_ inputLength: Int) -> Int {
        let leave = inputLength % 100
        let feat = ((leave - 1) >> 1) + 1
        return (((feat - 1) >> 1) >> 1) + 1 + (inputLength / 100) * 13
    }

    private func blockMask(seqLen: Int, cuSeqlens: [Int], dtype: DType) -> MLXArray {
        var mask = [Float](repeating: -1e9, count: seqLen * seqLen)
        for i in 0..<(cuSeqlens.count - 1) {
            let start = cuSeqlens[i], end = cuSeqlens[i + 1]
            for r in start..<end {
                for c in start..<end { mask[r * seqLen + c] = 0 }
            }
        }
        return MLXArray(mask).reshaped(seqLen, seqLen).asType(dtype).expandedDimensions(axes: [0, 1])
    }

    /// features: (1, nMels, frames); validFrames: frames covered by the attention mask.
    func callAsFunction(_ features: MLXArray, validFrames: Int) -> MLXArray {
        let chunkSize = config.nWindow * 2
        let feat = features[0]
        var chunks = [MLXArray]()
        var chunkLens = [Int]()
        var pos = 0
        while pos < validFrames {
            let remaining = validFrames - pos
            let clen = pos + chunkSize >= validFrames ? (remaining % chunkSize == 0 ? chunkSize : remaining) : chunkSize
            chunks.append(feat[0..., pos..<(pos + clen)])
            chunkLens.append(clen)
            pos += clen
        }
        let maxChunk = chunkLens.max() ?? 1
        let padded = chunks.map { c in
            c.dim(1) < maxChunk
                ? MLX.concatenated([c, MLXArray.zeros([c.dim(0), maxChunk - c.dim(1)], dtype: c.dtype)], axis: 1)
                : c
        }
        let batch = MLX.stacked(padded, axis: 0).expandedDimensions(axis: 3)  // (C, mels, maxChunk, 1)

        var x = MLXNN.gelu(conv1(batch))
        x = MLXNN.gelu(conv2(x))
        x = MLXNN.gelu(conv3(x))
        let (b, f, t, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        x = x.transposed(0, 2, 3, 1).reshaped(b, t, c * f)
        x = convOut(x)
        x = x + positionalEmbedding[0..<x.dim(1), 0...]

        let afterCnnLens = chunkLens.map { AudioEncoder.featOutLength($0) }
        var hidden = concatenated((0..<b).map { x[$0, 0..<afterCnnLens[$0], 0...] }, axis: 0)

        // Attention windows split the whole post-CNN sequence (not each chunk) into blocks of
        // maxAfterCnn * (n_window_infer / (n_window * 2)).
        let maxAfterCnn = afterCnnLens.max() ?? 1
        let windowAfterCnn = maxAfterCnn * (config.nWindowInfer / (config.nWindow * 2))
        let totalLen = afterCnnLens.reduce(0, +)
        let seqAfterCnn = AudioEncoder.featOutLength(validFrames)
        var cuSeqlens = [0]
        for _ in 0..<(seqAfterCnn / windowAfterCnn) { cuSeqlens.append(cuSeqlens.last! + windowAfterCnn) }
        if seqAfterCnn % windowAfterCnn != 0 { cuSeqlens.append(cuSeqlens.last! + seqAfterCnn % windowAfterCnn) }
        precondition(seqAfterCnn == totalLen && cuSeqlens.last! == totalLen, "音频编码器分块长度不一致")

        let mask = blockMask(seqLen: totalLen, cuSeqlens: cuSeqlens, dtype: hidden.dtype)
        hidden = hidden.expandedDimensions(axis: 0)
        for layer in layers {
            hidden = layer(hidden, mask: mask)
        }
        var out = lnPost(hidden[0])
        out = MLXNN.gelu(proj1(out))
        return proj2(out)  // (totalAfterCnn, outputDim)
    }
}

// MARK: - Text decoder (Qwen3)

final class TextAttention: Module {
    let numHeads: Int
    let numKvHeads: Int
    let headDim: Int
    let scale: Float
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let rope: RoPE

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        numHeads = cfg.numAttentionHeads
        numKvHeads = cfg.numKeyValueHeads
        headDim = cfg.headDim
        scale = 1 / sqrt(Float(cfg.headDim))
        _qProj.wrappedValue = Linear(inputDimensions: cfg.hiddenSize, outputDimensions: numHeads * headDim, bias: false)
        _kProj.wrappedValue = Linear(inputDimensions: cfg.hiddenSize, outputDimensions: numKvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(inputDimensions: cfg.hiddenSize, outputDimensions: numKvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(inputDimensions: numHeads * headDim, outputDimensions: cfg.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
        rope = RoPE(dimensions: headDim, traditional: false, base: cfg.ropeTheta)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: ASRKVCache?) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        var q = qNorm(qProj(x).reshaped(b, l, numHeads, headDim)).transposed(0, 2, 1, 3)
        var k = kNorm(kProj(x).reshaped(b, l, numKvHeads, headDim)).transposed(0, 2, 1, 3)
        var v = vProj(x).reshaped(b, l, numKvHeads, headDim).transposed(0, 2, 1, 3)
        let offset = cache?.offset ?? 0
        q = rope(q, offset: offset)
        k = rope(k, offset: offset)
        if let cache {
            (k, v) = cache.update(keys: k, values: v)
        }
        let out = MLX.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask)
        return oProj(out.transposed(0, 2, 1, 3).reshaped(b, l, numHeads * headDim))
    }
}

final class TextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        _gateProj.wrappedValue = Linear(inputDimensions: hiddenSize, outputDimensions: intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(inputDimensions: hiddenSize, outputDimensions: intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(inputDimensions: intermediateSize, outputDimensions: hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

final class TextDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: TextAttention
    @ModuleInfo(key: "mlp") var mlp: TextMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postNorm: RMSNorm

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        _selfAttn.wrappedValue = TextAttention(cfg)
        _mlp.wrappedValue = TextMLP(hiddenSize: cfg.hiddenSize, intermediateSize: cfg.intermediateSize)
        _inputNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        _postNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: ASRKVCache?) -> MLXArray {
        let h = x + selfAttn(inputNorm(x), mask: mask, cache: cache)
        return h + mlp(postNorm(h))
    }
}

final class TextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [TextDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: cfg.vocabSize, dimensions: cfg.hiddenSize)
        _layers.wrappedValue = (0..<cfg.numHiddenLayers).map { _ in TextDecoderLayer(cfg) }
        _norm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    /// Returns normalized hidden states; the caller applies the LM head.
    func callAsFunction(inputsEmbeds: MLXArray, cache: [ASRKVCache]) -> MLXArray {
        var h = inputsEmbeds
        let mask = TextModel.causalMask(offset: cache.first?.offset ?? 0, n: h.dim(1), dtype: h.dtype)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache[i])
        }
        return norm(h)
    }

    /// create_additive_causal_mask(N, offset); nil when one query attends to everything cached.
    static func causalMask(offset: Int, n: Int, dtype: DType) -> MLXArray? {
        if n == 1 { return nil }
        let total = offset + n
        let r = MLXArray.arange(0, total).reshaped(1, total)
        let l = MLXArray.arange(offset, total).reshaped(n, 1)
        return ((l .< r) * MLXArray(-1e9)).asType(dtype)
    }
}

// MARK: - Top-level model

final class Qwen3ASRModel: Module {
    let configuration: Qwen3ASRConfiguration
    @ModuleInfo(key: "audio_tower") var audioTower: AudioEncoder
    @ModuleInfo(key: "model") var model: TextModel
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ configuration: Qwen3ASRConfiguration) {
        self.configuration = configuration
        _audioTower.wrappedValue = AudioEncoder(config: configuration.audio)
        _model.wrappedValue = TextModel(configuration.text)
        if !configuration.text.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(inputDimensions: configuration.text.hiddenSize,
                                          outputDimensions: configuration.text.vocabSize, bias: false)
        }
        super.init()
    }

    /// Tied checkpoints reuse the embedding matrix as the LM head (Python: embed_tokens.as_linear).
    private func logits(_ hidden: MLXArray) -> MLXArray {
        if let lmHead { return lmHead(hidden) }
        return model.embedTokens.asLinear(hidden)
    }

    /// _build_inputs_embeds: the <|audio_pad|> block is contiguous in this prompt, so the audio
    /// features replace it by concatenation.
    func buildInputsEmbeds(inputIDs: [Int], audioFeatures: MLXArray) -> MLXArray {
        let embeds = model.embedTokens(MLXArray(inputIDs.map { Int32($0) }).reshaped(1, -1))  // (1, L, H)
        let feats = audioFeatures.asType(embeds.dtype)
        let padPositions = inputIDs.indices.filter { inputIDs[$0] == configuration.audioTokenID }
        let count = min(padPositions.count, feats.dim(0))
        guard let first = padPositions.first, count > 0 else { return embeds }
        let h = embeds.dim(2)
        let flat = embeds.reshaped(-1, h)
        return concatenated([flat[0..<first, 0...], feats[0..<count, 0...], flat[(first + count)..., 0...]], axis: 0)
            .reshaped(1, -1, h)
    }

    /// Greedy decoding (temperature 0), stopping at an EOS id or after maxTokens.
    func generate(audioFeatures: MLXArray, inputIDs: [Int], eosTokenIDs: Set<Int>, maxTokens: Int) -> [Int] {
        let cache = (0..<configuration.text.numHiddenLayers).map { _ in ASRKVCache() }
        let embeds = buildInputsEmbeds(inputIDs: inputIDs, audioFeatures: audioFeatures)
        let seqLen = embeds.dim(1)
        func sample(_ hidden: MLXArray) -> MLXArray {
            logits(hidden).argMax(axis: -1)
        }
        var token: MLXArray
        if seqLen > 1 {
            _ = model(inputsEmbeds: embeds[0..., 0..<(seqLen - 1), 0...], cache: cache)
            token = sample(model(inputsEmbeds: embeds[0..., (seqLen - 1)..., 0...], cache: cache))
        } else {
            token = sample(model(inputsEmbeds: embeds, cache: cache))
        }
        eval(token)
        var out = [Int]()
        while out.count < maxTokens {
            let t = Int(token.item(Int32.self))
            if eosTokenIDs.contains(t) { break }
            out.append(t)
            token = sample(model(inputsEmbeds: model.embedTokens(token.reshaped(1, 1)), cache: cache))
            eval(token)
        }
        return out
    }
}
