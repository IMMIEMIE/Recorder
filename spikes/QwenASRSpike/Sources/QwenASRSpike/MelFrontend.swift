import Foundation
import Accelerate
import MLX

/// Whisper-style log-mel frontend, bit-matching transformers' WhisperFeatureExtractor
/// as used by mlx_audio's Qwen3-ASR preprocessing:
///   - slaney mel filterbank (201 freq bins -> 128 mels, 0–8000 Hz, slaney norm)
///   - center=True reflect padding (200 samples each side), hann(400), hop 160, power 2.0
///   - mel floor 1e-10, log10, drop last frame, clamp max-8, (x+4)/4
/// Audio is padded to 30 s (480 000 samples) exactly like `padding=True`.
struct MelFrontend {
    let nFft = 400
    let hop = 160
    let nSamples = 480_000
    let nMels = 128
    let sampleRate = 16_000

    let window: [Double]                   // hann(400), symmetric — debug-dumpable
    let filterBank: [Double]               // flattened [mel * 201 + bin] — debug-dumpable
    private let dftCos: [Double]            // flattened [bin * 400 + t]
    private let dftSin: [Double]

    init() {
        let nFft = self.nFft
        // hann window — torch.hann_window(400) is PERIODIC (2*pi/N), not symmetric
        window = (0..<nFft).map { 0.5 - 0.5 * cos(2.0 * .pi * Double($0) / Double(nFft)) }
        // DFT matrices for rfft bins 0...200
        let bins = nFft / 2 + 1
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
        // slaney mel filterbank: (128, 201)
        filterBank = MelFrontend.slaneyFilterBank(
            numFrequencyBins: bins, numMelFilters: nMels,
            minFrequency: 0.0, maxFrequency: 8000.0, samplingRate: sampleRate)
    }

    /// transformers audio_utils.mel_filter_bank with mel_scale="slaney", norm="slaney".
    private static func slaneyFilterBank(
        numFrequencyBins: Int, numMelFilters: Int,
        minFrequency: Double, maxFrequency: Double, samplingRate: Int
    ) -> [Double] {
        func hzToMel(_ f: Double) -> Double {
            f < 1000.0 ? 3.0 * f / 200.0 : 15.0 + log(f / 1000.0) * (27.0 / log(6.4))
        }
        func melToHz(_ m: Double) -> Double {
            m < 15.0 ? 200.0 * m / 3.0 : 1000.0 * exp((log(6.4) / 27.0) * (m - 15.0))
        }
        let melMin = hzToMel(minFrequency), melMax = hzToMel(maxFrequency)
        // mel points, then back to hz: numMelFilters + 2 center freqs
        let melFreqs = (0..<(numMelFilters + 2)).map {
            melToHz(melMin + (melMax - melMin) * Double($0) / Double(numMelFilters + 1))
        }
        let fftFreqs = (0..<numFrequencyBins).map {
            Double($0) * Double(samplingRate / 2) / Double(numFrequencyBins - 1)
        }
        // triangular filters with slaney area normalization
        var bank = [Double](repeating: 0, count: numMelFilters * numFrequencyBins)
        for m in 0..<numMelFilters {
            let lower = melFreqs[m], center = melFreqs[m + 1], upper = melFreqs[m + 2]
            // enorm = 2 / (upper - lower)  (slaney norm; librosa applies in mel space
            // via filter bandwidth — transformers divides by hz width of the band)
            let enorm = 2.0 / (upper - lower)
            for (i, f) in fftFreqs.enumerated() {
                let up = (f - lower) / (center - lower)
                let down = (upper - f) / (upper - center)
                let w = max(0.0, min(up, down)) * enorm
                bank[m * numFrequencyBins + i] = w
            }
        }
        return bank
    }

