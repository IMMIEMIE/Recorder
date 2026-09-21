import AVFoundation
import ScreenCaptureKit
import CoreMedia

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
    func startFile(_ url: URL) throws {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0, input.processingFormat.sampleRate > 0 else { throw AIError.message("音频文件为空或格式不受支持") }
        queue.sync {
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
    func stop() {
        let old = queue.sync { () -> SCStream? in
            generation = UUID()
            timer?.cancel(); timer = nil; file = nil
            converter.finish()
            let old = stream; stream = nil
            return old
        }
        if let old { Task { try? await old.stopCapture() } }
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
