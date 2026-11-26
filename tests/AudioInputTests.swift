import Foundation
import AVFoundation

final class Result: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var levels: [Float] = []
    var ended = false
    var error = ""
    func append(_ pcm: Data, level: Float = 0) {
        lock.lock()
        data.append(pcm)
        levels.append(level)
        lock.unlock()
    }
    func finish() { lock.lock(); ended = true; lock.unlock() }
    func fail(_ message: String) { lock.lock(); error = message; lock.unlock() }
    func snapshot() -> (Int, Bool, String) {
        lock.lock(); defer { lock.unlock() }
        return (data.count / 2, ended, error)
    }
    func pcmSamples() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        return decodePCM16(data)
    }
    func maxLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        return levels.max() ?? 0
    }
}

func encodePCM16(_ samples: [Int16]) -> Data {
    var little = samples.map { $0.littleEndian }
    return little.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return Data() }
        return Data(bytes: base, count: samples.count * 2)
    }
}

func decodePCM16(_ data: Data) -> [Int16] {
    let count = data.count / 2
    var out = [Int16](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        let bound = base.assumingMemoryBound(to: Int16.self)
        for i in 0..<count { out[i] = Int16(littleEndian: bound[i]) }
    }
    return out
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AudioInputTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func testFileInput() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-audio-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let frames: AVAudioFrameCount = 14400  // Includes a short final read, not a whole 100 ms block.
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.25 } }
        try file.write(from: buffer)
    }
    let input = AdditionalAudioInput(), result = Result()
    input.onPCM = { pcm, level in result.append(pcm, level: level) }
    input.onEnd = { result.finish() }
    input.onFailure = { result.fail($0) }
    try input.startFile(url)
    for _ in 0..<200 {
        if result.snapshot().1 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let complete = result.snapshot()
    try check(complete.1 && complete.2.isEmpty, "File must finish without errors")
    try check(abs(complete.0 - Int(Double(frames) * 16000 / 44100)) <= 2, "16 kHz mono sample count must include converter tail: \(complete.0)")
    input.stop()
    try check(result.snapshot().0 == complete.0, "Stop after EOF must not duplicate tail")
    let second = Result()
    input.onPCM = { pcm, level in second.append(pcm, level: level) }
    input.onEnd = { second.finish() }
    try input.startFile(url)
    try await Task.sleep(nanoseconds: 130_000_000)
    input.stop()
    let stopped = second.snapshot()
    try await Task.sleep(nanoseconds: 250_000_000)
    try check(second.snapshot().0 == stopped.0 && !second.snapshot().1, "Stopped file must not keep emitting or finish a later session")
    do { try input.startFile(url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).wav")); throw NSError(domain: "Missing file accepted", code: 1) }
    catch let error as NSError { try check(error.domain != "Missing file accepted", "Missing file must fail") }
    print("PASS: stereo 44.1 kHz file → mono PCM16 16 kHz, paced reading, EOF tail, stop, restart and missing file")
}

func testMixerSoftLimiting() throws {
    // Unity gain below knee (no attenuation of normal speech).
    try check(PCM16AudioMixer.mixSample(0, 0) == 0, "Zero mix must be zero")
    try check(PCM16AudioMixer.mixSample(10000, 5000) == 15000, "Linear sum below knee must be exact")
    try check(PCM16AudioMixer.mixSample(-12000, -8000) == -20000, "Negative linear sum below knee must be exact")
    try check(PCM16AudioMixer.mixSample(28000, 0) == 28000, "Boundary at knee must be exact")
    try check(PCM16AudioMixer.mixSample(-28000, 0) == -28000, "Negative boundary at knee must be exact")

    // Soft-limiting above knee: monotonic, no Int16 wrap-around, no overflow.
    let midOver = PCM16AudioMixer.mixSample(20000, 15000) // sum = 35000
    let maxPos = PCM16AudioMixer.mixSample(Int16.max, Int16.max) // sum = 65534
    try check(midOver > 28000 && midOver <= Int16.max, "Positive soft limit out of bounds: \(midOver)")
    try check(maxPos >= midOver && maxPos <= Int16.max, "Soft limiter must stay monotonic and <= Int16.max: \(maxPos)")

    let midNeg = PCM16AudioMixer.mixSample(-20000, -15000) // sum = -35000
    let maxNeg = PCM16AudioMixer.mixSample(Int16.min, Int16.min) // sum = -65536
    try check(midNeg < -28000 && midNeg >= Int16.min, "Negative soft limit out of bounds: \(midNeg)")
    try check(maxNeg <= midNeg && maxNeg >= Int16.min, "Negative soft limiter must stay monotonic and >= Int16.min: \(maxNeg)")

    // Opposite phase cancellation.
    try check(PCM16AudioMixer.mixSample(20000, -20000) == 0, "Opposite phase samples must cancel")
    print("PASS: PCM16AudioMixer unity gain, soft-limiting, anti-clipping and no wrap-around")
}

func testMixerAlignmentSilencePaddingAndDrain() throws {
    let mixer = PCM16AudioMixer(frameSamples: 320, tickIntervalMs: 20, maxBufferedSamples: 1600)

    // 1. Dual-source aligned mix + RMS computation.
    let sysChunk = [Int16](repeating: 4000, count: 320)
    let micChunk = [Int16](repeating: 2000, count: 320)
    mixer.append(encodePCM16(sysChunk), to: .system)
    mixer.append(encodePCM16(micChunk), to: .microphone)
    guard let frame1 = mixer.mixNextFrame() else {
        throw NSError(domain: "AudioInputTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected mixed frame"])
    }
    let samples1 = decodePCM16(frame1.data)
    try check(samples1.count == 320, "Mixed frame must have 320 samples, got \(samples1.count)")
    try check(samples1.allSatisfy { $0 == 6000 }, "Aligned dual-source mix must equal 6000")
    let expectedRMS: Float = 6000.0 / 32768.0
    try check(abs(frame1.rms - expectedRMS) < 0.001, "Mixed RMS mismatch: \(frame1.rms) vs \(expectedRMS)")

    // 2. Single-source silence padding (system active, mic temporarily silent/absent).
    mixer.append(encodePCM16([Int16](repeating: 5000, count: 320)), to: .system)
    guard let frame2 = mixer.mixNextFrame() else {
        throw NSError(domain: "AudioInputTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected system-only frame"])
    }
    let samples2 = decodePCM16(frame2.data)
    try check(samples2.allSatisfy { $0 == 5000 }, "System-only frame must zero-pad mic without blocking")
    try check(abs(frame2.rms - (5000.0 / 32768.0)) < 0.001, "System-only RMS mismatch")

    // 3. Single-source silence padding (mic active, system silent/absent, partial frame).
    mixer.append(encodePCM16([Int16](repeating: -3000, count: 100)), to: .microphone)
    guard let frame3 = mixer.mixNextFrame() else {
        throw NSError(domain: "AudioInputTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Expected mic-only frame"])
    }
    let samples3 = decodePCM16(frame3.data)
    try check(samples3.count == 320, "Partial frame must be zero-padded to frameSamples")
    try check(samples3[0..<100].allSatisfy { $0 == -3000 }, "First 100 samples must carry mic audio")
    try check(samples3[100..<320].allSatisfy { $0 == 0 }, "Remainder must be zero-padded")

    // 4. Both-empty tick with emitSilenceIfEmpty: true vs false.
    let silenceFrame = mixer.mixNextFrame(emitSilenceIfEmpty: true)
    try check(silenceFrame != nil && silenceFrame!.data.count == 640 && silenceFrame!.rms == 0, "Silence tick must output 320 zero samples")
    let skipped = mixer.mixNextFrame(emitSilenceIfEmpty: false)
    try check(skipped == nil, "Empty tick with emitSilenceIfEmpty=false must return nil")

    // 5. Backlog cap prevents unbounded queue buildup / clock drift.
    let oversized = (0..<3000).map { Int16($0) }
    mixer.append(encodePCM16(oversized), to: .system)
    let counts = mixer.bufferedSampleCounts()
    try check(counts.system == 1600, "System buffer must be capped at maxBufferedSamples (1600), got \(counts.system)")
    let oldestKept = decodePCM16(mixer.mixNextFrame()!.data).first
    try check(oldestKept == 1400, "Backlog cap must keep newest samples (expected first=1400, got \(String(describing: oldestKept)))")
    _ = mixer.drain()

    // 6. Drain flushes asymmetric trailing audio without inventing extra trailing silence.
    mixer.append(encodePCM16([Int16](repeating: 1000, count: 450)), to: .system)
    mixer.append(encodePCM16([Int16](repeating: 500, count: 200)), to: .microphone)
    let drained = mixer.drain()
    let drainedSamples = drained.flatMap { decodePCM16($0.data) }
    try check(drainedSamples.count == 450, "Drain must preserve exact max trailing sample count (450), got \(drainedSamples.count)")
    try check(drainedSamples[0..<200].allSatisfy { $0 == 1500 }, "Overlapping drained tail must be mixed")
    try check(drainedSamples[200..<450].allSatisfy { $0 == 1000 }, "Non-overlapping drained tail must be preserved")
    try check(mixer.drain().isEmpty, "Second drain must emit nothing")
    print("PASS: PCM16AudioMixer dual-source alignment, silence padding, backlog cap and exact drain")
}

