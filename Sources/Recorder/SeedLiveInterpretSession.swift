import Foundation

/// Binary WebSocket transport for Volcengine / BytePlus Seed-LiveInterpret 2.0 (`volc-ast`).
/// Wire framing: raw Protobuf `TranslateRequest` / `TranslateResponse` per binary WebSocket frame.
/// All transport state lives on one serial queue; audio producers only enqueue bounded data.
final class SeedLiveInterpretClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var endKind = LiveCloudEndKind.other
    var onSlowService: ((Bool) -> Void)?
    var onReady: (() -> Void)?
    var onResponse: ((VolcAstTranslateResponse) -> Void)?
    var onEnd: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "recorder.seed-liveinterpret")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var pending: [(Data, Int)] = []
    private var buffered = 0
    private var sending = false
    private var ready = false
    private var finishing = false
    private var closed = false
    private var sessionID = ""
    private var connectionID = ""
    private var sequence: Int32 = 0
    private var deadline: DispatchWorkItem?
    private var windowStart: TimeInterval = 0
    private var windowQueue = 0
    private var windowBytes = 0
    private var slow = false
    private let finishTimeout: TimeInterval
    private let allowLocalhost: Bool
    private let uptime: () -> TimeInterval

    init(finishTimeout: TimeInterval = 30, allowLocalhost: Bool = false,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.finishTimeout = finishTimeout
        self.allowLocalhost = allowLocalhost
        self.uptime = uptime
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func connect(configuration: LiveTranslateConfiguration, key: String, allowLocalhost: Bool = false) throws {
        guard !key.isEmpty else { throw AIError.message("请在 LiveTranslate 设置中保存专用 API Key") }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AIError.message("API Key 格式无效，请重新填写") }
        let url = try configuration.url(allowLocalhost: allowLocalhost || self.allowLocalhost)
        let profile = configuration.profile
        let appKey = profile.appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let connID = UUID().uuidString
        let sid = UUID().uuidString

        var request = URLRequest(url: url)
        request.setValue(profile.modelID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connID, forHTTPHeaderField: "X-Api-Connect-Id")
        if appKey.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(key, forHTTPHeaderField: "X-Api-Access-Key")
        }

        let startRequest = Self.buildStartSessionRequest(
            sessionID: sid,
            connectionID: connID,
            configuration: configuration
        )

        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 20

        queue.sync {
            self.sessionID = sid
            self.connectionID = connID
            self.sequence = 1
            let session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 4_000_000
            self.socket = socket
            socket.resume()
            armTimeout(20, message: "LiveTranslate 连接或会话配置超时，请检查网络和服务地址")
            enqueue(startRequest.encode(), bytes: 0)
            receive()
        }
    }

    static func buildStartSessionRequest(
        sessionID: String,
        connectionID: String,
        configuration: LiveTranslateConfiguration
    ) -> VolcAstTranslateRequest {
        let profile = configuration.profile
        let mode = configuration.audioOutput ? "s2s" : "s2t"
        let sourceLanguage = profile.resolvedSourceLanguage(targetLanguage: configuration.language)
        // Official Volcengine AST 2.0 demo uses format="wav" for 16 kHz mono PCM16 uplink chunks.
        let sourceAudio = VolcAstAudio(format: "wav", rate: 16_000, bits: 16, channel: 1)
        // Request 24 kHz mono PCM16 output in s2s mode to directly feed the existing playback pipeline.
        let targetAudio: VolcAstAudio? = configuration.audioOutput
            ? VolcAstAudio(format: "pcm", rate: 24_000, bits: 16, channel: 1)
            : nil
        return VolcAstTranslateRequest(
            requestMeta: VolcAstRequestMeta(
                resourceID: profile.modelID,
                connectionID: connectionID,
                sessionID: sessionID,
                sequence: 1
            ),
            event: .startSession,
            user: VolcAstUser(uid: "shengjian_macos", did: "shengjian_macos"),
            sourceAudio: sourceAudio,
            targetAudio: targetAudio,
            request: VolcAstReqParams(
                mode: mode,
                sourceLanguage: sourceLanguage,
                targetLanguage: configuration.language
            ),
            denoise: false
        )
    }

    func append(_ data: Data) -> Bool {
        queue.sync {
            guard ready, !finishing, !closed else { return false }
            let now = uptime()
            var nextSlow = slow
            if now - windowStart >= 15, windowBytes > 0 {
                nextSlow = Double(windowQueue + windowBytes - buffered) < 0.8 * Double(windowBytes)
                windowStart = now; windowQueue = buffered; windowBytes = 0
            }
            if buffered > 48_000 { nextSlow = true }
            if slow != nextSlow {
                slow = nextSlow
                let callback = onSlowService
                DispatchQueue.main.async { callback?(nextSlow) }
            }
            guard buffered + data.count <= 320_000 else { return false }
            windowBytes += data.count
            sequence += 1
            let request = VolcAstTranslateRequest(
                requestMeta: VolcAstRequestMeta(sessionID: sessionID, sequence: sequence),
                event: .taskRequest,
                sourceAudio: VolcAstAudio(format: "wav", rate: 16_000, bits: 16, channel: 1, binaryData: data)
            )
            enqueue(request.encode(), bytes: data.count)
            return true
        }
    }

    func finish() {
        queue.async {
            guard self.ready, !self.closed, !self.finishing else { return }
            self.finishing = true
            self.armTimeout(self.finishTimeout, message: "LiveTranslate 尾句处理超时，已保留收到的文字，末句可能不完整")
            self.sequence += 1
            let request = VolcAstTranslateRequest(
                requestMeta: VolcAstRequestMeta(sessionID: self.sessionID, sequence: self.sequence),
                event: .finishSession
            )
            self.enqueue(request.encode(), bytes: 0)
        }
    }

    func cancel() { queue.sync { end(nil, notify: false) } }

    private func armTimeout(_ seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end(message) }
        deadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func enqueue(_ payload: Data, bytes: Int) {
        buffered += bytes
        pending.append((payload, bytes))
        sendNext()
    }

    private func sendNext() {
        guard !closed, !sending, !pending.isEmpty, let socket else { return }
        sending = true
        let (payload, bytes) = pending.removeFirst()
        socket.send(.data(payload)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.sending = false
                self.buffered -= bytes
                if error != nil { self.end(self.connectionError()) } else { self.sendNext() }
            }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure:
                    self.end(self.connectionError())
                case .success(let message):
                    let raw: Data
                    switch message {
                    case .data(let bytes): raw = bytes
                    case .string(let text): raw = Data(text.utf8)
                    @unknown default:
                        self.end("LiveTranslate 返回未知消息格式"); return
                    }
                    guard let response = try? VolcAstTranslateResponse.decode(raw) else {
                        self.end("LiveTranslate 返回无效数据"); return
                    }
                    if self.handle(response) {
                        self.receive()
                    }
                }
            }
        }
    }

    /// Returns false if the session has terminated.
    private func handle(_ response: VolcAstTranslateResponse) -> Bool {
        if response.hasErrorStatus {
            let code = response.responseMeta?.statusCode ?? 0
            let message = response.responseMeta?.message ?? ""
            endKind = Self.classifyStatus(code: code, detail: message)
            end(endKind.message ?? Self.serviceError(code: code, detail: message))
            return false
        }
        switch response.event {
        case .sessionStarted, .connectionStarted:
            if let returnedID = response.responseMeta?.sessionID, !returnedID.isEmpty {
                sessionID = returnedID
            }
            if !ready {
                ready = true
                deadline?.cancel()
                windowStart = uptime()
                let callback = onReady
                DispatchQueue.main.async { callback?() }
            }
        case .sessionFinished, .connectionFinished:
            end(finishing ? nil : "LiveTranslate 会话意外结束，已保留收到的文字")
            return false
        case .sessionFailed, .connectionFailed, .sessionCanceled:
            let code = response.responseMeta?.statusCode ?? 0
            let message = response.responseMeta?.message ?? ""
            endKind = Self.classifyStatus(code: code, detail: message)
            end(endKind.message ?? Self.serviceError(code: code, detail: message))
            return false
        default:
            guard ready else {
                end("LiveTranslate 会话配置顺序异常")
                return false
            }
            let callback = onResponse
            DispatchQueue.main.async { callback?(response) }
        }
        return true
    }

    private func connectionError() -> String {
        let status = (socket?.response as? HTTPURLResponse)?.statusCode
        let reason = socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        endKind = .classify(code: status == 429 ? status : socket?.closeCode.rawValue, detail: reason)
        if let message = endKind.message { return message }
        switch status {
        case 401, 403:
            return "LiveTranslate API Key 无效、资源未开通或无权访问，请核对密钥、App Key 及资源 ID"
        case 429:
            return "LiveTranslate 请求受限或额度不足，请稍后重试"
        default:
            return "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
        }
    }

    static func classifyStatus(code: Int32, detail: String) -> LiveCloudEndKind {
        if code == 11_301 || code == 11_303 || code == 429 { return .rateLimited }
        return LiveCloudEndKind.classify(code: Int(code), detail: detail)
    }

    static func serviceError(code: Int32, detail: String) -> String {
        let lower = detail.lowercased()
        if code == 11_200 || code == 401 || code == 403 || code == 45000010 || code == 45000030
            || lower.contains("auth") || lower.contains("key") || lower.contains("permission")
            || lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("resource") {
            return "LiveTranslate API Key 无效、资源未开通或无权访问，请核对密钥、App Key 及资源 ID"
        }
        if code == 11_301 || code == 11_302 || code == 11_303 || code == 429
            || lower.contains("limit") || lower.contains("quota") || lower.contains("balance") || lower.contains("arrears") {
            return "LiveTranslate 请求受限或额度不足，请检查账户余额并稍后重试"
        }
        return "LiveTranslate 服务处理失败，请检查资源权限和会话配置；已有文字已保留"
    }

    private func end(_ error: String?, notify: Bool = true) {
        guard !closed else { return }
        closed = true; ready = false; deadline?.cancel(); deadline = nil
        pending.removeAll(); buffered = 0
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        if notify {
            let callback = onEnd
            DispatchQueue.main.async { callback?(error) }
        }
    }
}

