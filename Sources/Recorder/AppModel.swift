import SwiftUI
import AVFoundation
import Carbon
import UniformTypeIdentifiers
import Combine
// SwiftPM builds import the backend module; the swiftc test scripts compile its sources into one module.
#if canImport(RecorderBackend)
import RecorderBackend
#endif

struct TranslationPart {
    var text: String
    var revision: Int
    var done: Bool
}

struct Transcript: Identifiable {
    let id: String
    var text: String
    var seconds: Double
    var sourceDone = true
    var incomplete = false
    /// Keyed by backend unit id; a sentence carried past a forced cut can anchor a second unit here.
    var translations: [Int: TranslationPart] = [:]
    var translation: String { translations.keys.sorted().compactMap { translations[$0]?.text }.filter { !$0.isEmpty }.joined(separator: " ") }
    var translating: Bool { translations.values.contains { !$0.done } }
}

final class AppModel: ObservableObject {
    @Published private(set) var subtitleMode = false
    private var subtitleWindow: SubtitleWindowController?
    @Published var state = "connecting"
    @Published var detail = "正在启动本地推理服务…"
    @Published var error = ""
    @Published var finalText: [Transcript] = []
    @Published var partial = ""
    @Published var level: Float = 0
    @Published var microphones: [Microphone] = []
    @Published var audioSource = "microphone"
    @Published var audioFileURL: URL?
    private let additionalInput = AdditionalAudioInput()
    private var startAttempt = UUID()
    @Published var device: AudioDeviceID = 0
    @Published var permission = "尚未请求"
    @Published var modelID = "mlx-community/Qwen3-ASR-1.7B-bf16"
    @Published var asrProvider = "local"
    @Published var asrAPIBaseURL = "https://api.openai.com/v1"
    @Published var asrAPIModel = ""
    @Published var asrAPIKeyInput = ""
    @Published var asrAPIProtocol = "openai"
    @Published var asrConnectionMessage = ""
    @Published private(set) var asrTesting = false
    private var asrTestClient: StreamingASRClient?
    /// Set and read under audioLock: capture callbacks route PCM to it instead of the backend.
    private var streamClient: StreamingASRClient?
    private var streamAttempt = UUID()
    private var activeASRProvider = "local"
    private var activeAPIBaseURL = ""
    private var activeAPIModel = ""
    private var activeAPIProtocol = "openai"
    static let qwenID = "mlx-community/Qwen3-ASR-1.7B-bf16"
    static let whisperID = "mlx-community/whisper-large-v3-turbo"
    @Published var activeModelID = "mlx-community/Qwen3-ASR-1.7B-bf16"
    @Published var preset = "mlx-community/Qwen3-ASR-1.7B-bf16"
    @Published var localPath = ""
    @Published var revision = ""
    @Published var language = "auto"
    @Published var previewInterval = 1200
    @Published var endpointMode = "smart"
    @Published var silence = 1000
    @Published var maxSegment = 18
    @Published var progress = 0.0
    @Published var progressLabel = ""
    static let translatorQwenID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    static let translatorHunyuanID = "mlx-community/Hunyuan-MT-7B-4bit"
    /// Must match Backend.translationTargets (Sources/RecorderBackend/BackendTypes.swift).
    static let translationTargets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"]
    @Published var translationProvider = "local"
    @Published var translationAPIProfile = ""
    private let apiTranslations = APITranslationQueue()
    @Published var translationEnabled = false
    @Published var translationTarget = "简体中文"
    @Published var translatorPreset = AppModel.translatorQwenID
    @Published var translatorModelID = AppModel.translatorQwenID
    @Published var translatorRevision = ""
    @Published var activeTranslatorID = ""
    @Published var translatorState = "idle"
    @Published var translatorDetail = ""
    @Published var translatorProgress = 0.0
    @Published var translatorProgressLabel = ""
    @Published var translationTick = 0
    @Published var holdToTalk = UserDefaults.standard.bool(forKey: "holdToTalk") {
        didSet { UserDefaults.standard.set(holdToTalk, forKey: "holdToTalk") }
    }
    @Published var shortcutKey = UserDefaults.standard.string(forKey: "shortcutKey") ?? "Space" {
        didSet { UserDefaults.standard.set(shortcutKey, forKey: "shortcutKey"); registerShortcut() }
    }
    private var transport: BackendChannel?
    private let capture = AudioCapture()
    private var session = ""
    private var seen = Set<String>()
    private var rows: [String:Int] = [:]
    private var translatorSelectionLoaded = false
    private var revisions: [Int:Int] = [:]
    private var sequence = 0
    private var samples = 0
    private let audioLock = NSLock()
    private var accepting = false
    private var hotKey: EventHotKeyRef?
    private var hotHandler: EventHandlerRef?
    private var sleepObserver: NSObjectProtocol?
    @Published private var pendingStart = false
    private var generation = UUID()
    @Published private(set) var liveConfiguration = LiveTranslateConfiguration()
    @Published var liveEndpoint = LiveTranslateConfiguration().endpoint
    @Published var liveLanguage = "zh"
    @Published var liveAudioOutput = false
    @Published var liveVolume: Float = 0.8
    @Published var livePlaybackTiming: LiveTranslatePlaybackTiming = .streaming
    @Published private(set) var livePlaying = false
    @Published private(set) var replayingTranscriptID: String?
    @Published private(set) var replayRevision = 0
    private var replayCache = LiveSessionReplayCache()
    private let replayPlayer = LiveTranslateAudioPlayer()
    private var replayAttempt = UUID()
    private let liveAudioPlayer = LiveTranslateAudioPlayer()
    private var liveAudioMuted = false
    private var livePlaybackSession = UUID()
    @Published var liveKeyInput = ""
    @Published var liveMessage = ""
    @Published private(set) var liveTesting = false
    private let liveClientFactory: () -> LiveTranslateClient
    private let liveSessionFactory: ((LiveTranslateProvider) -> any LiveTranslationSession)?
    private let liveKeyReader: (String) throws -> String?
    private let liveDefaults: UserDefaults
    private var liveSession: (any LiveTranslationSession)?
    private var liveRowRevisions: [String: Int] = [:]
    private var liveSentenceRows = LiveSentenceRows()
    private var liveRowRanges: [String: (Int, Int)] = [:]
    private var liveUntranslatedRanges: [(Int, Int)] = []
    private let localSpeech: any LocalSpeechOutputting
    private let replaySpeech: any LocalSpeechOutputting
    let hyModelStore: HyModelStore
    private let hyRuntime = HyLocalSession()
    private let runtimeVerified: () -> Bool
    private let runtimeExecutable: () -> URL?
    private var hyObservation: AnyCancellable?
    private var hyLoadAttempt = UUID()
    @Published var liveProvider: LiveTranslateProvider = .qwenCloud
    @Published private(set) var hyRuntimeState = "idle"
    @Published private(set) var hyRuntimeDetail = "本地模型未加载"
    var hyRuntimeVerified: Bool { runtimeVerified() }
    var hyRuntimeUnavailableReason: String { HyRuntimeAvailability.unavailableReason }
    /// The model occupies about 23 GB while loaded; below this it would push everything else into swap.
    var hyMemoryIsLow: Bool { ProcessInfo.processInfo.physicalMemory < 32 << 30 }
    var canLoadHyModel: Bool {
        !liveSettingsBusy && liveEnabled && liveConfiguration.provider == .hyLocal && hyRuntimeVerified
            && !["loading", "ready"].contains(hyRuntimeState) && hyModelStore.state != "downloading"
    }
    private var liveAttempt = UUID()
    var liveEnabled: Bool { liveConfiguration.enabled }
    var liveSettingsBusy: Bool { recording || pendingStart || state == "finalizing" || liveTesting }
    var canStop: Bool { recording || pendingStart || (liveEnabled && state == "connecting") }


