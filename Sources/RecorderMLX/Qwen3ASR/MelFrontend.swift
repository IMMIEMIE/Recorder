import Accelerate
import Foundation
import MLX

/// Whisper-style log-mel frontend matching transformers' WhisperFeatureExtractor as mlx_audio's
/// Qwen3-ASR calls it (`padding=True, truncation=False`: no 30 s padding, the log-mel max is taken
/// over the real frames only):
///   - slaney mel filterbank (201 bins -> 128 mels, 0-8000 Hz, slaney norm)
///   - center=True reflect padding (200 each side), periodic hann(400), hop 160, power 2
///   - mel floor 1e-10, log10, drop the last frame, clamp to max-8, (x+4)/4
/// Math runs in Double through cblas_dgemm (row-major; vDSP_mmulD proved unreliable, and beta
/// must be 0 so reused outputs are overwritten, not accumulated). See docs/SPIKE-RESULTS.md §5.
struct MelFrontend {
    static let sampleRate = 16_000
    let nFft = 400
    let hop = 160
    let nMels: Int

    private let window: [Double]
    private let filterBank: [Double]  // (nMels, bins) row-major
    private let dftCos: [Double]      // (bins, nFft) row-major
    private let dftSin: [Double]

    init(nMels: Int = 128) {
        self.nMels = nMels
        let bins = nFft / 2 + 1
        // torch.hann_window(400) is periodic (2π/N), not symmetric.
        window = (0..<nFft).map { 0.5 - 0.5 * cos(2.0 * .pi * Double($0) / Double(nFft)) }
        var cosM = [Double](repeating: 0, count: bins * nFft)
        var sinM = [Double](repeating: 0, count: bins * nFft)
        for k in 0..<bins {
            for t in 0..<nFft {
                let angle = 2.0 * .pi * Double(k) * Double(t) / Double(nFft)
                cosM[k * nFft + t] = cos(angle)
                sinM[k * nFft + t] = sin(angle)
            }
        }
        dftCos = cosM
        dftSin = sinM
        filterBank = MelFrontend.slaneyFilterBank(bins: bins, mels: nMels, maxFrequency: 8000)
    }

    /// transformers audio_utils.mel_filter_bank(mel_scale="slaney", norm="slaney"), fmin 0.
    private static func slaneyFilterBank(bins: Int, mels: Int, maxFrequency: Double) -> [Double] {
        func hzToMel(_ f: Double) -> Double { f < 1000 ? 3 * f / 200 : 15 + log(f / 1000) * (27 / log(6.4)) }
        func melToHz(_ m: Double) -> Double { m < 15 ? 200 * m / 3 : 1000 * exp((log(6.4) / 27) * (m - 15)) }
        let melMax = hzToMel(maxFrequency)
        let centers = (0..<(mels + 2)).map { melToHz(melMax * Double($0) / Double(mels + 1)) }
        let fftFreqs = (0..<bins).map { Double($0) * Double(sampleRate / 2) / Double(bins - 1) }
        var bank = [Double](repeating: 0, count: mels * bins)
        for m in 0..<mels {
            let lower = centers[m], center = centers[m + 1], upper = centers[m + 2]
            let enorm = 2 / (upper - lower)
            for (i, f) in fftFreqs.enumerated() {
                let up = (f - lower) / (center - lower)
                let down = (upper - f) / (upper - center)
                bank[m * bins + i] = max(0, min(up, down)) * enorm
            }
        }
        return bank
    }

    /// Frames covered by the rescaled attention mask: floor(samples / hop).
    static func validFrames(sampleCount: Int) -> Int { sampleCount / 160 }

    /// samples: 16 kHz mono in [-1, 1), at least 201 samples (callers pad to 1 s).
    /// Returns (1, nMels, samples / hop).
    func logMel(_ samples: [Float]) -> MLXArray {
        let pad = nFft / 2
        let n = samples.count
        precondition(n > pad, "音频过短，无法计算梅尔频谱")
        // np.pad(mode="reflect"): x[pad]...x[1], x, x[n-2]...x[n-1-pad]
        var centered = [Double]()
        centered.reserveCapacity(n + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { centered.append(Double(samples[i])) }
        for s in samples { centered.append(Double(s)) }
        for i in 0..<pad { centered.append(Double(samples[n - 2 - i])) }

        let bins = nFft / 2 + 1
        let frames = n / hop  // 1 + n/hop STFT frames, minus the dropped last one

        // Windowed frames (frames, nFft).
        var framed = [Double](repeating: 0, count: frames * nFft)
        centered.withUnsafeBufferPointer { src in
            framed.withUnsafeMutableBufferPointer { dst in
                for f in 0..<frames {
                    vDSP_vmulD(src.baseAddress! + f * hop, 1, window, 1, dst.baseAddress! + f * nFft, 1, vDSP_Length(nFft))
                }
            }
        }
        // Real/imaginary DFT parts (frames, bins) = framed · dft^T.
        var real = [Double](repeating: 0, count: frames * bins)
        var imag = [Double](repeating: 0, count: frames * bins)
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(bins), Int32(nFft), 1.0,
                    framed, Int32(nFft), dftCos, Int32(nFft), 0.0, &real, Int32(bins))
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(bins), Int32(nFft), 1.0,
                    framed, Int32(nFft), dftSin, Int32(nFft), 0.0, &imag, Int32(bins))
        var power = [Double](repeating: 0, count: frames * bins)
        for i in 0..<power.count { power[i] = real[i] * real[i] + imag[i] * imag[i] }

        // Mel energies (frames, nMels) = power · filterBank^T.
        var mel = [Double](repeating: 0, count: frames * nMels)
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(nMels), Int32(bins), 1.0,
                    power, Int32(bins), filterBank, Int32(bins), 0.0, &mel, Int32(nMels))

        var logSpec = [Double](repeating: 0, count: frames * nMels)
        var maxVal = -Double.infinity
        for i in 0..<mel.count {
            let v = log10(max(1e-10, mel[i]))
            logSpec[i] = v
            if v > maxVal { maxVal = v }
        }
        // Transpose to (nMels, frames) while clamping and scaling.
        let floor = maxVal - 8
        var out = [Float](repeating: 0, count: nMels * frames)
        for t in 0..<frames {
            for m in 0..<nMels {
                out[m * frames + t] = Float((max(logSpec[t * nMels + m], floor) + 4) / 4)
            }
        }
        return MLXArray(out).reshaped(1, nMels, frames)
    }
}
