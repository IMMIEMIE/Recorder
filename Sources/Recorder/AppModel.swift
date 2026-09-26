import SwiftUI
import AVFoundation
import Carbon
import UniformTypeIdentifiers

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
    private var asrAudio: [String:Data] = [:]
    private var asrTask: Task<Void, Never>?
    private var asrTestTask: Task<Void, Never>?
    private var activeASRProvider = "local"
    private var activeAPIBaseURL = ""
    private var activeAPIModel = ""
    private var activeAPIProtocol = "openai"
    private var activeASRLanguage = "auto"
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
    /// Must match TRANSLATION_TARGETS in backend/core.py.
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
    private var transport: Transport?
    private var process: Process?
    private var stderrPipe: Pipe?
    private let diagnosticLock = NSLock()
    private var backendDiagnostic = ""
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
    private var socketPath = ""
    @Published private(set) var liveConfiguration = LiveTranslateConfiguration()
    @Published var liveEndpoint = LiveTranslateConfiguration().endpoint
    @Published var liveLanguage = "zh"
    @Published var liveKeyInput = ""
    @Published var liveMessage = ""
    @Published private(set) var liveTesting = false
    private let liveClientFactory: () -> LiveTranslateClient
    private let liveKeyReader: (String) throws -> String?
    private let liveDefaults: UserDefaults
    private var liveClient: LiveTranslateClient?
    private var liveEvents = LiveTranslateEvents()
    private var liveAttempt = UUID()
    var liveEnabled: Bool { liveConfiguration.enabled }
    var liveSettingsBusy: Bool { recording || pendingStart || state == "finalizing" || liveTesting }
    var canStop: Bool { recording || pendingStart || (liveEnabled && state == "connecting") }


    var busy: Bool { !["idle", "ready", "error"].contains(state) }
    var inputBusy: Bool { busy || pendingStart || liveTesting || asrTesting }
    var qwenASR: Bool { asrProvider == "api" && asrAPIProtocol == "qwen_realtime" }
    var recording: Bool { state == "recording" }
    var canStart: Bool {
        if liveEnabled { return state == "ready" && !liveTesting }
        return state == "ready" && !asrTesting && asrProvider == activeASRProvider &&
        (asrProvider != "api" || (asrAPIBaseURL == activeAPIBaseURL && asrAPIModel == activeAPIModel && asrAPIProtocol == activeAPIProtocol))
    }
    var joinedText: String { finalText.map(\.text).joined(separator: "\n") }
    var exportText: String {
        let translated = finalText.contains { !$0.translation.isEmpty }
        return finalText.map { item in
            let translation = item.translation
            return translation.isEmpty ? item.text : item.text + "\n" + translation
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
        if liveEnabled { return "LiveTranslate → \(liveConfiguration.languageName)" }
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
         liveKeyReader: @escaping (String) throws -> String? = { try APIKeyStore.read(endpoint: $0) }) {
        self.liveClientFactory = liveClientFactory; self.liveKeyReader = liveKeyReader
        liveDefaults = defaults
        liveConfiguration = LiveTranslateConfiguration.load(defaults: defaults)
        liveEndpoint = liveConfiguration.endpoint; liveLanguage = liveConfiguration.language
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
        if liveEnabled { state = "ready"; detail = "LiveTranslate 已就绪"; error = ""; return }
        generation = UUID()
        let currentGeneration = generation
        state = "connecting"; error = ""
        translatorSelectionLoaded = false
        let resources = Bundle.main.resourceURL!
        let python = resources.appendingPathComponent("runtime/bin/python3")
        let script = resources.appendingPathComponent("backend/server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            state = "error"; error = "运行环境缺失，请使用 scripts/build.sh 构建完整应用"; return
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalRecorder")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent("config.json")
            let initial = resources.appendingPathComponent("initial-config.json")
            if !FileManager.default.fileExists(atPath: configURL.path), FileManager.default.fileExists(atPath: initial.path) { try FileManager.default.copyItem(at: initial, to: configURL) }
        } catch { self.error = "无法创建本地配置目录"; state = "error"; return }
        socketPath = "/tmp/recorder-\(UUID().uuidString).sock"
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--socket", socketPath, "--root", root.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["NUMBA_CACHE_DIR"] = root.appendingPathComponent("numba-cache").path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        stderrPipe = stderr
        diagnosticLock.lock(); backendDiagnostic = ""; diagnosticLock.unlock()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.diagnosticLock.lock()
            self.backendDiagnostic = String((self.backendDiagnostic + String(decoding: data, as: UTF8.self)).suffix(2000))
            self.diagnosticLock.unlock()
        }
        process.standardError = stderr
        process.terminationHandler = { [weak self] child in DispatchQueue.main.async {
            guard let self, self.generation == currentGeneration else { return }
            self.stopInputs(); self.state = "error"
            self.diagnosticLock.lock(); let diagnostic = self.backendDiagnostic; self.diagnosticLock.unlock()
            self.error = "推理服务退出（代码 \(child.terminationStatus)）。点击重新连接恢复。\n" + diagnostic
        } }
        do { try process.run(); self.process = process }
        catch { state = "error"; self.error = "无法启动 Python 运行环境：\(error.localizedDescription)"; return }
        let path = socketPath
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<100 {
                let channel = Transport()
                do {
                    try channel.connect(path: path)
                    DispatchQueue.main.async {
                        guard let self, self.generation == currentGeneration else { channel.close(); return }
                        self.transport = channel
                        channel.onEvent = { [weak self] event in DispatchQueue.main.async {
                            guard self?.generation == currentGeneration else { return }; self?.handle(event)
                        } }
                        channel.onFailure = { [weak self] message in DispatchQueue.main.async {
                            guard let self, self.generation == currentGeneration else { return }
                            self.stopInputs(); self.state = "error"; self.error = message
                        } }
                        self.command("hello")
                    }
                    return
                } catch { Thread.sleep(forTimeInterval: 0.1) }
            }
            DispatchQueue.main.async {
                guard self?.generation == currentGeneration, self?.process?.isRunning == true else { return }
                self?.state = "error"; self?.error = "推理服务连接超时，请重新连接"
            }
        }
    }

    func shutdown() {
        asrTask?.cancel(); asrTask = nil; asrTestTask?.cancel(); asrTestTask = nil
        asrAudio.removeAll(); asrTesting = false
        liveAttempt = UUID()
        liveClient?.cancel(); liveClient = nil; liveTesting = false
        settleLiveRows()
        cancelLiveTranslations()
        generation = UUID()
        pendingStart = false
        audioLock.lock(); accepting = false; audioLock.unlock()
        stopInputs()
        transport?.close(); transport = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        if !socketPath.isEmpty { try? FileManager.default.removeItem(atPath: socketPath) }
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
                if !qwenASR { extra["api_key"] = key }
                command("load", extra:extra)
            } catch { self.error = error.localizedDescription }
        } else { command(download ? "download" : "load", extra:["config":config]) }
    }
    var activeModelName: String {
        if liveEnabled { return "Qwen3.8 LiveTranslate" }
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
            asrAPIBaseURL = QwenRealtimeASRConfiguration.endpoint
            asrAPIModel = QwenRealtimeASRConfiguration.model
            endpointMode = "fixed"
        } else { asrAPIBaseURL = "https://api.openai.com/v1"; asrAPIModel = "" }
    }
    private func normalizedASREndpoint() throws -> String {
        if qwenASR {
            return try QwenRealtimeASRConfiguration(endpoint:asrAPIBaseURL, model:asrAPIModel, language:language).normalizedEndpoint()
        }
        var base = asrAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/audio/transcriptions") { base.removeLast("/audio/transcriptions".count) }
        return try AIProfile.normalize(base)
    }
    func testASRConnection() {
        guard qwenASR, !liveEnabled, !inputBusy else { return }
        do {
            let base = try normalizedASREndpoint()
            let keyInput = asrAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyInput.isEmpty { try APIKeyStore.save(keyInput, endpoint:"asr:" + base); asrAPIKeyInput = "" }
            let key = try APIKeyStore.read(endpoint:"asr:" + base) ?? ""
            let configuration = QwenRealtimeASRConfiguration(endpoint:base, model:asrAPIModel, language:language)
            let currentGeneration = generation
            asrTesting = true; asrConnectionMessage = "正在连接千问并确认手动转写模式…"
            asrTestTask = Task { @MainActor [weak self] in
                var message = "连接成功，已确认转写模式；测试未发送音频"
                do { _ = try await QwenRealtimeASRClient().transcribe(configuration:configuration, key:key, pcm:nil) }
                catch { message = error.localizedDescription }
                guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                self.asrTesting = false; self.asrTestTask = nil; self.asrConnectionMessage = message
            }
        } catch { asrConnectionMessage = error.localizedDescription }
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
            self.command("start", extra: ["endpoint_mode": self.endpointMode, "endpoint_silence_ms": self.silence])
        }
        if audioSource == "microphone" {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in DispatchQueue.main.async {
                self?.updatePermission(); begin(granted)
            } }
        } else { begin(true) }
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
        let sent = liveEnabled ? (liveClient?.append(pcm) ?? false) : (transport?.audio(pcm, session: session, sequence: sequence, start: samples) ?? false)
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
            if state == "recording" { state = "finalizing"; liveClient?.finish() }
            else if state == "connecting" {
                liveAttempt = UUID(); liveClient?.cancel(); liveClient = nil; state = "ready"
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
            activeASRLanguage = language
            previewInterval = c["preview_interval_ms"] as? Int ?? 1200
            endpointMode = c["endpoint_mode"] as? String ?? "smart"
            silence = c["endpoint_silence_ms"] as? Int ?? 1000
            maxSegment = c["max_segment_seconds"] as? Int ?? 18
        case "asr_api_audio":
            receiveQwenAudio(event)
        case "status":
            let next = event["state"] as? String ?? "idle"
            if next != "recording", recording { stopInputs(); audioLock.lock(); accepting = false; audioLock.unlock(); level = 0 }
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
    private func receiveQwenAudio(_ event: [String:Any]) {
        guard activeASRProvider == "api", activeAPIProtocol == "qwen_realtime",
              event["session_id"] as? String == session, let call = event["call_id"] as? String,
              let encoded = event["audio"] as? String, let data = Data(base64Encoded:encoded) else { return }
        var pcm = asrAudio[call] ?? Data(); pcm.append(data)
        guard pcm.count <= 800_000 else {
            asrAudio[call] = nil
            command("asr_api_result", extra:["call_id":call, "error":"千问音频片段过长"])
            return
        }
        asrAudio[call] = pcm
        guard event["done"] as? Bool == true else { return }
        asrAudio[call] = nil
        guard asrTask == nil else {
            command("asr_api_result", extra:["call_id":call, "error":"千问识别请求仍在处理中"]); return
        }
        let currentGeneration = generation, currentSession = session
        let configuration = QwenRealtimeASRConfiguration(endpoint:activeAPIBaseURL, model:activeAPIModel, language:activeASRLanguage)
        asrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var result: [String:Any] = ["call_id":call]
            do {
                let key = try APIKeyStore.read(endpoint:"asr:" + configuration.endpoint) ?? ""
                result["text"] = try await QwenRealtimeASRClient().transcribe(configuration:configuration, key:key, pcm:pcm) { [weak self] text in
                    guard let self, self.generation == currentGeneration, self.session == currentSession else { return }
                    self.partial = text
                }
            } catch { result["error"] = error.localizedDescription }
            guard self.generation == currentGeneration, self.session == currentSession, !Task.isCancelled else { return }
            self.asrTask = nil
            self.command("asr_api_result", extra:result)
        }
    }
    func saveText() {
        TextExport.save(exportText) { [weak self] message in self?.error = message }
    }
    func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exportText, forType: .string) }
    func clear() { guard !busy else { return }; cancelLiveTranslations(); finalText.removeAll(); rows.removeAll(); seen.removeAll(); revisions.removeAll(); partial = "" }

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
            var next = LiveTranslateConfiguration(enabled: enabled ?? liveEnabled, endpoint: liveEndpoint, language: liveLanguage)
            next = try next.normalized()
            let key = liveKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try APIKeyStore.save(key, endpoint: next.keyAccount) }
            try next.save(defaults: liveDefaults)
            let changedMode = next.enabled != liveEnabled
            // Stop the old service before publishing the new selection.
            if changedMode { shutdown() }
            liveConfiguration = next; liveEndpoint = next.endpoint; liveLanguage = next.language; liveKeyInput = ""
            liveMessage = key.isEmpty ? "设置已保存；保留此地址已有的密钥" : "设置已保存；专用 API Key 已存入钥匙串"
            if changedMode { launch() }
            return true
        } catch { liveMessage = error.localizedDescription; return false }
    }
    func setLiveEnabled(_ enabled: Bool) {
        guard !liveSettingsBusy, enabled != liveEnabled else { return }
        if enabled { _ = saveLiveSettings(enabled: true) }
        else {
            // Leaving the mode must work even if the settings editor contains an invalid draft.
            do {
                var next = liveConfiguration; next.enabled = false; try next.save(defaults: liveDefaults)
                shutdown(); liveConfiguration = next; launch()
            } catch { liveMessage = error.localizedDescription }
        }
    }
    func testLiveConnection() {
        guard !inputBusy, !liveSettingsBusy, saveLiveSettings() else { return }
        connectLive(test: true)
    }
    private func connectLive(test: Bool) {
        let attempt = UUID(); liveAttempt = attempt
        let currentSession = session
        let client = liveClientFactory()
        liveClient = client; liveTesting = test
        if !test { state = "connecting"; detail = "正在连接 LiveTranslate…"; liveEvents = LiveTranslateEvents() }
        liveMessage = "正在连接并确认会话配置…"
        client.onReady = { [weak self, weak client] in
            guard let self, self.liveAttempt == attempt, self.liveClient === client else { return }
            if test { client?.finish() }
            else {
                guard self.pendingStart else { client?.cancel(); return }
                self.state = "recording"; self.beginCapture()
            }
        }
        client.onEvent = { [weak self] event in
            guard let self, !test, self.liveAttempt == attempt, self.session == currentSession else { return }
            self.liveEvents.apply(event)
            self.publishLiveRows()
        }
        client.onEnd = { [weak self] message in
            guard let self, self.liveAttempt == attempt else { return }
            self.liveAttempt = UUID()
            if !test {
                self.audioLock.lock(); self.accepting = false; self.audioLock.unlock()
                self.stopInputs()
                self.pendingStart = false; self.level = 0
                self.preserveUnmatchedLiveOutput()
                self.settleLiveRows()
                self.state = "ready"
                if let message { self.error = message }
                else if self.liveEvents.hasUnmatchedOutput { self.error = "部分译文未收到对应句子信息，请重新连接服务" }
            }
            self.liveTesting = false; self.liveClient = nil
            self.liveMessage = message ?? (test ? "连接成功，已确认文本输出与目标语言" : "本次会话已结束")
        }
        do {
            let key = try liveKeyReader(liveConfiguration.keyAccount) ?? ""
            try client.connect(configuration: liveConfiguration, key: key)
        } catch {
            client.cancel(); liveClient = nil; liveTesting = false; pendingStart = false
            liveMessage = error.localizedDescription
            if !test { state = "ready"; self.error = error.localizedDescription }
        }
    }
    private func publishLiveRows() {
        var changed = false
        for sourceID in liveEvents.order {
            guard let row = liveEvents.rows[sourceID] else { continue }
            let translation = liveEvents.translation(for: row)
            guard !row.source.text.isEmpty || !translation.text.isEmpty else { continue }
            let id = "\(session):live:\(sourceID)"
            let index: Int
            if let existing = rows[id] { index = existing }
            else {
                index = finalText.count; rows[id] = index
                finalText.append(Transcript(id: id, text: "", seconds: row.seconds))
            }
            let previous = finalText[index]
            guard previous.text != row.source.text || previous.seconds != row.seconds || previous.sourceDone != row.source.done ||
                    previous.translations[-2]?.text != translation.text || previous.translations[-2]?.done != translation.done else { continue }
            var updated = previous
            updated.text = row.source.text; updated.seconds = row.seconds; updated.sourceDone = row.source.done
            updated.translations[-2] = TranslationPart(text: translation.text, revision: 0, done: translation.done)
            finalText[index] = updated; changed = true
        }
        if changed {
            // Late ASR/translation must not move an earlier spoken sentence behind a newer one.
            let prefix = "\(session):live:"
            let orderedIDs = liveEvents.order.enumerated().sorted {
                let left = liveEvents.rows[$0.element]?.seconds ?? 0
                let right = liveEvents.rows[$1.element]?.seconds ?? 0
                return left == right ? $0.offset < $1.offset : left < right
            }.map { prefix + $0.element }
            let currentIDs = finalText.filter { $0.id.hasPrefix(prefix) }.map(\.id)
            let visibleIDs = orderedIDs.filter { rows[$0] != nil }
            if currentIDs != visibleIDs {
                let current = Dictionary(uniqueKeysWithValues: finalText.filter { $0.id.hasPrefix(prefix) }.map { ($0.id, $0) })
                finalText = finalText.filter { !$0.id.hasPrefix(prefix) } + visibleIDs.compactMap { current[$0] }
                rows = Dictionary(uniqueKeysWithValues: finalText.enumerated().map { ($0.element.id, $0.offset) })
            }
            translationTick += 1
        }
    }
    private func preserveUnmatchedLiveOutput() {
        for (outputID, part) in liveEvents.unmatchedOutputs {
            let id = "\(session):live:unmatched:\(outputID)"
            guard rows[id] == nil else { continue }
            rows[id] = finalText.count
            var row = Transcript(id: id, text: "", seconds: 0, sourceDone: false, incomplete: true)
            row.translations[-2] = TranslationPart(text: part.text, revision: 0, done: true)
            finalText.append(row)
        }
    }
    private func settleLiveRows() {
        for index in finalText.indices where finalText[index].id.hasPrefix("\(session):live:") {
            if !finalText[index].sourceDone || finalText[index].translating { finalText[index].incomplete = true }
            if var part = finalText[index].translations[-2] {
                part.done = true; finalText[index].translations[-2] = part
            }
        }
        translationTick += 1
    }
}