    var busy: Bool { !["idle", "ready", "error"].contains(state) }
    var inputBusy: Bool { busy || pendingStart || liveTesting || asrTesting }
    /// "qwen_realtime" is the historical config tag for the WebSocket streaming ASR protocol.
    var streamingASR: Bool { asrProvider == "api" && asrAPIProtocol == "qwen_realtime" }
    private var streamingActive: Bool { activeASRProvider == "api" && activeAPIProtocol == "qwen_realtime" }
    var recording: Bool { state == "recording" }
    var canStart: Bool {
        if liveEnabled { return state == "ready" && !liveTesting && (liveConfiguration.provider == .qwenCloud || (hyRuntimeVerified && hyRuntimeState == "ready")) }
        return state == "ready" && !asrTesting && asrProvider == activeASRProvider &&
        (asrProvider != "api" || (asrAPIBaseURL == activeAPIBaseURL && asrAPIModel == activeAPIModel && asrAPIProtocol == activeAPIProtocol))
    }
    var joinedText: String { finalText.map { $0.text.isEmpty ? $0.translation : $0.text }.joined(separator: "\n") }
    var exportText: String {
        let translated = finalText.contains { !$0.translation.isEmpty }
        return finalText.map { item in
            let translation = item.translation
            return [item.text, translation].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: translated ? "\n\n" : "\n")
    }
    var translatorBusy: Bool { ["downloading", "loading", "warming"].contains(translatorState) }
    var translatorStatusTitle: String {
        ["idle":"未加载", "downloading":"下载中", "loading":"加载中", "warming":"预热中", "ready":"已就绪", "error":"需要处理"][translatorState] ?? translatorState
    }
    var activeTranslatorName: String {
        switch activeTranslatorID {
        case Self.translatorQwenID: return "Qwen3 4B"
        case Self.translatorHunyuanID: return "Hunyuan-MT 7B"
        default: return activeTranslatorID.split(separator: "/").last.map(String.init) ?? activeTranslatorID
        }
    }
    var translationSummary: String {
        if liveEnabled { return "\(liveConfiguration.modelName) → \(liveConfiguration.languageName)" }
        if translationProvider == "api" {
            guard translationEnabled else { return "已关闭" }
            let profile = AIProfiles.shared.profiles.first { $0.id == translationAPIProfile }
            return profile.map { "API · \($0.modelID) → \(translationTarget)" } ?? "请在翻译设置中选择 API 服务"
        }
        if translatorState == "downloading" { return "正在下载翻译模型…" }
        if ["loading", "warming"].contains(translatorState) { return "正在加载翻译模型…" }
        guard translationEnabled else { return "已关闭" }
        if translatorState == "ready", !activeTranslatorID.isEmpty { return "\(activeTranslatorName) → \(translationTarget)" }
        if translatorState == "error" { return "翻译模型需要处理" }
        return "译为\(translationTarget) · 随识别模型加载"
    }
    var statusTitle: String {
        ["connecting":"连接服务", "idle":"等待模型", "downloading":"下载模型", "loading":"加载模型", "warming":"模型预热", "ready":"准备就绪", "recording":"正在聆听", "finalizing":"处理尾句", "error":"需要处理"][state] ?? state
    }

    init(defaults: UserDefaults = .standard, integrateSystem: Bool = true,
         liveClientFactory: @escaping () -> LiveTranslateClient = { LiveTranslateClient() },
         liveKeyReader: @escaping (String) throws -> String? = { try APIKeyStore.read(endpoint: $0) },
         liveSessionFactory: ((LiveTranslateProvider) -> any LiveTranslationSession)? = nil,
         hyModelStore: HyModelStore? = nil,
         runtimeVerified: @escaping () -> Bool = { HyRuntimeAvailability.isVerified },
         runtimeExecutable: @escaping () -> URL? = { HyRuntimeAvailability.executableURL },
         localSpeech: (any LocalSpeechOutputting)? = nil,
         replaySpeech: (any LocalSpeechOutputting)? = nil) {
        self.liveClientFactory = liveClientFactory; self.liveKeyReader = liveKeyReader
        self.liveSessionFactory = liveSessionFactory
        self.hyModelStore = hyModelStore ?? HyModelStore()
        self.runtimeVerified = runtimeVerified; self.runtimeExecutable = runtimeExecutable
        self.localSpeech = localSpeech ?? LocalSpeechOutput()
        self.replaySpeech = replaySpeech ?? LocalSpeechOutput()
        liveDefaults = defaults
        liveConfiguration = LiveTranslateConfiguration.load(defaults: defaults)
        liveProvider = liveConfiguration.provider
        liveEndpoint = liveConfiguration.endpoint; liveLanguage = liveConfiguration.language
        liveAudioOutput = liveConfiguration.audioOutput; liveVolume = liveConfiguration.volume
        livePlaybackTiming = liveConfiguration.playbackTiming
        hyObservation = self.hyModelStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.localSpeech.onPlayingChange = { [weak self] playing in
            guard let self, self.liveConfiguration.provider == .hyLocal else { return }
            self.livePlaying = playing
        }
        self.localSpeech.onFailure = { [weak self] message in self?.error = message; self?.stopLivePlayback() }
        self.replaySpeech.onFailure = { [weak self] message in self?.error = message; self?.stopReplay() }
        apiTranslations.onUpdate = { [weak self] id, text, done in
            guard let self, let index = self.rows[id], self.finalText.indices.contains(index) else { return }
            // Negative unit IDs are reserved for frontend API translations.
            self.finalText[index].translations[-1] = done && text.isEmpty ? nil : TranslationPart(text: text, revision: 1, done: done)
            self.translationTick += 1
        }
        apiTranslations.onError = { [weak self] message in self?.error = message }
        if integrateSystem { refreshDevices(); updatePermission() }
        capture.onFailure = { [weak self] message in DispatchQueue.main.async { self?.stop(); self?.error = message } }
        capture.onPCM = { [weak self] pcm, rms in self?.audio(pcm, rms: rms) }
        if integrateSystem {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        registerShortcut()
        }
        launch()
    }