/// Maps Seed-LiveInterpret 2.0 subtitle and TTS Protobuf events into the provider-neutral LiveTranslationSession API.
final class SeedLiveInterpretSession: LiveTranslationSession {
    var onReady: (() -> Void)?
    var onEvent: ((LiveTranslationSessionEvent) -> Void)?
    var onEnd: ((String?) -> Void)?
    var endKind: LiveCloudEndKind { client.endKind }

    private struct TurnState {
        var id: String
        var startMS: Int = 0
        var endMS: Int = 0
        var source = ""
        var sourceDone = false
        var translation = ""
        var translationDone = false
        var audioDone = false
        var audioBytes = Data()
        var audioRejected = false
        var audioReleased = false
        var replayEmitted = false
    }

    private static let maxPendingAudioBytes = 24_000 * 2 * 30
    private static let oggMagic = Data([0x4F, 0x67, 0x67, 0x53]) // "OggS"

    private let client: SeedLiveInterpretClient
    private var active = false
    private var audioEnabled = false
    private var playbackTiming: LiveTranslatePlaybackTiming = .streaming
    private var playbackFailed = false
    private var revision = 0
    private var turns: [Int: TurnState] = [:]
    private var order: [Int] = []
    private var activeSourceTurn: Int?
    private var activeTranslationTurn: Int?
    private var activeTTSTurn: Int?
    private var nextSourceTurn = 0
    private var nextTranslationTurn = 0
    private var nextTTSTurn = 0
    private var previousUpdates: [String: LiveTranslationUpdate] = [:]
    private var audioTails: [Int: UInt8] = [:]
    private var pendingPlaybackBytes = 0