func testMixerLiveStartStopAndRestart() async throws {
    let mixer = PCM16AudioMixer(frameSamples: 320, tickIntervalMs: 20, maxBufferedSamples: 8000)
    let session1 = Result()
    mixer.onPCM = { pcm, level in session1.append(pcm, level: level) }

    mixer.start()
    mixer.append(encodePCM16([Int16](repeating: 4000, count: 640)), to: .system)
    mixer.append(encodePCM16([Int16](repeating: 3000, count: 640)), to: .microphone)
    try await Task.sleep(nanoseconds: 55_000_000)
    // Append trailing tail right before stop; stop() must synchronously drain it.
    mixer.append(encodePCM16([Int16](repeating: 9000, count: 150)), to: .microphone)
    mixer.stop()

    let countAfterStop = session1.snapshot().0
    try check(countAfterStop >= 790, "Live run + stop drain must include all fed samples, got \(countAfterStop)")
    try check(session1.pcmSamples().suffix(150).allSatisfy { $0 == 9000 }, "Stop must drain trailing samples cleanly")
    try check(session1.maxLevel() > 0.2, "Mixed level meter must reflect mixed audio")

    // Verify no emissions occur after stop.
    try await Task.sleep(nanoseconds: 70_000_000)
    try check(session1.snapshot().0 == countAfterStop, "Stopped mixer must not keep emitting")

    // Verify clean restart with no leftover state from previous session.
    let session2 = Result()
    mixer.onPCM = { pcm, level in session2.append(pcm, level: level) }
    mixer.start()
    mixer.append(encodePCM16([Int16](repeating: 2500, count: 320)), to: .system)
    mixer.stop()
    let samples2 = session2.pcmSamples()
    try check(samples2.count >= 320 && samples2.suffix(320).allSatisfy { $0 == 2500 }, "Restarted mixer must emit fresh session audio")
    print("PASS: PCM16AudioMixer live timer cadence, stop drain and clean restart")
}