    /// np.pad(waveform, (200, 200), mode="reflect").
    private static func reflectPad(_ x: [Double], left: Int, right: Int) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(x.count + left + right)
        for i in (1...left).reversed() { out.append(x[i]) }           // x[200], x[199], ... x[1]
        out.append(contentsOf: x)
        for i in 0..<right { out.append(x[x.count - 2 - i]) }
        return out
    }

    /// input: float32 samples in [-1, 1) at 16 kHz mono.
    /// output: MLXArray (1, nMels, 3000) — (batch, mel, frames), zero-padded audio to 30 s.
    func logMel(_ samples: [Float]) -> MLXArray {
        // pad to 30 s with zeros (padding_value 0.0, padding=True)
        var padded = samples.map { Double($0) }
        padded.reserveCapacity(nSamples)
        if padded.count > nSamples { padded = Array(padded.prefix(nSamples)) }
        padded.append(contentsOf: [Double](repeating: 0, count: nSamples - padded.count))
        // reflect padding, center=True
        let centered = MelFrontend.reflectPad(padded, left: nFft / 2, right: nFft / 2)

        let numFramesTotal = 1 + (centered.count - nFft) / hop  // 3001 for 30 s
        let bins = nFft / 2 + 1

        // power spectrogram: (frames, bins) — DFT via matrix multiply in Double.
        // cblas_dgemm row-major, unambiguous layout (vDSP_mmulD semantics are not).
        var power = [Double](repeating: 0, count: numFramesTotal * bins)
        centered.withUnsafeBufferPointer { centeredPtr in
            for f in 0..<numFramesTotal {
                let base = f * hop
                var frame = [Double](repeating: 0, count: nFft)
                vDSP_vmulD(centeredPtr.baseAddress! + base, 1, window, 1, &frame, 1, vDSP_Length(nFft))
                var real = [Double](repeating: 0, count: bins)
                var imag = [Double](repeating: 0, count: bins)
                // real = frame (1x400) · cosM^T (400x201); cosM is [bin][t] row-major
                // beta must be 0: dgemm adds beta*C to the result
                cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                            1, Int32(bins), Int32(nFft), 1.0,
                            frame, Int32(nFft), dftCos, Int32(nFft), 0.0,
                            &real, Int32(bins))
                cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                            1, Int32(bins), Int32(nFft), 1.0,
                            frame, Int32(nFft), dftSin, Int32(nFft), 0.0,
                            &imag, Int32(bins))
                for k in 0..<bins {
                    power[f * bins + k] = real[k] * real[k] + imag[k] * imag[k]
                }
            }
        }

        // debug: dump power spectrogram for python-side diff
        if ProcessInfo.processInfo.environment["SPIKE_DEBUG"] == "1" {
            print("power[:8] =", power.prefix(8).map { Float($0) })
            power.withUnsafeBufferPointer { buf in
                try? Data(buffer: buf).write(to: URL(fileURLWithPath: "/tmp/swift_power.bin"))
            }
        }

        // drop last frame: [:, :-1]
        let frames = numFramesTotal - 1
        // mel: (mels, frames)
        var logSpec = [Float](repeating: 0, count: nMels * frames)
        var maxVal = -Double.infinity
        var melRow = [Double](repeating: 0, count: frames)
        filterBank.withUnsafeBufferPointer { fbPtr in
            power.withUnsafeBufferPointer { pPtr in
                for m in 0..<nMels {
                    // melRow = filterBank[m] (1x201) · power^T (201 x frames);
                    // power is (frames, bins) row-major, TransB yields its transpose
                    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                1, Int32(frames), Int32(bins), 1.0,
                                fbPtr.baseAddress! + m * bins, Int32(bins),
                                pPtr.baseAddress!, Int32(bins), 0.0,
                                &melRow, Int32(frames))
                    for t in 0..<frames {
                        let v = log10(max(1e-10, melRow[t]))
                        if v > maxVal { maxVal = v }
                        logSpec[m * frames + t] = Float(v)
                    }
                }
            }
        }
        // clamp + scale in float32 (python: float64 log, then asarray float32 AFTER clamp/scale —
        // transformers computes clamp in float64 then casts; we keep Double then cast)
        let floor = maxVal - 8.0
        for i in 0..<logSpec.count {
            let v = Double(logSpec[i])
            logSpec[i] = Float((max(v, floor) + 4.0) / 4.0)
        }
        return MLXArray(logSpec).reshaped(1, nMels, frames)
    }

    /// Frames marked valid by the rescaled attention mask: transformers samples
    /// the padded mask every hop then trims the last frame when len % hop != 0 —
    /// floor division covers both cases.
    func validFrames(sampleCount: Int) -> Int {
        let maxFrames = nSamples / hop
        return min(maxFrames, sampleCount / hop)
    }
}
