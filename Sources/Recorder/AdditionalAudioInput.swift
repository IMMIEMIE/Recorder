import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Audio capture input modes supported on macOS.
enum AudioInputSource: String, CaseIterable {
    case microphone = "microphone"
    case system = "system"
    case systemMix = "system_mix"
    case file = "file"

    static let defaultsKey = "audio.input.source"
    static let filePathKey = "audio.input.filePath"
    /// Live capture modes shown in the main workspace mode bar and menu bar quick switcher.
    static let liveModes: [AudioInputSource] = [.microphone, .system, .systemMix]

    var titleKey: String {
        switch self {
        case .microphone: return "麦克风"
        case .system: return "系统声音"
        case .systemMix: return "系统声音 + 麦克风"
        case .file: return "音频文件"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .systemMix: return "person.2.wave.2.fill"
        case .file: return "doc.waveform"
        }
    }

    var usesMicrophone: Bool { self == .microphone || self == .systemMix }
    var usesSystemAudio: Bool { self == .system || self == .systemMix }

    /// Restores the last selected audio source from UserDefaults.
    /// If "file" was saved but the file is missing or unreadable, falls back safely to `.microphone`.
    static func restore(
        defaults: UserDefaults,
        fileExists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> (source: AudioInputSource, fileURL: URL?) {
        let savedPath = defaults.string(forKey: filePathKey)
        let validFileURL: URL? = {
            guard let path = savedPath, !path.isEmpty, fileExists(path) else { return nil }
            return URL(fileURLWithPath: path)
        }()
        guard let raw = defaults.string(forKey: defaultsKey),
              let saved = AudioInputSource(rawValue: raw) else {
            return (.microphone, validFileURL)
        }
        if saved == .file {
            guard let url = validFileURL else { return (.microphone, nil) }
            return (.file, url)
        }
        return (saved, validFileURL)
    }

    static func save(source: AudioInputSource, fileURL: URL?, defaults: UserDefaults) {
        defaults.set(source.rawValue, forKey: defaultsKey)
        if let path = fileURL?.path, !path.isEmpty {
            defaults.set(path, forKey: filePathKey)
        } else {
            defaults.removeObject(forKey: filePathKey)
        }
    }
}

/// Fixed-cadence software mixer that combines system audio and microphone PCM16 (16 kHz mono)
/// streams without blocking either source. Soft-limits peaks above the knee to prevent clipping.
final class PCM16AudioMixer {
    enum Channel {
        case system
        case microphone
    }

    private struct SampleFIFO {
        private var storage: [Int16] = []
        private var head = 0

        var count: Int { storage.count - head }
        var isEmpty: Bool { head >= storage.count }

        mutating func append(_ samples: [Int16], maxCount: Int) {
            guard !samples.isEmpty else { return }
            storage.append(contentsOf: samples)
            if count > maxCount {
                head = storage.count - maxCount
            }
            compactIfNeeded()
        }

        mutating func pop(upTo maxSamples: Int) -> [Int16] {
            let available = min(maxSamples, count)
            guard available > 0 else { return [] }
            let slice = Array(storage[head..<(head + available)])
            head += available
            compactIfNeeded()
            return slice
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
        }

        private mutating func compactIfNeeded() {
            if head >= storage.count {
                storage.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 4096 && head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
        }
    }

    static let sampleRate = 16000
    static let defaultFrameSamples = 320     // 20 ms at 16 kHz
    static let defaultTickIntervalMs = 20
    static let defaultMaxBufferedSamples = 8000  // 500 ms cap per channel

    private static let softLimitKnee: Int32 = 28000
    private static let softLimitCeiling: Double = 32767.0
    private static let softLimitHeadroom: Double = 32767.0 - 28000.0

    let frameSamples: Int
    let tickIntervalMs: Int
    let maxBufferedSamples: Int

    var onPCM: ((Data, Float) -> Void)?

    private let queue = DispatchQueue(label: "recorder.audio-mixer")
    private var timer: DispatchSourceTimer?
    private var active = false
    private var systemBuffer = SampleFIFO()
    private var micBuffer = SampleFIFO()