    init(client: SeedLiveInterpretClient = SeedLiveInterpretClient()) {
        self.client = client
    }

    func start(configuration: LiveTranslateConfiguration, key: String, sessionID: String) throws {
        active = true
        audioEnabled = configuration.audioOutput
        playbackTiming = configuration.playbackTiming
        playbackFailed = false
        revision = 0
        turns.removeAll()
        order.removeAll()
        activeSourceTurn = nil
        activeTranslationTurn = nil
        activeTTSTurn = nil
        nextSourceTurn = 0
        nextTranslationTurn = 0
        nextTTSTurn = 0
        previousUpdates.removeAll()
        audioTails.removeAll()
        pendingPlaybackBytes = 0

        client.onSlowService = { [weak self] slow in self?.onEvent?(.slowService(slow)) }
        client.onReady = { [weak self] in
            guard let self, self.active else { return }
            self.onReady?()
        }
        client.onResponse = { [weak self] response in
            self?.consume(response)
        }
        client.onEnd = { [weak self] message in
            guard let self, self.active else { return }
            if message == nil {
                self.closeActiveTurnsOnCleanEnd()
            }
            self.publishRows()
            self.releaseReadyAudio()
            self.emitReadyReplays()
            var error = message
            if error == nil, !self.audioTails.isEmpty {
                error = "末段译音数据不完整，已有字幕已保留"
            }
            if error == nil, self.pendingPlaybackBytes > 0 {
                error = "部分译音未收到完整定稿，已跳过播放；已有字幕已保留"
            }
            self.active = false
            self.onEnd?(error)
        }

        do {
            try client.connect(configuration: configuration, key: key)
        } catch {
            active = false
            throw error
        }
    }