    func setSubtitleMode(_ enabled: Bool) {
        subtitleMode = enabled
        if enabled {
            if subtitleWindow == nil {
                subtitleWindow = SubtitleWindowController(model: self) { [weak self] in self?.subtitleMode = false }
            }
            subtitleWindow?.show()
        } else {
            subtitleWindow?.close()
            subtitleWindow = nil
        }
    }

    func refreshDevices() { microphones = AudioCapture.microphones() }
    func updatePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "已允许"
        case .denied, .restricted: permission = "未允许"
        default: permission = "尚未请求"
        }
    }

    func launch() {
        shutdown()
        if liveEnabled {
            state = liveConfiguration.provider == .qwenCloud ? "ready" : "idle"
            detail = liveConfiguration.provider == .qwenCloud ? "LiveTranslate 已就绪"
                : !hyRuntimeVerified ? hyRuntimeUnavailableReason
                : hyModelStore.hasCachedFile ? "请加载 Hy-SimulMT 模型" : "请在 LiveTranslate 设置中下载 Hy-SimulMT 模型"
            error = ""
            return
        }
        generation = UUID()
        let currentGeneration = generation
        state = "connecting"; error = ""
        translatorSelectionLoaded = false
        let channel: BackendChannel
        do { channel = try LocalBackend.makeChannel() }
        catch { self.error = "无法创建本地配置目录"; state = "error"; return }
        channel.onEvent = { [weak self] event in DispatchQueue.main.async {
            guard let self, self.generation == currentGeneration else { return }
            self.handle(event)
        } }
        channel.onFailure = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.generation == currentGeneration else { return }
            self.stopInputs(); self.state = "error"; self.error = message
        } }
        transport = channel
        command("hello")
    }

    func shutdown() {
        audioLock.lock(); accepting = false; let previousLiveSession = liveSession; liveSession = nil; audioLock.unlock()
        stopReplay()
        stopLivePlayback()
        asrTestClient?.cancel(); asrTestClient = nil; asrTesting = false
        streamAttempt = UUID()
        audioLock.lock(); let stream = streamClient; streamClient = nil; audioLock.unlock()
        stream?.cancel()
        liveAttempt = UUID()
        previousLiveSession?.cancel(); liveTesting = false
        hyLoadAttempt = UUID(); hyRuntime.unload(); hyRuntimeState = "idle"; hyRuntimeDetail = "本地模型未加载"
        if hyModelStore.state == "checking" { hyModelStore.cancel() }
        settleLiveRows()
        cancelLiveTranslations()
        generation = UUID()
        pendingStart = false
        audioLock.lock(); accepting = false; audioLock.unlock()
        stopInputs()
        transport?.close(); transport = nil
    }

    private func command(_ name: String, extra: [String:Any] = [:]) {
        guard !liveEnabled else { return }
        var value: [String:Any] = ["command":name, "protocol_version":1, "request_id":UUID().uuidString, "session_id":session]
        value.merge(extra) { _, new in new }
        transport?.send(value)
    }

    var config: [String:Any] {
        ["schema_version":1, "model_id":modelID, "local_model_path":localPath,
         "revision":revision, "language":language, "preview_interval_ms":previewInterval,
         "endpoint_mode":endpointMode, "endpoint_silence_ms":silence, "max_segment_seconds":maxSegment,
         "provider":asrProvider, "api_base_url":asrAPIBaseURL, "api_model":asrAPIModel, "api_protocol":asrAPIProtocol]
    }
    func load(download: Bool = false) {
        guard !liveEnabled, !asrTesting else { return }
        error = ""; progress = 0
        if asrProvider == "api" {
            do {
                let base = try normalizedASREndpoint()
                guard !asrAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIError.message("请填写支持音频转写的模型 ID")
                }
                asrAPIBaseURL = base
                asrAPIModel = asrAPIModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let account = "asr:" + base
                let input = asrAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !input.isEmpty { try APIKeyStore.save(input, endpoint: account); asrAPIKeyInput = "" }
                guard let key = try APIKeyStore.read(endpoint: account), !key.isEmpty else {
                    throw AIError.message("请填写识别 API Key")
                }
                var extra: [String:Any] = ["config":config]
                if !streamingASR { extra["api_key"] = key }
                command("load", extra:extra)
            } catch { self.error = error.localizedDescription }
        } else { command(download ? "download" : "load", extra:["config":config]) }
    }
    var activeModelName: String {
        if liveEnabled { return liveConfiguration.modelName }
        if activeASRProvider == "api" { return "API · \(activeAPIModel)" }
        switch activeModelID {
        case Self.qwenID: return "Qwen3-ASR 1.7B"
        case Self.whisperID: return "Whisper Large v3 Turbo"
        default: return activeModelID.split(separator: "/").last.map(String.init) ?? activeModelID
        }
    }
    func selectPreset(_ id: String) {
        guard !busy else { return }
        preset = id
        if id != "custom" {
            modelID = id
            localPath = ""
            revision = ""
        }
    }
    func setASRProvider(_ provider: String) {
        guard !busy, !asrTesting, ["local", "api"].contains(provider) else { return }
        asrProvider = provider
    }
    func setASRAPIProtocol(_ value: String) {
        guard !inputBusy, ["openai", "qwen_realtime"].contains(value), value != asrAPIProtocol else { return }
        asrAPIProtocol = value; asrAPIKeyInput = ""; asrConnectionMessage = ""
        if value == "qwen_realtime" {
            asrAPIBaseURL = StreamingASRConfiguration.endpoint
            asrAPIModel = StreamingASRConfiguration.model
        } else { asrAPIBaseURL = "https://api.openai.com/v1"; asrAPIModel = "" }
    }
    private func normalizedASREndpoint() throws -> String {
        if streamingASR {
            asrAPIModel = StreamingASRConfiguration.model
            return StreamingASRConfiguration.endpoint
        }
        var base = asrAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/audio/transcriptions") { base.removeLast("/audio/transcriptions".count) }
        return try AIProfile.normalize(base)
    }
    func testASRConnection() {
        guard streamingASR, !liveEnabled, !inputBusy else { return }
        do {
            let base = try normalizedASREndpoint()
            let keyInput = asrAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyInput.isEmpty { try APIKeyStore.save(keyInput, endpoint:"asr:" + base); asrAPIKeyInput = "" }
            let key = try APIKeyStore.read(endpoint:"asr:" + base) ?? ""
            let client = StreamingASRClient()
            let finish = { [weak self, weak client] (message: String) in
                guard let self, let client, self.asrTestClient === client else { return }
                client.cancel(); self.asrTestClient = nil; self.asrTesting = false; self.asrConnectionMessage = message
            }
            // task-started proves key, model and parameters; the task is closed before any audio is sent.
            client.onReady = { finish("连接成功，识别任务已启动；测试未发送音频") }
            client.onEnd = { error in finish(error ?? "识别任务已结束") }
            asrTestClient = client; asrTesting = true; asrConnectionMessage = "正在连接并启动识别任务…"
            try client.connect(configuration: StreamingASRConfiguration(language:language, silenceMS:silence), key:key)
        } catch { asrTestClient = nil; asrTesting = false; asrConnectionMessage = error.localizedDescription }
    }
    func cancelDownload() { command("cancel_download") }

    var translationConfig: [String:Any] {
        ["schema_version":1, "enabled":translationEnabled, "target_language":translationTarget,
         "provider":translationProvider, "api_profile":translationAPIProfile,
         "model_id":translatorModelID, "revision":translatorRevision]
    }
    func setTranslation(enabled: Bool) {
        guard !liveEnabled else { return }
        guard !translatorBusy, enabled != translationEnabled else { return }
        error = ""
        translationEnabled = enabled
        if !enabled { cancelLiveTranslations() }
        command("translation_settings", extra: ["enabled": enabled])
    }
    private func cancelLiveTranslations() {
        apiTranslations.cancel()
        for index in finalText.indices {
            finalText[index].translations = finalText[index].translations.filter { $0.value.done }
        }
    }
    func setTranslationProvider(_ provider: String) {
        guard !liveEnabled else { return }
        guard !translatorBusy, ["local", "api"].contains(provider), provider != translationProvider else { return }
        cancelLiveTranslations()
        translationProvider = provider
        if provider == "api", translationAPIProfile.isEmpty {
            translationAPIProfile = AIProfiles.shared.selectedID
        }
        command("translation_settings", extra: ["provider":provider, "api_profile":translationAPIProfile])
    }
    func setTranslationAPIProfile(_ id: String) {
        guard !liveEnabled else { return }
        translationAPIProfile = id
        command("translation_settings", extra: ["api_profile":id])
    }
    private func translateFinal(id: String, text: String) {
        guard !liveEnabled, translationEnabled, translationProvider == "api" else { return }
        do {
            guard let profile = AIProfiles.shared.profiles.first(where: { $0.id == translationAPIProfile }) else {
                throw AIError.message("请在设置 → AI 服务中保存配置，并在翻译设置中选择该服务")
            }
            guard let key = try APIKeyStore.read(endpoint: profile.baseURL), !key.isEmpty else {
                throw AIError.message("请在设置 → AI 服务中保存该服务的 API Key")
            }
            apiTranslations.enqueue(.init(id:id, text:text, target:translationTarget, config:profile.configuration, key:key))
        } catch { self.error = "API 翻译未启动：\(error.localizedDescription)。原文仍保留。" }
    }
    func setTranslationTarget(_ target: String) {
        guard !liveEnabled else { return }
        guard target != translationTarget else { return }
        translationTarget = target
        command("translation_settings", extra: ["target_language": target])
    }
    func loadTranslator(download: Bool = false) {
        guard !liveEnabled else { return }
        guard !translatorBusy else { return }
        error = ""; translatorProgress = 0
        command(download ? "download" : "load", extra: ["role":"translator", "translation":translationConfig])
    }
    func selectTranslatorPreset(_ id: String) {
        guard !translatorBusy else { return }
        translatorPreset = id
        if id != "custom" { translatorModelID = id; translatorRevision = "" }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { localPath = panel.url?.path ?? "" }
    }
    func showPermissionSettings() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }

    func toggle() { canStop ? stop() : start() }
    func chooseAudioFile() {
        guard !busy, !pendingStart else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { audioFileURL = panel.url }
    }
    func start() {
        stopReplay()
        guard canStart, !pendingStart else {
            if state == "ready" { error = "识别服务设置已更改，请先点击「连接 / 切换」使其生效" }
            return
        }
        if audioSource == "file", audioFileURL == nil { error = "请先选择音频文件"; return }
        error = ""; pendingStart = true
        startAttempt = UUID()
        let attempt = startAttempt
        let begin = { [weak self] (granted: Bool) in
            guard let self, self.pendingStart, self.startAttempt == attempt else { return }
            guard granted else { self.pendingStart = false; self.error = "请在系统设置中允许麦克风访问"; return }
            guard self.state == "ready" else { self.pendingStart = false; return }
            self.session = UUID().uuidString
            self.partial = ""; self.revisions.removeAll()
            if self.liveEnabled { self.connectLive(test: false); return }
            if self.streamingActive { self.connectStreaming(); return }
            self.command("start", extra: ["endpoint_mode": self.endpointMode, "endpoint_silence_ms": self.silence])
        }
        if audioSource == "microphone" {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in DispatchQueue.main.async {
                self?.updatePermission(); begin(granted)
            } }
        } else { begin(true) }
    }

    /// The cloud task starts first; the backend session starts once audio can flow, and ends after the last final.
    private func connectStreaming() {
        let attempt = UUID(); streamAttempt = attempt
        let currentSession = session
        let configuration = StreamingASRConfiguration(language:language, silenceMS:silence)
        let client = StreamingASRClient()
        client.onReady = { [weak self] in
            guard let self, self.streamAttempt == attempt, self.session == currentSession, self.pendingStart else { return }
            self.command("start", extra: ["endpoint_silence_ms": self.silence])
        }
        client.onPartial = { [weak self] text in
            guard let self, self.streamAttempt == attempt, self.session == currentSession else { return }
            self.partial = text
        }
        client.onFinal = { [weak self] id, text, begin in
            guard let self, self.streamAttempt == attempt, self.session == currentSession else { return }
            self.command("asr_stream_final", extra: ["segment_id":id, "text":text, "start_sample":begin * 16])
        }
        client.onEnd = { [weak self] error in
            guard let self, self.streamAttempt == attempt else { return }
            self.streamAttempt = UUID()
            self.audioLock.lock(); self.accepting = false; self.streamClient = nil; self.audioLock.unlock()
            self.stopInputs(); self.level = 0
            if let error { self.error = error }
            if self.pendingStart { self.pendingStart = false; return }
            if self.session == currentSession, ["recording", "finalizing"].contains(self.state) {
                self.state = "finalizing"; self.command("stop")
            }
        }
        audioLock.lock(); streamClient = client; audioLock.unlock()
        do {
            try client.connect(configuration: configuration, key: try APIKeyStore.read(endpoint:StreamingASRConfiguration.keyAccount) ?? "")
            detail = "正在连接识别服务…"
        } catch {
            streamAttempt = UUID()
            audioLock.lock(); streamClient = nil; audioLock.unlock()
            pendingStart = false; self.error = error.localizedDescription
        }
    }

    private func beginCapture() {
        guard pendingStart else { command("stop"); return }
        pendingStart = false
        audioLock.lock(); sequence = 0; samples = 0; accepting = true; audioLock.unlock()
        let currentSession = session
        additionalInput.onPCM = { [weak self] pcm, rms in self?.audio(pcm, rms: rms) }
        additionalInput.onEnd = { [weak self] in DispatchQueue.main.async {
            guard let self, self.session == currentSession, self.recording else { return }
            self.stop()
        } }
        additionalInput.onFailure = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.session == currentSession, self.recording else { return }
            self.stop(); self.error = message
        } }
        do {
            switch audioSource {
            case "file":
                guard let url = audioFileURL else { throw AIError.message("请先选择音频文件") }
                try additionalInput.startFile(url)
            case "system":
                Task { @MainActor [weak self] in
                    guard let self, self.session == currentSession, self.recording else { return }
                    do { try await self.additionalInput.startSystem() }
                    catch {
                        guard self.session == currentSession, self.recording else { return }
                        self.stop()
                        self.error = "无法采集系统声音：\(error.localizedDescription)。请在系统设置 → 隐私与安全性中允许声笺录制屏幕与系统音频。"
                    }
                }
            default: try capture.start(device: device)
            }
        } catch { stop(); self.error = error.localizedDescription }
    }

    private func stopInputs() {
        capture.stop()
        additionalInput.stop()
    }

    private func audio(_ pcm: Data, rms: Float) {
        audioLock.lock()
        guard accepting else { audioLock.unlock(); return }
        let audioSession = session
        let sent = liveEnabled ? (liveSession?.append(pcm) ?? false)
            : streamClient.map { $0.append(pcm) } ?? (transport?.audio(pcm, session: session, sequence: sequence, start: samples) ?? false)
        if sent { sequence += 1; samples += pcm.count / 2 }
        else { accepting = false }
        audioLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == audioSession, self.recording else { return }
            self.level = min(1, rms * 8)
            if !sent { self.stop(); self.error = "音频传输积压，已停止采集并处理已排队音频；最后一个未发送音频块未能保留。" }
        }
    }

    func stop() {
        startAttempt = UUID()
        pendingStart = false
        stopInputs()
        audioLock.lock(); accepting = false; audioLock.unlock()
        level = 0
        if liveEnabled {
            if state == "recording" { state = "finalizing"; liveSession?.finish() }
            else if state == "connecting" {
                liveAttempt = UUID()
                audioLock.lock(); let previousLiveSession = liveSession; liveSession = nil; audioLock.unlock()
                previousLiveSession?.cancel(); state = "ready"
            }
        } else if let client = streamClient {
            if state == "recording" { state = "finalizing"; detail = "正在等待尾句识别结果…"; client.finish() }
            else {
                streamAttempt = UUID(); client.cancel()
                audioLock.lock(); streamClient = nil; audioLock.unlock()
            }
        } else if state == "recording" { state = "finalizing"; command("stop") }
    }

    private func handle(_ event: [String:Any]) {
        guard !liveEnabled else { return }
        switch event["type"] as? String {
        case "config":
            guard let c = event["config"] as? [String:Any] else { return }
            asrProvider = c["provider"] as? String ?? "local"
            asrAPIProtocol = c["api_protocol"] as? String ?? "openai"
            activeAPIProtocol = asrAPIProtocol
            activeASRProvider = asrProvider
            asrAPIBaseURL = c["api_base_url"] as? String ?? "https://api.openai.com/v1"
            if asrAPIBaseURL.isEmpty { asrAPIBaseURL = "https://api.openai.com/v1" }
            asrAPIModel = c["api_model"] as? String ?? ""
            activeAPIBaseURL = asrAPIBaseURL
            activeAPIModel = asrAPIModel
            modelID = c["model_id"] as? String ?? modelID
            activeModelID = modelID
            localPath = c["local_model_path"] as? String ?? ""
            revision = c["revision"] as? String ?? ""
            preset = localPath.isEmpty && [Self.qwenID, Self.whisperID].contains(modelID) ? modelID : "custom"
            language = c["language"] as? String ?? "auto"
            previewInterval = c["preview_interval_ms"] as? Int ?? 1200
            endpointMode = c["endpoint_mode"] as? String ?? "smart"
            silence = c["endpoint_silence_ms"] as? Int ?? 1000
            maxSegment = c["max_segment_seconds"] as? Int ?? 18
            migrateLegacyStreamingConfig()
        case "status":
            let next = event["state"] as? String ?? "idle"
            if next != "recording", recording {
                stopInputs(); level = 0
                streamAttempt = UUID()
                audioLock.lock(); accepting = false; let stream = streamClient; streamClient = nil; audioLock.unlock()
                stream?.cancel()
            }
            state = next; detail = event["detail"] as? String ?? ""
            if next == "recording" { beginCapture() }
            if next == "ready" { partial = "" }
        case "partial", "final":
            guard event["session_id"] as? String == session,
                  let segment = event["segment_id"] as? Int, let rev = event["revision"] as? Int else { return }
            let id = "\(session):\(segment)"
            guard !seen.contains(id), rev > (revisions[segment] ?? 0) else { return }
            revisions[segment] = rev
            let text = event["text"] as? String ?? ""
            if event["type"] as? String == "final" {
                seen.insert(id)
                if !text.isEmpty {
                    rows[id] = finalText.count
                    finalText.append(Transcript(id:id, text:text, seconds:Double(event["start_sample"] as? Int ?? 0) / 16000))
                    translateFinal(id: id, text: text)
                }
                partial = ""
            } else { partial = text }
        case "translation":
            guard translationProvider == "local", translationEnabled else { return }
            // Translations may finish after a new session starts; they still belong to their original rows.
            guard let sessionID = event["session_id"] as? String, let segment = event["segment_id"] as? Int,
                  let unit = event["unit_id"] as? Int, let rev = event["revision"] as? Int,
                  let index = rows["\(sessionID):\(segment)"], finalText.indices.contains(index),
                  rev > (finalText[index].translations[unit]?.revision ?? -1) else { return }
            let text = event["text"] as? String ?? ""
            let done = event["done"] as? Bool ?? false
            finalText[index].translations[unit] = done && text.isEmpty ? nil : TranslationPart(text: text, revision: rev, done: done)
            if index == finalText.count - 1 { translationTick += 1 }
        case "translator":
            let previous = translatorState
            translatorState = event["state"] as? String ?? "idle"
            translatorDetail = event["detail"] as? String ?? ""
            activeTranslatorID = event["active_model"] as? String ?? ""
            guard let c = event["config"] as? [String:Any] else { return }
            translationProvider = c["provider"] as? String ?? "local"
            translationAPIProfile = c["api_profile"] as? String ?? ""
            translationEnabled = c["enabled"] as? Bool ?? false
            translationTarget = c["target_language"] as? String ?? "简体中文"
            // Keep an unsaved model choice in Settings until a load commits one.
            if !translatorSelectionLoaded || (translatorState == "ready" && previous != "ready") {
                translatorSelectionLoaded = true
                translatorModelID = c["model_id"] as? String ?? Self.translatorQwenID
                translatorRevision = c["revision"] as? String ?? ""
                translatorPreset = [Self.translatorQwenID, Self.translatorHunyuanID].contains(translatorModelID) ? translatorModelID : "custom"
            }
        case "progress":
            let completed = event["completed"] as? Double ?? 0, total = event["total"] as? Double ?? 1
            let value = total > 0 ? min(1, completed / total) : 0, label = event["detail"] as? String ?? ""
            if event["role"] as? String == "translator" { translatorProgress = value; translatorProgressLabel = label }
            else { progress = value; progressLabel = label }
        case "error": error = event["message"] as? String ?? "未知错误"
        default: break
        }
    }
    /// Streaming ASR uses a fixed endpoint and model. Configs saved with another address or model
    /// (e.g. the former Qwen-Audio realtime chat endpoint) are rewritten, carrying their Keychain key over.
    private func migrateLegacyStreamingConfig() {
        let old = asrAPIBaseURL
        guard asrProvider == "api", asrAPIProtocol == "qwen_realtime",
              old != StreamingASRConfiguration.endpoint || asrAPIModel != StreamingASRConfiguration.model else { return }
        asrAPIBaseURL = StreamingASRConfiguration.endpoint
        asrAPIModel = StreamingASRConfiguration.model
        let account = StreamingASRConfiguration.keyAccount
        if let key = try? APIKeyStore.read(endpoint:"asr:" + old), !key.isEmpty, (try? APIKeyStore.read(endpoint:account)) == nil {
            try? APIKeyStore.save(key, endpoint:account)
        }
        asrConnectionMessage = "已切换为固定流式识别模型 \(StreamingASRConfiguration.model)，正在应用新设置…"
        load()
    }
    func saveText() {
        TextExport.save(exportText) { [weak self] message in self?.error = message }
    }
    func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exportText, forType: .string) }
    func clear() { guard !busy else { return }; stopReplay(); replayCache.clear(); replayRevision = replayCache.revision; cancelLiveTranslations(); finalText.removeAll(); rows.removeAll(); seen.removeAll(); revisions.removeAll(); partial = "" }

    func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if hotHandler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
                let model = Unmanaged<AppModel>.fromOpaque(pointer).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                    if model.holdToTalk { model.start() } else { model.toggle() }
                } else if model.holdToTalk { model.stop() }
                return noErr
            }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &hotHandler)
        }
        let code = shortcutKey == "R" ? kVK_ANSI_R : shortcutKey == "D" ? kVK_ANSI_D : kVK_Space
        let result = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4C415352, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { error = "快捷键已被占用，请更换按键" }
    }
}


