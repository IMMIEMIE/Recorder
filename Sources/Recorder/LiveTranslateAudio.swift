import AVFoundation

/// Reassembles PCM16 samples across websocket messages; duplicate events never replay sound.
struct LiveTranslateAudioDecoder {
    private var seen = Set<String>()
    private var completed = Set<String>()
    private var tails: [String: UInt8] = [:]

    mutating func consume(_ event: [String: Any]) throws -> Data? {
        guard let type = event["type"] as? String, ["response.audio.delta", "response.audio.done"].contains(type) else { return nil }
        if let id = event["event_id"] as? String, !seen.insert(id).inserted { return nil }
        guard let item = event["item_id"] as? String else { throw AIError.message("译音缺少消息标识") }
        guard !completed.contains(item) else { return nil }
        if type == "response.audio.done" {
            completed.insert(item)
            guard tails.removeValue(forKey: item) == nil else { throw AIError.message("译音数据不完整，已停止播放") }
            return nil
        }
        guard let encoded = event["delta"] as? String, let chunk = Data(base64Encoded: encoded) else {
            throw AIError.message("译音数据格式无效，已停止播放")
        }
        var data = Data()
        if let tail = tails.removeValue(forKey: item) { data.append(tail) }
        data.append(chunk)
        if data.count % 2 == 1 { tails[item] = data.removeLast() }
        return data.isEmpty ? nil : data
    }
    var hasIncompleteSample: Bool { !tails.isEmpty }
    static func buffer(_ pcm: Data) throws -> AVAudioPCMBuffer {
        guard !pcm.isEmpty, pcm.count % 2 == 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw AIError.message("无法解码译音") }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBytes { raw in
            for index in 0..<Int(buffer.frameLength) {
                let word = UInt16(raw[index * 2]) | (UInt16(raw[index * 2 + 1]) << 8)
                samples[index] = Float(Int16(bitPattern: word)) / 32768
            }
        }
        return buffer
    }
}

/// Delayed mode releases whole utterances only after source, translation and audio are final.
/// It uses the server's source/output associations, including when those arrive after the audio.
struct LiveTranslatePlaybackQueue {
    let timing: LiveTranslatePlaybackTiming
    private var decoder = LiveTranslateAudioDecoder()
    private var buffers: [String: Data] = [:]
    private var audioDone = Set<String>()
    private var released = Set<String>()
    private var bufferedBytes = 0

    init(timing: LiveTranslatePlaybackTiming) {
        self.timing = timing
    }

    var hasPendingAudio: Bool { bufferedBytes > 0 }
    var hasIncompleteSample: Bool { decoder.hasIncompleteSample }

    mutating func consume(_ event: [String: Any], transcripts: LiveTranslateEvents) throws -> [Data] {
        let pcm = try decoder.consume(event)
        if timing == .streaming { return pcm.map { [$0] } ?? [] }
        if let id = event["item_id"] as? String {
            if let pcm, !released.contains(id) {
                guard bufferedBytes + pcm.count <= 24000 * 2 * 30 else {
                    throw AIError.message("等待定稿的译音超过 30 秒，已停止本次播放；字幕继续更新")
                }
                buffers[id, default: Data()].append(pcm); bufferedBytes += pcm.count
            }
            if event["type"] as? String == "response.audio.done" { audioDone.insert(id) }
        }
        var ready: [Data] = []
        for source in transcripts.order {
            guard let row = transcripts.rows[source] else { continue }
            let waiting = row.outputs.filter { !released.contains($0) }
            if !row.outputs.isEmpty && waiting.isEmpty { continue }
            // An earlier utterance must not be overtaken by later completed output.
            guard row.source.done else { break }
            if row.outputs.isEmpty {
                if row.source.text.isEmpty { continue }
                break
            }
            guard waiting.allSatisfy({ audioDone.contains($0) && transcripts.outputs[$0]?.done == true }) else { break }
            for output in waiting {
                released.insert(output)
                if let data = buffers.removeValue(forKey: output) {
                    bufferedBytes -= data.count; ready.append(data)
                }
            }
        }
        return ready
    }
}

