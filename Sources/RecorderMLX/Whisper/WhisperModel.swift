import Foundation
import MLX
import MLXNN

// mlx_whisper/whisper.py (mlx-whisper 0.4.3). Module keys mirror the Python tree so the
// converted weights load directly.

struct WhisperDimensions {
    var nMels: Int
    var nAudioCtx: Int
    var nAudioState: Int
    var nAudioHead: Int
    var nAudioLayer: Int
    var nVocab: Int
    var nTextCtx: Int
    var nTextState: Int
    var nTextHead: Int
    var nTextLayer: Int

    init(json raw: [String: Any]) throws {
        func value(_ key: String) throws -> Int {
            guard let v = (raw[key] as? NSNumber)?.intValue, v > 0 else {
                throw MLXModelError("需要 MLX Whisper 格式的 config.json，不能直接加载 Transformers/PyTorch 权重")
            }
            return v
        }
        nMels = try value("n_mels")
        nAudioCtx = try value("n_audio_ctx")
        nAudioState = try value("n_audio_state")
        nAudioHead = try value("n_audio_head")
        nAudioLayer = try value("n_audio_layer")
        nVocab = try value("n_vocab")
        nTextCtx = try value("n_text_ctx")
        nTextState = try value("n_text_state")
        nTextHead = try value("n_text_head")
        nTextLayer = try value("n_text_layer")
    }

    var isMultilingual: Bool { nVocab >= 51865 }
    var numLanguages: Int { nVocab - 51765 - (isMultilingual ? 1 : 0) }
}

/// Self-attention keys/values (concatenated along the sequence axis) and cross-attention
/// keys/values (computed once from the audio features), before the head split.
struct WhisperLayerCache {
    var selfKV: (MLXArray, MLXArray)?
    var crossKV: (MLXArray, MLXArray)?
}

final class WhisperAttention: Module {
    let nHead: Int
    @ModuleInfo(key: "query") var queryProj: Linear
    @ModuleInfo(key: "key") var keyProj: Linear
    @ModuleInfo(key: "value") var valueProj: Linear
    @ModuleInfo(key: "out") var outProj: Linear

    init(nState: Int, nHead: Int) {
        self.nHead = nHead
        _queryProj.wrappedValue = Linear(nState, nState)
        _keyProj.wrappedValue = Linear(nState, nState, bias: false)
        _valueProj.wrappedValue = Linear(nState, nState)
        _outProj.wrappedValue = Linear(nState, nState)
        super.init()
    }

    /// xa nil: self-attention (cache extends it); xa set: cross-attention (cache replaces it).
    func callAsFunction(_ x: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil,
                        cache: (MLXArray, MLXArray)? = nil) -> (MLXArray, (MLXArray, MLXArray)) {
        let q = queryProj(x)
        var k: MLXArray
        var v: MLXArray
        if let xa {
            if let cache {
                (k, v) = cache
            } else {
                k = keyProj(xa)
                v = valueProj(xa)
            }
        } else {
            k = keyProj(x)
            v = valueProj(x)
            if let cache {
                k = concatenated([cache.0, k], axis: 1)
                v = concatenated([cache.1, v], axis: 1)
            }
        }
        return (outProj(attention(q, k, v, mask: mask)), (k, v))
    }

    /// qkv_attention: both q and k scaled by head_dim^-0.25, float32-precise softmax.
    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, mask: MLXArray?) -> MLXArray {
        let (b, nCtx, nState) = (q.dim(0), q.dim(1), q.dim(2))
        let scale = pow(Float(nState / nHead), -0.25)
        let qh = q.reshaped(b, nCtx, nHead, -1).transposed(0, 2, 1, 3) * scale
        let kh = k.reshaped(b, k.dim(1), nHead, -1).transposed(0, 2, 3, 1) * scale
        let vh = v.reshaped(b, v.dim(1), nHead, -1).transposed(0, 2, 1, 3)
        var qk = matmul(qh, kh)
        if let mask {
            // Python slices mask[:n_ctx, :n_ctx]; with a cache only single-token queries follow,
            // whose 1x1 mask slice is zero.
            qk = qk + mask[0..<nCtx, 0..<nCtx]
        }
        let w = softmax(qk, axis: -1, precise: true)
        return matmul(w, vh).transposed(0, 2, 1, 3).reshaped(b, nCtx, nState)
    }
}

final class WhisperBlock: Module {
    @ModuleInfo var attn: WhisperAttention
    @ModuleInfo(key: "attn_ln") var attnLn: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttn: WhisperAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttnLn: LayerNorm?
    @ModuleInfo var mlp1: Linear
    @ModuleInfo var mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpLn: LayerNorm

    init(nState: Int, nHead: Int, crossAttention: Bool) {
        _attn.wrappedValue = WhisperAttention(nState: nState, nHead: nHead)
        _attnLn.wrappedValue = LayerNorm(dimensions: nState)
        if crossAttention {
            _crossAttn.wrappedValue = WhisperAttention(nState: nState, nHead: nHead)
            _crossAttnLn.wrappedValue = LayerNorm(dimensions: nState)
        }
        _mlp1.wrappedValue = Linear(nState, nState * 4)
        _mlp2.wrappedValue = Linear(nState * 4, nState)
        _mlpLn.wrappedValue = LayerNorm(dimensions: nState)
        super.init()
    }