    func append(_ pcm: Data) -> Bool { client.append(pcm) }
    func finish() { client.finish() }
    func cancel() { active = false; client.cancel() }
    func stopAutomaticPlayback() {
        playbackFailed = true
        pendingPlaybackBytes = 0
        for index in order {
            turns[index]?.audioBytes.removeAll()
        }
    }

    private func ensureTurn(_ index: Int) {
        if turns[index] == nil {
            turns[index] = TurnState(id: "ast-\(index)")
            order.append(index)
        }
    }

    private func consume(_ response: VolcAstTranslateResponse) {
        guard active, let event = response.event else { return }
        switch event {
        case .sourceSubtitleStart:
            if let prev = activeSourceTurn, turns[prev]?.sourceDone == false {
                turns[prev]?.sourceDone = true
            }
            nextSourceTurn += 1
            activeSourceTurn = nextSourceTurn
            ensureTurn(nextSourceTurn)
            if response.startTime > 0, turns[nextSourceTurn]?.startMS == 0 {
                turns[nextSourceTurn]?.startMS = Int(response.startTime)
            }
            if !response.text.isEmpty {
                let existing = turns[nextSourceTurn]?.source ?? ""
                turns[nextSourceTurn]?.source = VolcAstSubtitleMerger.merge(existing: existing, incoming: response.text)
            }
        case .sourceSubtitleResponse:
            let turn: Int
            if let current = activeSourceTurn {
                turn = current
            } else {
                nextSourceTurn += 1
                activeSourceTurn = nextSourceTurn
                turn = nextSourceTurn
                ensureTurn(turn)
            }
            if response.startTime > 0, turns[turn]?.startMS == 0 {
                turns[turn]?.startMS = Int(response.startTime)
            }
            if !response.text.isEmpty {
                let existing = turns[turn]?.source ?? ""
                turns[turn]?.source = VolcAstSubtitleMerger.merge(existing: existing, incoming: response.text)
            }
        case .sourceSubtitleEnd:
            let turn: Int
            if let current = activeSourceTurn {
                turn = current
            } else {
                nextSourceTurn += 1
                turn = nextSourceTurn
                ensureTurn(turn)
            }
            if response.startTime > 0, turns[turn]?.startMS == 0 {
                turns[turn]?.startMS = Int(response.startTime)
            }
            if response.endTime > 0 {
                turns[turn]?.endMS = Int(response.endTime)
            }
            if !response.text.isEmpty {
                turns[turn]?.source = response.text
            }
            turns[turn]?.sourceDone = true
            activeSourceTurn = nil

        case .translationSubtitleStart:
            if let prev = activeTranslationTurn, turns[prev]?.translationDone == false {
                turns[prev]?.translationDone = true
            }
            nextTranslationTurn += 1
            activeTranslationTurn = nextTranslationTurn
            ensureTurn(nextTranslationTurn)
            if response.startTime > 0, turns[nextTranslationTurn]?.startMS == 0 {
                turns[nextTranslationTurn]?.startMS = Int(response.startTime)
            }
            if !response.text.isEmpty {
                let existing = turns[nextTranslationTurn]?.translation ?? ""
                turns[nextTranslationTurn]?.translation = VolcAstSubtitleMerger.merge(existing: existing, incoming: response.text)
            }
        case .translationSubtitleResponse:
            let turn: Int
            if let current = activeTranslationTurn {
                turn = current
            } else {
                nextTranslationTurn += 1
                activeTranslationTurn = nextTranslationTurn
                turn = nextTranslationTurn
                ensureTurn(turn)
            }
            if response.startTime > 0, turns[turn]?.startMS == 0 {
                turns[turn]?.startMS = Int(response.startTime)
            }
            if !response.text.isEmpty {
                let existing = turns[turn]?.translation ?? ""
                turns[turn]?.translation = VolcAstSubtitleMerger.merge(existing: existing, incoming: response.text)
            }
        case .translationSubtitleEnd:
            let turn: Int
            if let current = activeTranslationTurn {
                turn = current
            } else {
                nextTranslationTurn += 1
                turn = nextTranslationTurn
                ensureTurn(turn)
            }
            if response.endTime > 0 {
                turns[turn]?.endMS = Int(response.endTime)
            }
            if !response.text.isEmpty {
                turns[turn]?.translation = response.text
            }
            turns[turn]?.translationDone = true
            activeTranslationTurn = nil

        case .ttsSentenceStart:
            if let prev = activeTTSTurn, turns[prev]?.audioDone == false {
                finishTTSTurn(prev)
            }
            nextTTSTurn += 1
            activeTTSTurn = nextTTSTurn
            ensureTurn(nextTTSTurn)
        case .ttsResponse:
            guard audioEnabled, !response.data.isEmpty else { return }
            let turn: Int
            if let current = activeTTSTurn {
                turn = current
            } else {
                nextTTSTurn += 1
                activeTTSTurn = nextTTSTurn
                turn = nextTTSTurn
                ensureTurn(turn)
            }
            consumeAudioChunk(response.data, turn: turn)
        case .ttsSentenceEnd:
            if let current = activeTTSTurn {
                finishTTSTurn(current)
                activeTTSTurn = nil
            }
        case .ttsEnded:
            if let current = activeTTSTurn {
                finishTTSTurn(current)
                activeTTSTurn = nil
            }
        default:
            return
        }

        publishRows()
        releaseReadyAudio()
        emitReadyReplays()
    }