/// Session audio stays in memory; completed clips survive recording restarts until history is cleared.
struct LiveTranslateReplayCache {
    private var decoder = LiveTranslateAudioDecoder()
    private var pending: [String: Data] = [:]
    private var done = Set<String>()
    private var rejected = Set<String>()
    private var finalized = Set<String>()
    private var clips: [String: Data] = [:]
    private var order: [String] = []
    private var pendingBytes = 0
    private var clipBytes = 0
    private(set) var revision = 0
    let capacity: Int
    init(capacity: Int = 128 * 1024 * 1024) { self.capacity = capacity }
    func audio(for transcriptID: String) -> Data? { clips[transcriptID] }
    mutating func beginSession() {
        decoder = LiveTranslateAudioDecoder(); pending.removeAll(); done.removeAll()
        rejected.removeAll(); finalized.removeAll(); pendingBytes = 0
    }
    mutating func clear() {
        beginSession(); clips.removeAll(); order.removeAll(); clipBytes = 0; revision += 1
    }
    mutating func consume(_ event: [String: Any], transcripts: LiveTranslateEvents, session: String) {
        let id = event["item_id"] as? String ?? ""
        do {
            if let pcm = try decoder.consume(event), !rejected.contains(id) {
                // Match the player's per-clip bound; never cache a truncated clip as replayable.
                if (pending[id]?.count ?? 0) + pcm.count > 24000 * 2 * 30 || pendingBytes + pcm.count > capacity {
                    pendingBytes -= pending.removeValue(forKey: id)?.count ?? 0; rejected.insert(id)
                } else { pending[id, default: Data()].append(pcm); pendingBytes += pcm.count }
            }
            if event["type"] as? String == "response.audio.done" { done.insert(id) }
        } catch {
            pendingBytes -= pending.removeValue(forKey: id)?.count ?? 0; rejected.insert(id)
        }
        for source in transcripts.order {
            guard !finalized.contains(source), let row = transcripts.rows[source], row.source.done,
                  !row.outputs.isEmpty, transcripts.translation(for: row).done,
                  row.outputs.allSatisfy({ done.contains($0) || rejected.contains($0) }) else { continue }
            finalized.insert(source)
            var pcm = Data()
            for output in row.outputs {
                if let data = pending.removeValue(forKey: output) { pendingBytes -= data.count; pcm.append(data) }
            }
            guard !pcm.isEmpty, pcm.count <= min(capacity, 24000 * 2 * 30),
                  row.outputs.allSatisfy({ !rejected.contains($0) }) else { continue }
            while clipBytes + pcm.count > capacity, !order.isEmpty {
                clipBytes -= clips.removeValue(forKey: order.removeFirst())?.count ?? 0
            }
            let key = "\(session):live:\(source)"
            clips[key] = pcm; order.append(key); clipBytes += pcm.count; revision += 1
        }
    }
}

/// Main-thread controlled player; completion callbacks return to the main queue.
final class LiveTranslateAudioPlayer {
    var onFailure: ((String) -> Void)?
    private let engineFactory: () -> AVAudioEngine
    init(engineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() }) { self.engineFactory = engineFactory }
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var generation = UUID()
    private var queuedFrames = 0
    private var drained: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var drainTimeout: DispatchWorkItem?

    func start(volume: Float) throws {
        stop()
        let engine = engineFactory()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!)
        player.volume = volume
        try engine.start()
        player.play()
        self.engine = engine; self.node = player
        let token = generation
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.fail("译音输出设备发生变化，已停止播放；字幕继续更新")
        }
    }
    func append(_ pcm: Data) throws {
        guard let node, engine?.isRunning == true else { throw AIError.message("译音播放器未就绪") }
        guard queuedFrames + pcm.count / 2 <= 24000 * 30 else { throw AIError.message("译音播放积压超过 30 秒，已停止播放；字幕继续更新") }
        let buffer = try LiveTranslateAudioDecoder.buffer(pcm)
        queuedFrames += Int(buffer.frameLength)
        let token = generation, count = Int(buffer.frameLength)
        node.scheduleBuffer(buffer, completionCallbackType: engine?.isInManualRenderingMode == true ? .dataConsumed : .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.queuedFrames -= count
                if self.queuedFrames == 0, let done = self.drained { self.stop(); done() }
            }
        }
    }
    func finish(_ completion: @escaping () -> Void) {
        guard queuedFrames > 0 else { stop(); completion(); return }
        drained = completion
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.fail("译音播放超时，已停止播放")
        }
        drainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 32, execute: timeout)
    }
    private func fail(_ message: String) {
        let done = drained
        stop(); onFailure?(message); done?()
    }
    func stop() {
        generation = UUID(); drainTimeout?.cancel(); drainTimeout = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        node?.stop(); engine?.stop(); node = nil; engine = nil
        queuedFrames = 0; drained = nil
    }
}