    func callAsFunction(_ input: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil,
                        cache: WhisperLayerCache? = nil) -> (MLXArray, WhisperLayerCache) {
        var x = input
        var next = WhisperLayerCache()
        let (y, kv) = attn(attnLn(x), mask: mask, cache: cache?.selfKV)
        x = x + y
        next.selfKV = kv
        if let crossAttn, let crossAttnLn {
            let (cy, crossKV) = crossAttn(crossAttnLn(x), xa: xa, cache: cache?.crossKV)
            x = x + cy
            next.crossKV = crossKV
        }
        x = x + mlp2(MLXNN.gelu(mlp1(mlpLn(x))))
        return (x, next)
    }
}

final class WhisperAudioEncoder: Module {
    @ModuleInfo var conv1: Conv1d
    @ModuleInfo var conv2: Conv1d
    @ModuleInfo var blocks: [WhisperBlock]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    let sinusoids: MLXArray  // computed, not in the checkpoint (Python: _positional_embedding)

    init(_ dims: WhisperDimensions, dtype: DType) {
        _conv1.wrappedValue = Conv1d(inputChannels: dims.nMels, outputChannels: dims.nAudioState,
                                     kernelSize: 3, padding: 1)
        _conv2.wrappedValue = Conv1d(inputChannels: dims.nAudioState, outputChannels: dims.nAudioState,
                                     kernelSize: 3, stride: 2, padding: 1)
        _blocks.wrappedValue = (0..<dims.nAudioLayer).map { _ in
            WhisperBlock(nState: dims.nAudioState, nHead: dims.nAudioHead, crossAttention: false)
        }
        _lnPost.wrappedValue = LayerNorm(dimensions: dims.nAudioState)
        sinusoids = WhisperAudioEncoder.sinusoids(length: dims.nAudioCtx, channels: dims.nAudioState).asType(dtype)
        super.init()
    }

    /// whisper.sinusoids, evaluated with the same float32 ops as Python.
    static func sinusoids(length: Int, channels: Int) -> MLXArray {
        let increment = log(10000.0) / Double(channels / 2 - 1)
        let inverse = MLX.exp(MLXArray.arange(channels / 2).asType(.float32) * Float(-increment))
        let scaled = MLXArray.arange(length).asType(.float32).expandedDimensions(axis: 1) * inverse.expandedDimensions(axis: 0)
        return concatenated([MLX.sin(scaled), MLX.cos(scaled)], axis: 1)
    }

    /// mel: (batch, frames, nMels) channels-last.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = MLXNN.gelu(conv1(mel))
        x = MLXNN.gelu(conv2(x))
        precondition(x.dim(1) == sinusoids.dim(0), "Whisper 输入音频长度不正确")
        x = x + sinusoids
        for block in blocks {
            x = block(x).0
        }
        return lnPost(x)
    }
}

final class WhisperTextDecoder: Module {
    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo(key: "positional_embedding") var positionalEmbedding: MLXArray
    @ModuleInfo var blocks: [WhisperBlock]
    @ModuleInfo var ln: LayerNorm
    let mask: MLXArray

    init(_ dims: WhisperDimensions, dtype: DType) {
        _tokenEmbedding.wrappedValue = Embedding(embeddingCount: dims.nVocab, dimensions: dims.nTextState)
        _positionalEmbedding.wrappedValue = MLXArray.zeros([dims.nTextCtx, dims.nTextState])
        _blocks.wrappedValue = (0..<dims.nTextLayer).map { _ in
            WhisperBlock(nState: dims.nTextState, nHead: dims.nTextHead, crossAttention: true)
        }
        _ln.wrappedValue = LayerNorm(dimensions: dims.nTextState)
        // create_additive_causal_mask(n_ctx).astype(dtype); in float16 the large negative
        // fill saturates to -inf, as it does in Python.
        let indices = MLXArray.arange(dims.nTextCtx)
        let upper = indices.expandedDimensions(axis: 1) .< indices.expandedDimensions(axis: 0)
        mask = (upper.asType(.float32) * Float(-1e9)).asType(dtype)
        super.init()
    }

    /// tokens: (batch, n) int32. Returns float logits (model dtype) and the updated caches.
    func callAsFunction(_ tokens: MLXArray, xa: MLXArray, cache: [WhisperLayerCache]?) -> (MLXArray, [WhisperLayerCache]) {
        let offset = cache?.first?.selfKV?.0.dim(1) ?? 0
        let n = tokens.dim(-1)
        var x = tokenEmbedding(tokens) + positionalEmbedding[offset..<(offset + n)]
        var next = [WhisperLayerCache]()
        for (i, block) in blocks.enumerated() {
            let (y, layerCache) = block(x, xa: xa, mask: mask, cache: cache?[i])
            x = y
            next.append(layerCache)
        }
        x = ln(x)
        return (tokenEmbedding.asLinear(x), next)
    }
}

final class WhisperModel: Module {
    let dims: WhisperDimensions
    @ModuleInfo var encoder: WhisperAudioEncoder
    @ModuleInfo var decoder: WhisperTextDecoder

    init(_ dims: WhisperDimensions, dtype: DType) {
        self.dims = dims
        _encoder.wrappedValue = WhisperAudioEncoder(dims, dtype: dtype)
        _decoder.wrappedValue = WhisperTextDecoder(dims, dtype: dtype)
        super.init()
    }
}