    init(
        frameSamples: Int = PCM16AudioMixer.defaultFrameSamples,
        tickIntervalMs: Int = PCM16AudioMixer.defaultTickIntervalMs,
        maxBufferedSamples: Int = PCM16AudioMixer.defaultMaxBufferedSamples
    ) {
        self.frameSamples = max(1, frameSamples)
        self.tickIntervalMs = max(1, tickIntervalMs)
        self.maxBufferedSamples = max(self.frameSamples, maxBufferedSamples)
    }

    func start() {
        queue.sync {
            timer?.cancel()
            timer = nil
            systemBuffer.removeAll()
            micBuffer.removeAll()
            active = true
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + .milliseconds(tickIntervalMs),
                repeating: .milliseconds(tickIntervalMs),
                leeway: .milliseconds(2)
            )
            source.setEventHandler { [weak self] in
                guard let self, self.active else { return }
                _ = self.mixNextFrameLocked(emitSilenceIfEmpty: true)
            }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            let wasActive = active
            active = false
            if wasActive {
                _ = drainLocked()
            }
            systemBuffer.removeAll()
            micBuffer.removeAll()
        }
    }

    func append(_ data: Data, to channel: Channel) {
        let count = data.count / 2
        guard count > 0 else { return }
        var samples = [Int16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                samples[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            }
        }
        queue.sync {
            switch channel {
            case .system:
                systemBuffer.append(samples, maxCount: maxBufferedSamples)
            case .microphone:
                micBuffer.append(samples, maxCount: maxBufferedSamples)
            }
        }
    }

    func bufferedSampleCounts() -> (system: Int, microphone: Int) {
        queue.sync { (systemBuffer.count, micBuffer.count) }
    }

    @discardableResult
    func mixNextFrame(emitSilenceIfEmpty: Bool = true) -> (data: Data, rms: Float)? {
        queue.sync { mixNextFrameLocked(emitSilenceIfEmpty: emitSilenceIfEmpty) }
    }

    @discardableResult
    func drain() -> [(data: Data, rms: Float)] {
        queue.sync { drainLocked() }
    }

    private func mixNextFrameLocked(emitSilenceIfEmpty: Bool) -> (data: Data, rms: Float)? {
        if !emitSilenceIfEmpty && systemBuffer.isEmpty && micBuffer.isEmpty {
            return nil
        }
        let sys = systemBuffer.pop(upTo: frameSamples)
        let mic = micBuffer.pop(upTo: frameSamples)
        return emitMixed(system: sys, mic: mic, count: frameSamples)
    }

    private func drainLocked() -> [(data: Data, rms: Float)] {
        var emitted: [(data: Data, rms: Float)] = []
        while max(systemBuffer.count, micBuffer.count) > 0 {
            let remaining = max(systemBuffer.count, micBuffer.count)
            let count = min(frameSamples, remaining)
            let sys = systemBuffer.pop(upTo: count)
            let mic = micBuffer.pop(upTo: count)
            emitted.append(emitMixed(system: sys, mic: mic, count: count))
        }
        return emitted
    }

    private func emitMixed(system: [Int16], mic: [Int16], count: Int) -> (data: Data, rms: Float) {
        var mixed = [Int16](repeating: 0, count: count)
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = i < system.count ? system[i] : 0
            let m = i < mic.count ? mic[i] : 0
            let out = Self.mixSample(s, m)
            mixed[i] = out
            let norm = Float(out) / 32768.0
            sumSquares += norm * norm
        }
        let rms = count > 0 ? sqrt(sumSquares / Float(count)) : 0
        let data = mixed.withUnsafeBufferPointer { ptr -> Data in
            guard let base = ptr.baseAddress else { return Data() }
            return Data(bytes: base, count: count * 2)
        }
        onPCM?(data, rms)
        return (data, rms)
    }