    private func consumeAudioChunk(_ raw: Data, turn: Int) {
        if raw.starts(with: Self.oggMagic) {
            turns[turn]?.audioRejected = true
            if !playbackFailed {
                playbackFailed = true
                onEvent?(.playbackWarning("服务端返回了不支持的压缩译音格式，已停止播放；字幕继续更新"))
            }
            return
        }
        var aligned = Data()
        if let tail = audioTails.removeValue(forKey: turn) { aligned.append(tail) }
        aligned.append(raw)
        if aligned.count % 2 == 1 {
            audioTails[turn] = aligned.removeLast()
        }
        guard !aligned.isEmpty else { return }

        if turns[turn]?.audioRejected == false {
            let currentSize = turns[turn]?.audioBytes.count ?? 0
            if currentSize + aligned.count > Self.maxPendingAudioBytes {
                turns[turn]?.audioRejected = true
                turns[turn]?.audioBytes.removeAll()
            } else {
                turns[turn]?.audioBytes.append(aligned)
            }
        }

        guard !playbackFailed else { return }
        if playbackTiming == .streaming {
            turns[turn]?.audioReleased = true
            onEvent?(.audio(aligned))
        } else {
            if pendingPlaybackBytes + aligned.count > Self.maxPendingAudioBytes {
                playbackFailed = true
                pendingPlaybackBytes = 0
                onEvent?(.playbackWarning("等待定稿的译音超过 30 秒，已停止本次播放；字幕继续更新"))
            } else {
                pendingPlaybackBytes += aligned.count
                onEvent?(.audioPending)
            }
        }
    }

