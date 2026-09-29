import Foundation
import MLX
import MLXNN
import MLXFast

/// Qwen3-ASR port of mlx_audio/stt/models/qwen3_asr/qwen3_asr.py (the parts the
/// 声笺 backend uses: single-input, greedy, fixed language or auto).
/// Parameter names mirror the Python module tree so safetensors load directly.

// MARK: - Audio encoder

final class AudioAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scaling: Float

    @ModuleInfo(var keys: "q_proj") var qProj: Linear
    @ModuleInfo(var keys: "k_proj") var kProj: Linear
    @ModuleInfo(var keys: "v_proj") var vProj: Linear
    @ModuleInfo(var keys: "out_proj") var outProj: Linear

    init(dModel: Int, heads: Int) {
        embedDim = dModel
        numHeads = heads
        headDim = dModel / heads
        scaling = Float(headDim) ** -0.5
        _qProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _kProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _vProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        _outProj.wrappedValue = Linear(inputDimensions: dModel, outputDimensions: dModel, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let (bsz, seqLen, _) = (x.dim(0), x.dim(1), x.dim(2))
        var q = qProj(x) * scaling
        var k = kProj(x)
        var v = vProj(x)
        q = q.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        k = k.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        v = v.reshaped(bsz, seqLen, numHeads, headDim).transposed(0, 2, 1, 3)
        var out = MLXFast.scaledDotProductAttention(q, k, v, scale: 1.0, mask: mask)
        out = out.transposed(0, 2, 1, 3).reshaped(bsz, seqLen, embedDim)
        return outProj(out)
    }
}

final class AudioEncoderLayer: Module {
    let embedDim: Int
    @ModuleInfo(key: "self_attn") var selfAttn: AudioAttention
    @ModuleInfo(key: "self_attn_layer_norm") var attnNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm

    init(dModel: Int, ffnDim: Int, heads: Int) {
        embedDim = dModel
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
        h = gelu(fc1(h))
        h = fc2(h)
        return residual + h
    }
}

final class AudioEncoder: Module {
    struct Config {
        var dModel = 1024
        var heads = 16
        var layers = 24
        var ffnDim = 4096
        var downsampleHidden = 480
        var numMelBins = 128
        var maxSourcePositions = 1500
        var outputDim = 2048
        var nWindow = 50
        var nWindowInfer = 800
    }