    /// Mixes two PCM16 samples with unity gain below the soft-limit knee and smooth tanh compression above it.
    static func mixSample(_ a: Int16, _ b: Int16) -> Int16 {
        let sum = Int32(a) + Int32(b)
        let magnitude = abs(sum)
        if magnitude <= softLimitKnee {
            return Int16(sum)
        }
        let excess = Double(magnitude - softLimitKnee)
        let compressed = Double(softLimitKnee) + softLimitHeadroom * tanh(excess / softLimitHeadroom)
        let signed = sum >= 0 ? compressed : -compressed
        let clamped = max(-32768.0, min(softLimitCeiling, signed.rounded()))
        return Int16(clamped)
    }
}

/// Converts bounded input buffers; all access is serialized on the input queue.
final class InputPCMConverter {
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    var onPCM: ((Data, Float) -> Void)?

    func feed(_ input: AVAudioPCMBuffer) throws {
        if source != input.format {
            source = input.format
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { throw AIError.message("无法转换所选音源的音频格式") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 64
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? AIError.message("音频重采样失败") as NSError }
        emit(output)
    }
    func finish() {
        guard let converter else { return }
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
        for _ in 0..<4 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            emit(output)
            if status == .endOfStream || status == .error || output.frameLength == 0 { break }
            output.frameLength = 0
        }
        reset()
    }
    func reset() { converter = nil; source = nil }
    private func emit(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { let value = Float(samples[i]) / 32768; sum += value * value }
        onPCM?(Data(bytes: samples, count: count * 2), sqrt(sum / Float(count)))
    }
}

final class AdditionalAudioInput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPCM: ((Data, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private let queue = DispatchQueue(label: "recorder.additional-audio")
    private let converter = InputPCMConverter()
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var stream: SCStream?
    private var generation = UUID()

    override init() {
        super.init()
        converter.onPCM = { [weak self] data, level in self?.onPCM?(data, level) }
    }
    private var lastFileFrame: AVAudioFramePosition = 0

    func startFile(_ url: URL, atFrame: AVAudioFramePosition = 0) throws {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0, input.processingFormat.sampleRate > 0 else { throw AIError.message("音频文件为空或格式不受支持") }
        input.framePosition = min(atFrame, input.length)
        queue.sync {
            lastFileFrame = atFrame
            file = input
            converter.reset()
            let frames = AVAudioFrameCount(input.processingFormat.sampleRate / 10)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, let file = self.file else { return }
                do {
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
                    try file.read(into: buffer, frameCount: frames)
                    self.lastFileFrame = file.framePosition
                    if buffer.frameLength > 0 { try self.converter.feed(buffer) }
                    if file.framePosition >= file.length || buffer.frameLength == 0 {
                        self.converter.finish()
                        self.timer?.cancel(); self.timer = nil; self.file = nil
                        self.onEnd?()
                    }
                } catch {
                    self.timer?.cancel(); self.timer = nil; self.file = nil
                    self.onFailure?("读取音频文件失败：\(error.localizedDescription)")
                }
            }
            self.timer = timer
            timer.resume()
        }
    }
    func startSystem() async throws {
        let token = queue.sync { generation }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AIError.message("未找到可采集系统声音的显示器") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        let valid = queue.sync { () -> Bool in
            guard generation == token else { return false }
            self.stream = stream; converter.reset(); return true
        }
        guard valid else { throw CancellationError() }
        try await stream.startCapture()
        if queue.sync(execute: { generation != token }) {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }
    @discardableResult
    func stop() -> AVAudioFramePosition {
        let (old, frame) = queue.sync { () -> (SCStream?, AVAudioFramePosition) in
            generation = UUID()
            timer?.cancel(); timer = nil; file = nil
            converter.finish()
            let old = stream; stream = nil
            return (old, lastFileFrame)
        }
        if let old { Task { try? await old.stopCapture() } }
        return frame
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat? else { return }
        let count = sampleBuffer.numSamples
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard result == noErr else { onFailure?("无法读取系统音频数据（\(result)）"); return }
        do { try converter.feed(buffer) }
        catch { onFailure?(error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFailure?("系统声音采集已中断：\(error.localizedDescription)")
        }
    }
}