func testAudioInputSourcePersistence() throws {
    let suite = "test.audio-source-persistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // Default when empty is microphone.
    let initial = AudioInputSource.restore(defaults: defaults)
    try check(initial.source == .microphone && initial.fileURL == nil, "Empty defaults must restore microphone")

    // Standard live modes restore directly.
    for mode in AudioInputSource.liveModes {
        AudioInputSource.save(source: mode, fileURL: nil, defaults: defaults)
        let restored = AudioInputSource.restore(defaults: defaults)
        try check(restored.source == mode, "Mode \(mode.rawValue) must persist and restore")
    }

    // File mode restores when file exists, falls back safely to microphone when file is missing.
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("audio-persist-\(UUID().uuidString).wav")
    FileManager.default.createFile(atPath: tempFile.path, contents: Data([0, 1, 2, 3]))
    AudioInputSource.save(source: .file, fileURL: tempFile, defaults: defaults)
    let restoredExisting = AudioInputSource.restore(defaults: defaults)
    try check(restoredExisting.source == .file && restoredExisting.fileURL?.path == tempFile.path, "Existing saved file must restore file mode")

    try? FileManager.default.removeItem(at: tempFile)
    let restoredMissing = AudioInputSource.restore(defaults: defaults)
    try check(restoredMissing.source == .microphone && restoredMissing.fileURL == nil, "Missing saved file must fall back safely to microphone")

    // Unknown raw value falls back safely to microphone.
    defaults.set("invalid_mode", forKey: AudioInputSource.defaultsKey)
    try check(AudioInputSource.restore(defaults: defaults).source == .microphone, "Unknown mode must fall back to microphone")
    print("PASS: AudioInputSource persistence and missing-file fallback")
}

@main struct AudioInputTests {
    static func main() async throws {
        try await testFileInput()
        try testMixerSoftLimiting()
        try testMixerAlignmentSilencePaddingAndDrain()
        try await testMixerLiveStartStopAndRestart()
        try testAudioInputSourcePersistence()
    }
}