    private func finishTTSTurn(_ turn: Int) {
        turns[turn]?.audioDone = true
        if audioTails.removeValue(forKey: turn) != nil {
            turns[turn]?.audioRejected = true
            if !playbackFailed {
                playbackFailed = true
                onEvent?(.playbackWarning("译音数据不完整，已停止播放"))
            }
        }
    }

    private func closeActiveTurnsOnCleanEnd() {
        if let turn = activeSourceTurn {
            turns[turn]?.sourceDone = true
            activeSourceTurn = nil
        }
        if let turn = activeTranslationTurn {
            turns[turn]?.translationDone = true
            activeTranslationTurn = nil
        }
        if let turn = activeTTSTurn {
            turns[turn]?.audioDone = true
            activeTTSTurn = nil
        }
    }

    private func releaseReadyAudio() {
        guard audioEnabled, !playbackFailed, playbackTiming == .afterFinal else { return }
        for index in order {
            guard var state = turns[index] else { continue }
            if state.audioReleased { continue }
            guard state.sourceDone else { break }
            guard state.translationDone else { break }
            if !state.audioDone && !state.audioBytes.isEmpty { break }
            if !state.audioDone && !state.translation.isEmpty { break }
            state.audioReleased = true
            let pcm = state.audioBytes
            turns[index] = state
            if !pcm.isEmpty {
                pendingPlaybackBytes = max(0, pendingPlaybackBytes - pcm.count)
                onEvent?(.audio(pcm))
            }
        }
    }

    private func emitReadyReplays() {
        guard audioEnabled else { return }
        for index in order {
            guard var state = turns[index], !state.replayEmitted,
                  state.sourceDone, state.translationDone, state.audioDone else { continue }
            state.replayEmitted = true
            let pcm = state.audioBytes
            if state.audioReleased || playbackTiming == .streaming {
                state.audioBytes.removeAll()
            }
            turns[index] = state
            if !state.audioRejected, !pcm.isEmpty {
                onEvent?(.replayClip(segmentID: state.id, pcm: pcm))
            }
        }
    }

    private func publishRows() {
        for index in order {
            guard let state = turns[index] else { continue }
            guard !state.source.isEmpty || !state.translation.isEmpty else { continue }
            var update = LiveTranslationUpdate(
                segmentID: state.id,
                startSample: state.startMS * 16,
                endSample: state.endMS * 16,
                source: state.source,
                translation: state.translation,
                revision: 0,
                sourceDone: state.sourceDone,
                translationDone: state.translationDone,
                committed: state.translationDone
            )
            guard previousUpdates[state.id] != update else { continue }
            previousUpdates[state.id] = update
            revision += 1
            update.revision = revision
            onEvent?(.update(update))
        }
    }
}