    let config: Config
    @ModuleInfo(key: "conv2d1") var conv1: Conv2D
    @ModuleInfo(key: "conv2d2") var conv2: Conv2D
    @ModuleInfo(key: "conv2d3") var conv3: Conv2D
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [AudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear
    let positionalEmbedding: MLXArray  // (maxPositions, dModel)

    init(config: Config) {
        self.config = config
        _conv1.wrappedValue = Conv2D(
            inputChannels: 1, outputChannels: config.downsampleHidden,
            kernelSize: (3, 3), stride: (2, 2), padding: (1, 1))
        _conv2.wrappedValue = Conv2D(
            inputChannels: config.downsampleHidden, outputChannels: config.downsampleHidden,
            kernelSize: (3, 3), stride: (2, 2), padding: (1, 1))
        _conv3.wrappedValue = Conv2D(
            inputChannels: config.downsampleHidden, outputChannels: config.downsampleHidden,
            kernelSize: (3, 3), stride: (2, 2), padding: (1, 1))
        let freqAfterConv = ((((config.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(
            inputDimensions: config.downsampleHidden * freqAfterConv,
            outputDimensions: config.dModel, bias: false)
        positionalEmbedding = AudioEncoder.sinusoidal(length: config.maxSourcePositions, channels: config.dModel)
        _layers.wrappedValue = (0..<config.layers).map { _ in
            AudioEncoderLayer(dModel: config.dModel, ffnDim: config.ffnDim, heads: config.heads)
        }
        _lnPost.wrappedValue = LayerNorm(dimensions: config.dModel)
        _proj1.wrappedValue = Linear(inputDimensions: config.dModel, outputDimensions: config.dModel, bias: true)
        _proj2.wrappedValue = Linear(inputDimensions: config.dModel, outputDimensions: config.outputDim, bias: true)
        super.init()
    }

    /// python SinusoidalPositionEmbedding: concat[sin(scaled), cos(scaled)] along channels.
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

    /// python _get_feat_extract_output_lengths (numpy semantics, scalar input).
    static func featOutLength(_ inputLength: Int) -> Int {
        let leave = inputLength % 100
        let feat = (leave - 1) / 2 + 1        // python floor division on ints
        let inner = (feat - 1) / 2 + 1 - 1
        return (inner - 1) / 2 + 1 + (inputLength / 100) * 13
    }

    private func blockMask(seqLen: Int, cuSeqlens: [Int], dtype: Dtype) -> MLXArray {
        var mask = [Float](repeating: -1e9, count: seqLen * seqLen)
        for i in 0..<(cuSeqlens.count - 1) {
            let start = cuSeqlens[i], end = cuSeqlens[i + 1]
            for r in start..<end {
                for c in start..<end {
                    mask[r * seqLen + c] = 0
                }
            }
        }
        return MLXArray(mask).reshaped(seqLen, seqLen).astype(dtype).expandedDimensions(0, 1)
    }

    /// features: (1, nMels, 3000); validFrames: frames of real audio.
    func callAsFunction(_ features: MLXArray, validFrames: Int) -> MLXArray {
        let chunkSize = config.nWindow * 2
        let feat = features[0]                     // (128, 3000)
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
        // pad chunks on the time axis and stack
        let padded = chunks.map { c in
            c.dim(1) < maxChunk
                ? concatenated([c, MLXArray.zeros(c.dim(0), maxChunk - c.dim(1))], axis: 1)
                : c
        }
        let stacked = MLX.stacked(padded, axis: 0).expandedDimensions(3)  // (C, 128, maxChunk, 1)

        var x = MLXNN.gelu(conv1(stacked))
        x = MLXNN.gelu(conv2(x))
        x = MLXNN.gelu(conv3(x))                    // (C, 16, t, 480)
        let (b, f, t, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        x = x.transposed(0, 2, 3, 1).reshaped(b, t, c * f)
        x = convOut(x)
        x = x + positionalEmbedding[0..<x.dim(1), 0...]

        // per-chunk valid length after conv
        let afterCnnLens = chunkLens.map { AudioEncoder.featOutLength($0) }
        let validHiddens = (0..<b).map { x[$0, 0..<afterCnnLens[$0], 0...] }
        var hidden = MLX.concatenated(validHiddens, axis: 0)   // (total, dModel)

        // window blocks: python window_aftercnn = max_len_after_cnn * (n_window_infer / (n_window*2))
        let maxAfterCnn = afterCnnLens.max() ?? 1
        let windowAfterCnn = maxAfterCnn * (config.nWindowInfer / (config.nWindow * 2))
        let totalLen = afterCnnLens.reduce(0, +)
        var cuChunkLens = [Int]()
        for cnnLen in afterCnnLens {
            cuChunkLens.append(contentsOf: Array(repeating: windowAfterCnn, count: cnnLen / windowAfterCnn))
            if cnnLen % windowAfterCnn != 0 { cuChunkLens.append(cnnLen % windowAfterCnn) }
        }
        var cuSeqlens = [0]
        for l in cuChunkLens { cuSeqlens.append(cuSeqlens.last! + l) }
        precondition(cuSeqlens.last! == totalLen, "块注意力长度不一致")

        let mask = blockMask(seqLen: totalLen, cuSeqlens: cuSeqlens, dtype: hidden.dtype)
        hidden = hidden.expandedDimensions(0)
        for layer in layers {
            hidden = layer(hidden, mask: mask)
        }
        var out = hidden[0]
        out = lnPost(out)
        out = MLXNN.gelu(proj1(out))
        out = proj2(out)
        return out   // (totalAfterCnn, outputDim)
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

    init(hiddenSize: Int, heads: Int, kvHeads: Int, headDim: Int, eps: Float, ropeTheta: Float) {
        numHeads = heads
        numKvHeads = kvHeads
        self.headDim = headDim
        scale = Float(headDim) ** -0.5
        _qProj.wrappedValue = Linear(inputDimensions: hiddenSize, outputDimensions: heads * headDim, bias: false)
        _kProj.wrappedValue = Linear(inputDimensions: hiddenSize, outputDimensions: kvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(inputDimensions: hiddenSize, outputDimensions: kvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(inputDimensions: heads * headDim, outputDimensions: hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: eps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: eps)
        rope = RoPE(dimensions: headDim, traditional: false, base: ropeTheta)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache?) -> MLXArray {
        let (b, l, _) = (x.dim(0), x.dim(1), x.dim(2))
        var q = qProj(x).reshaped(b, l, numHeads, headDim)
        var k = kProj(x).reshaped(b, l, numKvHeads, headDim)
        var v = vProj(x).reshaped(b, l, numKvHeads, headDim)
        q = qNorm(q)
        k = kNorm(k)
        q = q.transposed(0, 2, 1, 3)
        k = k.transposed(0, 2, 1, 3)
        v = v.transposed(0, 2, 1, 3)
        let offset = cache?.offset ?? 0
        q = rope(q, offset: offset)
        k = rope(k, offset: offset)
        if let cache {
            (k, v) = cache.update(keys: k, values: v)
        }
        let out = MLXFast.scaledDotProductAttention(q, k, v, scale: scale, mask: mask)
        let qlen = q.dim(2)
        return oProj(out.transposed(0, 2, 1, 3).reshaped(b, qlen, numHeads * headDim))
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

    init(cfg: Qwen3ASRModel.TextConfig) {
        _selfAttn.wrappedValue = TextAttention(
            hiddenSize: cfg.hiddenSize, heads: cfg.numAttentionHeads,
            kvHeads: cfg.numKeyValueHeads, headDim: cfg.headDim,
            eps: cfg.rmsNormEps, ropeTheta: cfg.ropeTheta)
        _mlp.wrappedValue = TextMLP(hiddenSize: cfg.hiddenSize, intermediateSize: cfg.intermediateSize)
        _inputNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        _postNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache?) -> MLXArray {
        var h = x
        var residual = h
        h = inputNorm(h)
        h = selfAttn(h, mask: mask, cache: cache)
        h = residual + h
        residual = h
        h = postNorm(h)
        h = mlp(h)
        return residual + h
    }
}

final class TextModel: Module {
    let cfg: Qwen3ASRModel.TextConfig
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [TextDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(cfg: Qwen3ASRModel.TextConfig) {
        self.cfg = cfg
        _embedTokens.wrappedValue = Embedding(embeddingDimensions: cfg.hiddenSize, vocabularySize: cfg.vocabSize)
        _layers.wrappedValue = (0..<cfg.numHiddenLayers).map { _ in TextDecoderLayer(cfg: cfg) }
        _norm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    func callAsFunction(inputIds: MLXArray? = nil, inputsEmbeds: MLXArray? = nil,
                       cache: [KVCache?]?) -> MLXArray {
        var h = inputsEmbeds ?? embedTokens(inputIds!)
        let mask = TextModel.attentionMask(h: h, offset: cache?.first??.offset ?? 0, n: h.dim(1))
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i] ?? nil)
        }
        return norm(h)
    }

    /// additive causal mask like mlx's create_additive_causal_mask(N, offset);
    /// nil when a single query token attends to everything already cached.
    static func attentionMask(h: MLXArray, offset: Int, n: Int) -> MLXArray? {
        if n == 1 { return nil }
        let total = offset + n
        let r = MLXArray.arange(0..<total).reshaped(1, total)   // (1, total)
        let l = MLXArray.arange(offset..<offset + n).reshaped(n, 1)
        return ((l .< r) * MLXArray(-1e9)).astype(h.dtype)      // (n, total)
    }
}

// MARK: - Top-level model

final class Qwen3ASRModel: Module {
    struct TextConfig {
        var hiddenSize = 2048
        var numHiddenLayers = 28
        var numAttentionHeads = 16
        var numKeyValueHeads = 8
        var headDim = 128
        var intermediateSize = 6144
        var rmsNormEps: Float = 1e-6
        var ropeTheta: Float = 1_000_000
        var vocabSize = 151_936
        var tieWordEmbeddings = true
    }

    let text = TextConfig()
    @ModuleInfo(key: "audio_tower") var audioTower: AudioEncoder
    @ModuleInfo(key: "model") var model: TextModel

    /// 151643 <|endoftext|>, 151645 <|im_end|>
    let eosTokenIds: Set<Int> = [151_643, 151_645]
    let audioStartTokenId = 151_669
    let audioEndTokenId = 151_670
    let audioPadTokenId = 151_676

    init() {
        _audioTower.wrappedValue = AudioEncoder(config: AudioEncoder.Config())
        _model.wrappedValue = TextModel(cfg: text)
        super.init()
    }

    /// logits from a forward on embeddings (tied lm head: embed weight transposed).
    private func lmHead(_ hidden: MLXArray) -> MLXArray {
        precondition(text.tieWordEmbeddings)
        return model.embedTokens.asLinear(hidden)
    }

    /// python _build_inputs_embeds: replace the (contiguous) <|audio_pad|> embedding
    /// block with audio features. MLXArray has no scatter-by-index, so rebuild
    /// via concatenation — the pad block is always contiguous in this prompt.
    func buildInputsEmbeds(inputIds: MLXArray, audioFeatures: MLXArray) -> MLXArray {
        let embeds = model.embedTokens(inputIds)     // (1, L, H)
        let feats = audioFeatures.reshaped(-1, audioFeatures.dim(-1)).astype(embeds.dtype)
        let ids = inputIds.astype(.int32).reshaped(-1)
        eval(ids)
        var padPositions = [Int]()
        for i in 0..<ids.dim(0) {
            if Int(ids[i].item(Int32.self)) == audioPadTokenId { padPositions.append(i) }
            if padPositions.count >= feats.dim(0) { break }
        }
        guard let first = padPositions.first else { return embeds }
        let count = padPositions.count
        let last = first + count
        let h = embeds.dim(2)
        let flat = embeds.reshaped(-1, h)
        let pieces = [
            flat[0..<first, 0...],
            feats[0..<count, 0...],
            flat[last..., 0...],
        ]
        return MLX.concatenated(pieces, axis: 0).reshaped(1, -1, h)
    }

    /// Greedy transcription, mirroring stream_generate + generate_step (temperature 0).
    func generate(audioFeatures: MLXArray, inputIds: MLXArray, maxTokens: Int) -> [Int] {
        let cache: [KVCache?] = (0..<text.numHiddenLayers).map { _ in KVCache() }
        let embeds = buildInputsEmbeds(inputIds: inputIds, audioFeatures: audioFeatures)
        let seqLen = embeds.dim(1)

        // prefill all but the final position, then forward the final position to sample token 0
        var logits: MLXArray
        if seqLen > 1 {
            _ = model(inputsEmbeds: embeds[0..., 0..<(seqLen - 1), 0...], cache: cache)
            logits = model(inputsEmbeds: embeds[0..., (seqLen - 1)...(seqLen - 1), 0...], cache: cache)
        } else {
            logits = model(inputsEmbeds: embeds, cache: cache)
        }
        var token = MLX.argmax(logits[0..., logits.dim(1) - 1, 0...], axis: -1)
        eval(token)

        var out = [Int]()
        while out.count < maxTokens {
            let t = Int(token.item(Int32.self))
            if eosTokenIds.contains(t) { break }
            out.append(t)
            let nextEmbed = model.embedTokens(token.reshaped(1, 1))
            logits = model(inputsEmbeds: nextEmbed, cache: cache)
            token = MLX.argmax(logits[0..., logits.dim(1) - 1, 0...], axis: -1)
            eval(token)
        }
        return out
    }
}

// MARK: - Weight loading

enum WeightLoader {
    /// Load every safetensors shard in a snapshot dir and sanitize like the
    /// Python Model.sanitize: drop lm_head, strip "thinker.", keep conv layout as-is.
    static func load(snapshot: URL) throws -> [String: MLXArray] {
        let indexURL = snapshot.appendingPathComponent("model.safetensors.index.json")
        var files = [String]()
        if let idxData = try? Data(contentsOf: indexURL),
           let idx = try? JSONSerialization.jsonObject(with: idxData) as? [String: Any],
           let map = idx["weight_map"] as? [String: String] {
            files = Array(Set(map.values)).sorted()
        } else {
            files = ["model.safetensors"]
        }
        var weights = [String: MLXArray]()
        for f in files {
            let url = snapshot.appendingPathComponent(f)
            let shard = try MLXNN.loadWeights(url)
            for (k, v) in shard {
                var key = k
                if key.hasPrefix("thinker.") { key = String(key.dropFirst("thinker.".count)) }
                if key == "lm_head.weight" { continue }
                weights[key] = v
            }
        }
        return weights
    }
}