extension AppModel {
    @discardableResult
    func saveLiveSettings(enabled: Bool? = nil) -> Bool {
        guard !liveSettingsBusy else { return false }
        do {
            var next = liveConfiguration
            next.enabled = enabled ?? liveEnabled; next.provider = liveProvider; next.endpoint = liveEndpoint
            next.language = liveLanguage; next.audioOutput = liveAudioOutput; next.volume = liveVolume
            next.playbackTiming = livePlaybackTiming
            if next.enabled && next.provider == .hyLocal && !hyRuntimeVerified {
                liveMessage = hyRuntimeUnavailableReason
                return false
            }
            next = try next.normalized()
            let key = liveKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if next.provider == .qwenCloud, !key.isEmpty { try APIKeyStore.save(key, endpoint: next.keyAccount) }
            try next.save(defaults: liveDefaults)
            let changedMode = next.enabled != liveEnabled || next.provider != liveConfiguration.provider
            if changedMode { shutdown() }
            liveConfiguration = next; liveEndpoint = next.endpoint; liveLanguage = next.language; liveKeyInput = ""
            liveMessage = next.provider == .hyLocal ? "本地设置已保存，下次会话生效" : (key.isEmpty ? "设置已保存；保留此地址已有的密钥" : "设置已保存；专用 API Key 已存入钥匙串")
            if changedMode { launch(); loadChosenHyModel() }
            return true
        } catch { liveMessage = error.localizedDescription; return false }
    }
    func setLiveEnabled(_ enabled: Bool) {
        guard !liveSettingsBusy, enabled != liveEnabled else { return }
        if enabled && liveProvider == .hyLocal && !hyRuntimeVerified {
            liveMessage = hyRuntimeUnavailableReason
            return
        }
        if enabled { _ = saveLiveSettings(enabled: true) }
        else {
            // Leaving the mode must work even if its settings editor contains an invalid draft.
            do {
                var next = liveConfiguration; next.enabled = false; try next.save(defaults: liveDefaults)
                shutdown(); liveConfiguration = next; launch()
            } catch { liveMessage = error.localizedDescription }
        }
    }
    func setLiveProvider(_ provider: LiveTranslateProvider) {
        guard !liveSettingsBusy, provider != liveProvider else { return }
        guard provider != .hyLocal || hyRuntimeVerified else {
            liveMessage = hyRuntimeUnavailableReason
            return
        }
        do {
            // A provider switch restores its saved choices. Unsaved drafts (including a broken
            // cloud address) must not block leaving a provider or silently change its saved state.
            let next = liveConfiguration.selecting(provider)
            try next.save(defaults: liveDefaults)
            shutdown(); liveConfiguration = next; liveProvider = provider
            liveEndpoint = next.endpoint; liveLanguage = next.language; liveAudioOutput = next.audioOutput
            liveVolume = next.volume; livePlaybackTiming = next.playbackTiming; liveKeyInput = ""
            liveMessage = "已切换翻译方式，并恢复该方式已保存的设置"
            launch(); loadChosenHyModel()
        } catch { liveMessage = error.localizedDescription }
    }
    /// Turning the switches on is the request to use the model. A plain app launch stays idle, like
    /// the other local models: 23 GB of memory should not be taken just because the app opened.
    private func loadChosenHyModel() {
        if canLoadHyModel, !hyMemoryIsLow, hyModelStore.hasCachedFile { loadHyModel() }
    }
    func downloadHyModel() {
        guard !liveSettingsBusy, hyRuntimeVerified else { liveMessage = hyRuntimeUnavailableReason; return }
        hyModelStore.download()
    }
    func loadHyModel() {
        guard !liveSettingsBusy, liveEnabled, liveConfiguration.provider == .hyLocal,
              hyRuntimeState != "loading", hyModelStore.state != "downloading" else { return }
        guard hyRuntimeVerified, let executable = runtimeExecutable() else {
            liveMessage = hyRuntimeUnavailableReason; return
        }
        let attempt = UUID(); hyLoadAttempt = attempt
        hyRuntimeState = "loading"; hyRuntimeDetail = "正在校验并加载本地 Hy-SimulMT…"
        state = "loading"; error = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hyModelStore.refresh()
            guard self.hyLoadAttempt == attempt, self.liveEnabled, self.liveConfiguration.provider == .hyLocal else { return }
            guard let path = self.hyModelStore.modelPath else {
                self.hyRuntimeState = "error"; self.hyRuntimeDetail = self.hyModelStore.detail
                self.state = "idle"; self.detail = self.hyModelStore.detail; return
            }
            self.hyRuntime.onLoaded = { [weak self] in
                guard let self, self.hyLoadAttempt == attempt else { return }
                self.hyRuntimeState = "ready"; self.hyRuntimeDetail = "Hy-SimulMT 已加载，可开始中英实时翻译"
                self.state = "ready"; self.detail = self.hyRuntimeDetail
            }
            self.hyRuntime.onLoadFailure = { [weak self] message in
                guard let self, self.hyLoadAttempt == attempt else { return }
                self.hyRuntimeState = "error"; self.hyRuntimeDetail = message
                self.state = "error"; self.error = message
            }
            do { try self.hyRuntime.load(executableURL: executable, modelURL: URL(fileURLWithPath: path)) }
            catch {
                self.hyRuntimeState = "error"; self.hyRuntimeDetail = error.localizedDescription
                self.state = "error"; self.error = error.localizedDescription
            }
        }
    }
    func unloadHyModel() {
        guard !liveSettingsBusy else { return }
        hyLoadAttempt = UUID(); hyRuntime.unload()
        if hyModelStore.state == "checking" { hyModelStore.cancel() }
        hyRuntimeState = "idle"; hyRuntimeDetail = "本地模型已卸载"
        if liveEnabled && liveConfiguration.provider == .hyLocal { state = "idle"; detail = hyRuntimeDetail }
    }
    func testLiveConnection() {
        guard !inputBusy, !liveSettingsBusy, saveLiveSettings() else { return }
        if liveConfiguration.provider == .hyLocal && (!hyRuntimeVerified || hyRuntimeState != "ready") {
            liveMessage = hyRuntimeVerified ? "请先加载本地 Hy-SimulMT 模型" : hyRuntimeUnavailableReason
            return
        }
        connectLive(test: true)
    }
    private func connectLive(test: Bool) {
        let attempt = UUID(); liveAttempt = attempt
        let currentSession = test ? UUID().uuidString : session
        let configuration = liveConfiguration
        let client: any LiveTranslationSession
        if let factory = liveSessionFactory { client = factory(configuration.provider) }
        else if configuration.provider == .qwenCloud { client = QwenLiveTranslationSession(client: liveClientFactory()) }
        else { client = hyRuntime }
        audioLock.lock(); liveSession = client; audioLock.unlock()
        liveTesting = test
        if !test {
            liveAudioPlayer.stop(); localSpeech.stop(); livePlaying = false; liveAudioMuted = false
            liveRowRevisions.removeAll(); liveRowRanges.removeAll(); liveUntranslatedRanges.removeAll(); livePlaybackSession = UUID()
            liveSentenceRows = LiveSentenceRows()
            state = "connecting"; detail = configuration.provider == .hyLocal ? "正在启动本地翻译会话…" : "正在连接 LiveTranslate…"
        }
        liveMessage = configuration.provider == .hyLocal ? "正在确认本地会话…" : "正在连接并确认会话配置…"
        client.onReady = { [weak self, weak client] in
            guard let self, self.liveAttempt == attempt, let client, self.liveSession === client else { return }
            if test { client.finish() }
            else {
                guard self.pendingStart else { client.cancel(); return }
                if configuration.provider == .hyLocal {
                    self.localSpeech.start(session: currentSession, language: configuration.language,
                        volume: Double(configuration.volume), timing: configuration.playbackTiming, enabled: configuration.audioOutput)
                } else if configuration.audioOutput {
                    self.liveAudioPlayer.onFailure = { [weak self] message in self?.error = message; self?.stopLivePlayback() }
                    do { try self.liveAudioPlayer.start(volume: configuration.volume) }
                    catch { self.error = "无法播放译音，请检查系统声音输出；字幕继续更新"; self.liveAudioMuted = true }
                }
                self.state = "recording"; self.beginCapture()
            }
        }
        client.onEvent = { [weak self] event in
            guard let self, !test, self.liveAttempt == attempt, self.session == currentSession else { return }
            switch event {
            case .update(let update):
                let placed: LiveSentenceRows.Placement
                if configuration.provider == .hyLocal {
                    guard update.revision > (self.liveRowRevisions[update.segmentID] ?? -1) else { return }
                    placed = self.liveSentenceRows.place(update)
                } else {
                    placed = .init(row: update.segmentID, source: update.source ?? "", translation: update.translation,
                                   startSample: update.startSample, endSample: update.endSample)
                }
                guard self.publishLiveUpdate(update, placed: placed) else { return }
                if configuration.provider == .hyLocal {
                    if configuration.audioOutput && update.committed && update.translationDone && !placed.translation.isEmpty {
                        self.replayCache.insert(.speech(text: placed.translation, language: configuration.language),
                            for: "\(currentSession):live:\(placed.row)")
                        self.replayRevision = self.replayCache.revision
                    }
                    if !self.liveAudioMuted {
                        self.localSpeech.consume(session: currentSession, itemID: update.segmentID,
                            text: update.translation, committed: update.committed, final: update.translationDone)
                    }
                }
            case .audio(let pcm):
                guard configuration.audioOutput, !self.liveAudioMuted else { return }
                do { try self.liveAudioPlayer.append(pcm); self.livePlaying = true }
                catch { self.error = error.localizedDescription; self.stopLivePlayback() }
            case .audioPending:
                if configuration.audioOutput && !self.liveAudioMuted { self.livePlaying = true }
            case .replayClip(let segmentID, let pcm):
                self.replayCache.insert(.pcm(pcm), for: "\(currentSession):live:\(segmentID)")
                self.replayRevision = self.replayCache.revision
            case .playbackWarning(let message):
                guard !self.liveAudioMuted else { return }
                self.error = message; self.stopLivePlayback()
            case .untranslatedAudio(let start, let end):
                self.liveUntranslatedRanges.append((start, end))
                self.error = String(format: "%.1f–%.1f 秒的音频未能完整翻译，已有文字已保留", Double(start) / 16000, Double(end) / 16000)
                for (segmentID, range) in self.liveRowRanges where range.0 < end && range.1 > start {
                    if let index = self.rows["\(currentSession):live:\(segmentID)"] { self.finalText[index].incomplete = true }
                }
                self.translationTick += 1
            }
        }
        client.onEnd = { [weak self] message in
            guard let self, self.liveAttempt == attempt else { return }
            self.liveAttempt = UUID()
            self.audioLock.lock(); self.accepting = false; self.liveSession = nil; self.audioLock.unlock()
            self.liveTesting = false
            if !test {
                self.stopInputs(); self.pendingStart = false; self.level = 0
                self.settleLiveRows()
                if let message { self.error = message }
                // Local speech can hold an unfinished phrase without playing yet. A successful
                // session must flush that tail; cancellation and failures must only discard it.
                if message == nil && !self.liveAudioMuted && (self.livePlaying || configuration.provider == .hyLocal) {
                    self.state = "finalizing"; self.detail = "正在播放最后一段译音…"
                    let playback = self.livePlaybackSession
                    let drained: () -> Void = { [weak self] in
                        guard let self, self.livePlaybackSession == playback else { return }
                        self.livePlaying = false; self.state = "ready"
                    }
                    if configuration.provider == .hyLocal { self.localSpeech.finish(completion: drained) }
                    else { self.liveAudioPlayer.finish(drained) }
                } else { self.stopLivePlayback(); self.state = "ready" }
            }
            let testPassed = configuration.provider == .hyLocal ? "本地会话正常，模型已就绪" : "连接成功，已确认所选输出方式与目标语言"
            self.liveMessage = message ?? (test ? testPassed : "本次会话已结束")
        }
        do {
            let key = configuration.provider == .qwenCloud ? (try liveKeyReader(configuration.keyAccount) ?? "") : ""
            try client.start(configuration: configuration, key: key, sessionID: currentSession)
        } catch {
            client.cancel()
            audioLock.lock(); accepting = false; liveSession = nil; audioLock.unlock()
            liveTesting = false; pendingStart = false
            liveMessage = error.localizedDescription
            if !test { state = "ready"; self.error = error.localizedDescription }
        }
    }
    func canReplay(_ transcript: Transcript) -> Bool {
        transcript.sourceDone && !transcript.incomplete && !transcript.translating && replayCache.content(for: transcript.id) != nil
    }
    func replay(_ transcript: Transcript) {
        if replayingTranscriptID == transcript.id { stopReplay(); return }
        guard canReplay(transcript), let content = replayCache.content(for: transcript.id) else { return }
        stopReplay(); stopLivePlayback()
        let attempt = UUID(); replayAttempt = attempt
        let complete: () -> Void = { [weak self] in
            guard let self, self.replayAttempt == attempt else { return }
            self.replayingTranscriptID = nil
        }
        replayingTranscriptID = transcript.id
        switch content {
        case .speech(let text, let language):
            replaySpeech.replay(text: text, language: language, volume: Double(liveConfiguration.volume), completion: complete)
        case .pcm(let pcm):
            replayPlayer.onFailure = { [weak self] message in
                guard let self, self.replayAttempt == attempt else { return }
                self.error = message; self.stopReplay()
            }
            do {
                try replayPlayer.start(volume: liveConfiguration.volume)
                try replayPlayer.append(pcm); replayPlayer.finish(complete)
            } catch { self.error = "无法重播译音，请检查系统声音输出"; stopReplay() }
        }
    }
    func stopReplay() {
        replayAttempt = UUID(); replayPlayer.stop(); replaySpeech.stop(); replayingTranscriptID = nil
    }
    func stopLivePlayback() {
        livePlaybackSession = UUID(); liveAudioMuted = true
        liveSession?.stopAutomaticPlayback()
        liveAudioPlayer.stop(); localSpeech.stop(); livePlaying = false
        if liveEnabled && state == "finalizing" && liveSession == nil { state = "ready" }
    }
    @discardableResult
    private func publishLiveUpdate(_ update: LiveTranslationUpdate, placed: LiveSentenceRows.Placement) -> Bool {
        guard update.revision > (liveRowRevisions[update.segmentID] ?? -1) else { return false }
        liveRowRevisions[update.segmentID] = update.revision
        liveRowRanges[placed.row] = (placed.startSample, placed.endSample)
        guard !placed.source.isEmpty || !placed.translation.isEmpty else { return true }
        let id = "\(session):live:\(placed.row)"
        let index: Int
        let added = rows[id] == nil
        if let existing = rows[id] { index = existing }
        else {
            index = finalText.count; rows[id] = index
            finalText.append(Transcript(id: id, text: "", seconds: Double(placed.startSample) / 16000))
        }
        var row = finalText[index]
        let moved = row.seconds != Double(placed.startSample) / 16000
        row.text = placed.source; row.seconds = Double(placed.startSample) / 16000
        row.sourceDone = update.source == nil || update.sourceDone
        row.incomplete = update.incomplete || liveUntranslatedRanges.contains { placed.startSample < $0.1 && placed.endSample > $0.0 }
        row.translations[-2] = TranslationPart(text: placed.translation, revision: update.revision, done: update.translationDone)
        finalText[index] = row
        // Updates arrive once per generated token; order can only change with a new row or start time.
        if added || moved {
            let prefix = "\(session):live:"
            let current = finalText.enumerated().filter { $0.element.id.hasPrefix(prefix) }.sorted {
                $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
            }.map(\.element)
            finalText = finalText.filter { !$0.id.hasPrefix(prefix) } + current
            rows = Dictionary(uniqueKeysWithValues: finalText.enumerated().map { ($0.element.id, $0.offset) })
        }
        translationTick += 1
        return true
    }
    private func settleLiveRows() {
        for index in finalText.indices where finalText[index].id.hasPrefix("\(session):live:") {
            if !finalText[index].sourceDone || finalText[index].translating { finalText[index].incomplete = true }
            if var part = finalText[index].translations[-2] { part.done = true; finalText[index].translations[-2] = part }
        }
        translationTick += 1
    }
}
