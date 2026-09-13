import AVFoundation
import AudioToolbox
import CoreAudio

struct Microphone: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

final class AudioCapture {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let conversionLock = NSLock()
    var onPCM: ((Data, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private var observer: NSObjectProtocol?

    static func microphones() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            _ = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return Microphone(id: id, name: name?.takeUnretainedValue() as String? ?? "麦克风")
        }
    }

    func start(device: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if device != 0, let unit = input.audioUnit {
            var id = device
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw error("无法使用所选麦克风，请刷新设备列表") }
        }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw error("麦克风格式无效，请重新选择设备") }
        self.converter = converter
        self.engine = engine
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] inputBuffer, _ in
            guard let self else { return }
            self.conversionLock.lock()
            defer { self.conversionLock.unlock() }
            let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * 16000 / source.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return inputBuffer
            }
            if status == .error { self.onFailure?("音频重采样失败"); return }
            self.emit(output)
        }
        do { try engine.start() } catch { stop(); throw error }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            guard let engine, !engine.isRunning else { return }
            self?.onFailure?("音频设备发生变化；已停止录音，请刷新设备后重新开始")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        conversionLock.lock()
        if let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) {
            var error: NSError?
            for _ in 0..<4 {
                let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                emit(output)
                if status == .endOfStream || status == .error || output.frameLength == 0 { break }
                output.frameLength = 0
            }
        }
        engine = nil
        converter = nil
        conversionLock.unlock()
    }

    private func emit(_ output: AVAudioPCMBuffer) {
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        var sum: Float = 0
        for i in 0..<count { let v = Float(samples[i]) / 32768; sum += v * v }
        onPCM?(Data(bytes: samples, count: count * 2), sqrt(sum / Float(count)))
    }

    private func error(_ text: String) -> NSError { NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
}
