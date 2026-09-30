import Foundation

enum ASRValidation {
    /// Bundled Whisper assets (Contents/Resources/whisper), set by the app before the backend starts.
    /// nil skips the asset check (builds without the MLX model layer, and the backend tests).
    static var whisperAssets: URL?

    /// adapter.py validate_config: file-level snapshot checks per architecture.
    static func validate(config: ModelConfig, path: URL) throws {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            var data = Data()
            for byte in buffer where byte != 0 { data.append(byte) }
            return String(decoding: data, as: UTF8.self)
        }
        guard machine == "arm64" else { throw BackendError.value("MLX 后端需要 Apple Silicon macOS") }
        let configPath = path.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw BackendError.value("离线资源缺失: config.json")
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: configPath)) as? [String: Any] ?? [:]
        if raw["auto_map"] != nil { throw BackendError.value("不支持需要执行自定义远程代码的模型") }
        guard let architecture = raw["model_type"] as? String else {
            throw BackendError.value("仅支持 MLX Qwen3-ASR 和 MLX Whisper 架构")
        }
        if architecture == "qwen3_asr" {
            for name in ["tokenizer_config.json", "preprocessor_config.json", "vocab.json", "merges.txt"] {
                guard FileManager.default.fileExists(atPath: path.appendingPathComponent(name).path) else {
                    throw BackendError.value("离线资源缺失: \(name)")
                }
            }
            let tokenizer = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("tokenizer_config.json"))) as? [String: Any] ?? [:]
            if tokenizer["auto_map"] != nil { throw BackendError.value("不支持需要执行自定义远程代码的模型") }
            let weights = ((try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []).filter { $0.hasSuffix(".safetensors") }
            guard !weights.isEmpty else { throw BackendError.value("离线资源缺失: *.safetensors 权重") }
            let index = path.appendingPathComponent("model.safetensors.index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let map = (try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])?["weight_map"] as? [String: String] ?? [:]
                for name in Set(map.values) {
                    guard FileManager.default.fileExists(atPath: path.appendingPathComponent(name).path) else {
                        throw BackendError.value("离线资源缺失: \(name)")
                    }
                }
            }
        } else if architecture == "whisper" {
            let required = ["n_mels", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
                            "n_vocab", "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer"]
            for key in required {
                guard let value = strictJSONInt(raw[key] ?? NSNull()), value > 0 else {
                    throw BackendError.value("需要 MLX Whisper 格式的 config.json，不能直接加载 Transformers/PyTorch 权重")
                }
            }
            let hasWeights = FileManager.default.fileExists(atPath: path.appendingPathComponent("weights.safetensors").path) ||
                FileManager.default.fileExists(atPath: path.appendingPathComponent("weights.npz").path)
            guard hasWeights else { throw BackendError.value("离线资源缺失: weights.safetensors 或 weights.npz") }
            if let assets = whisperAssets {
                guard FileManager.default.fileExists(atPath: assets.path) else {
                    throw BackendError.value("Whisper 运行环境缺失，请重新安装应用")
                }
                for name in ["mel_filters.npz", "multilingual.tiktoken", "gpt2.tiktoken"] {
                    guard FileManager.default.fileExists(atPath: assets.appendingPathComponent(name).path) else {
                        throw BackendError.value("Whisper 离线辅助资源缺失: \(name)")
                    }
                }
            }
        } else {
            throw BackendError.value("仅支持 MLX Qwen3-ASR 和 MLX Whisper 架构")
        }
    }
}

/// Default engines for builds without the MLX model layer (the app injects Engines/MLX*Engine);
/// tests inject fakes.
final class PlaceholderASREngine: ASREngine {
    var isLoaded = false
    func load(config: ModelConfig, path: String) async throws {
        throw BackendError.value("本地识别模型引擎尚未接入，请等待后续版本更新")
    }
    func warmup() async throws {}
    func unload() async {}
    func transcribe(_ pcm: Data) async throws -> (text: String, elapsedMS: Int) {
        throw BackendError.value("本地识别模型引擎尚未接入，请等待后续版本更新")
    }
}

final class PlaceholderTranslatorEngine: TranslatorEngine {
    var isLoaded = false
    var modelID = ""
    func load(config: TranslationConfig, path: String) async throws {
        throw BackendError.value("本地翻译模型引擎尚未接入，请等待后续版本更新")
    }
    func warmup() async throws {}
    func unload() async {}
    func stream(_ text: String, target: String, context: [(String, String)]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

enum BackendJob {
    case load(ModelConfig, String)
    case loadAPI(ModelConfig, String)
    case infer(SegmentJob)
    case streamFinal(StreamFinal)
    case finish(String)
    case loadTranslator(TranslationConfig, String)
    case unloadTranslator
}

/// One in-flight translation; class identity mirrors the Python dict passed between worker calls.
final class TranslationJob {
    let unitID: Int
    let sessionID: String
    let segmentID: Int
    let source: String
    var cancelled = false
    var target = ""
    var text = ""
    var revision = 0
    var sent = 0.0
    var started = 0.0
    var stream: AsyncThrowingStream<String, Error>.Iterator?

    init(unitID: Int, sessionID: String, segmentID: Int, source: String) {
        self.unitID = unitID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.source = source
    }
}

final class SegmentSink {
    var items: [SegmentJob] = []
}

/// Port of backend/server.py. The actor's mailbox replaces the Condition(RLock) domain: audio
/// boundaries, the job queue, and recognition feedback all mutate here, one message at a time.
actor BackendCore {
    static let maxPendingTranslations = 4
    static let translatorBusy = ["downloading", "loading", "warming"]

    private weak var channel: (any BackendEventSink)?
    private var pendingEvents: [[String: Any]] = []
    private let root: URL
    private let asr: ASREngine
    private let apiRecognizer: APIRecognizing
    private let translator: TranslatorEngine

    private(set) var alive = true
    private var active = false
    private(set) var state = "idle"
    private(set) var session = ""
    private var request = ""
    private(set) var config = ModelConfig()
    private(set) var translation = TranslationConfig()
    private(set) var translatorState = "idle"
    private var translatorDetail = ""
    private let recognition = RecognitionCache()
    private let planner = TranslationPlanner()
    private var context: [(target: String, session: String, source: String, text: String)] = []
    private var nextUnitID = 0
    private var overloadSession: String?

    private var jobs: [BackendJob] = []
    private(set) var preview: SegmentJob?
    private(set) var finalSegments: Set<Int> = []
    private var pending = Data()
    private var seq = 0
    private var samples = 0
    private(set) var segmenter: Segmenter?
    private(set) var vad: WebRTCVAD?
    private var sink = SegmentSink()
    private var translating: TranslationJob?
    private var translations: [TranslationJob] = []

    private let configPath: URL
    private let translationPath: URL
    private var bootErrors: [String] = []
    private var bootFlushed = false
    private var pumping = false

    init(root: URL, asrEngine: ASREngine = PlaceholderASREngine(),
         apiRecognizer: APIRecognizing = APIRecognizer(),
         translator: TranslatorEngine = PlaceholderTranslatorEngine()) {
        self.root = root
        self.asr = asrEngine
        self.apiRecognizer = apiRecognizer
        self.translator = translator
        configPath = root.appendingPathComponent("config.json")
        translationPath = root.appendingPathComponent("translation.json")
        if let data = FileManager.default.contents(atPath: configPath.path) {
            do {
                config = try ModelConfig.parse(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            } catch {
                bootErrors.append("保存的配置无效，已恢复默认值")
            }
        }
        if let data = FileManager.default.contents(atPath: translationPath.path) {
            do {
                translation = try TranslationConfig.parse(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            } catch {
                bootErrors.append("保存的翻译配置无效，已恢复默认值")
            }
        }
    }

    func attach(_ sink: any BackendEventSink) {
        channel = sink
        for event in pendingEvents { sink.deliver(event) }
        pendingEvents.removeAll()
    }

    // Test hooks (tests compile in the same module; the Python tests mutated Server attributes directly).
    func prepareForTest(state: String? = nil, config: ModelConfig? = nil, translation: TranslationConfig? = nil) {
        if let state { self.state = state }
        if let config { self.config = config }
        if let translation { self.translation = translation }
    }

    var jobCount: Int { jobs.count }
    var currentAPIKey: String { apiRecognizer.key }
    var recognitionEntryCount: Int { recognition.entries.count }

    private func send(_ event: [String: Any]) {
        var full: [String: Any] = ["protocol_version": 1, "session_id": session, "request_id": request]
        for (key, value) in event { full[key] = value }
        // attach() runs as a detached Task and may lose the race with the first command
        // (hello); buffer until the sink is present so no reply is ever dropped.
        if let channel {
            channel.deliver(full)
        } else {
            pendingEvents.append(full)
        }
    }

    private func status(_ state: String, _ detail: String = "") {
        self.state = state
        send(["type": "status", "state": state, "detail": detail])
    }

    private func translatorStatus(_ state: String, _ detail: String = "") {
        translatorState = state
        translatorDetail = detail
        send(["type": "translator", "state": state, "detail": detail,
              "config": translation.asDict, "active_model": translator.modelID])
    }

    private func enqueue(_ item: SegmentJob) {
        var item = item
        item.sessionID = session
        if item.final {
            finalSegments.insert(item.segmentID)
            preview = nil
            jobs.append(.infer(item))
        } else {
            preview = item
        }
        schedule()
    }
    func enqueueForTest(_ item: SegmentJob) { enqueue(item) }

    /// Mirrors the Python tests feeding self.s.segmenter directly: emits become queued work immediately.
    func feedForTest(_ pcm: Data, _ voiced: Bool) throws {
        guard let segmenter else { throw BackendError.value("会话未开始") }
        try segmenter.feed(pcm, voiced)
        drainSink()
    }

    private func schedule() {
        guard !pumping, alive else { return }
        pumping = true
        Task { [weak self] in await self?.pumpLoop() }
    }

    var isBusy: Bool { pumping }

    private func pumpLoop() async {
        while alive {
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                active = true
                await run(job)
                active = false
            } else if translating != nil || !translations.isEmpty {
                // Translation outranks previews but yields to every queued job between tokens.
                active = false
                await runTranslation()
            } else if let item = preview {
                preview = nil
                active = true
                await run(.infer(item))
                active = false
            } else {
                pumping = false
                return
            }
        }
        pumping = false
    }

    func flush() throws {
        guard state == "recording" else { return }
        status("finalizing", "正在处理最后一段语音…")
        if segmenter != nil {
            if !pending.isEmpty {
                var pcm = pending
                if pcm.count < Backend.frame * 2 { pcm.append(Data(repeating: 0, count: Backend.frame * 2 - pcm.count)) }
                pending = Data()
                try segmenter?.feed(pcm, vad?.isSpeech(pcm) ?? false)
                drainSink()
            }
            segmenter?.flush()
            drainSink()
        }
        preview = nil
        jobs.append(.finish(session))
        schedule()
    }

    private func drainSink() {
        guard !sink.items.isEmpty else { return }
        let items = sink.items
        sink.items = []
        for item in items { enqueue(item) }
    }

    private func maybeQueueTranslatorLoad() {
        if translation.enabled && translation.provider == "local" && !translator.isLoaded &&
            !Self.translatorBusy.contains(translatorState) {
            queueTranslatorLoad(translation)
        }
    }

    private func queueTranslatorLoad(_ config: TranslationConfig, path: String = "") {
        translatorStatus("loading", "等待加载翻译模型…")
        jobs.append(.loadTranslator(config, path))
        schedule()
    }

    private func run(_ job: BackendJob) async {
        do {
            switch job {            case .loadAPI(let config, let key):
                if config.apiProtocol == "openai" {
                    try apiRecognizer.load(config: config, key: key)
                } else {
                    apiRecognizer.clearKey()
                }
                await asr.unload()
                recognition.clear()
                try config.save(configPath)
                self.config = config
                send(["type": "config", "config": config.asDict])
                status("ready", "识别 API 已就绪 · 语音片段将发送到所选服务")
                maybeQueueTranslatorLoad()
            case .load(let config, let path):
                status("loading", "加载模型到本机内存…")
                var config = config
                var resolved = path
                if resolved.isEmpty {
                    (resolved, config.revision) = try ModelCache.resolve(modelID: config.modelID, revision: config.revision,
                        cache: root.appendingPathComponent("models")) {
                        try ASRValidation.validate(config: config, path: $0)
                    }
                }
                recognition.clear()
                try await asr.load(config: config, path: resolved)
                status("warming", "正在预热模型…")
                try await asr.warmup()
                apiRecognizer.clearKey()
                try config.save(configPath)
                self.config = config
                send(["type": "config", "config": config.asDict])
                status("ready", "模型已就绪 · 本地推理")
                maybeQueueTranslatorLoad()
            case .infer(let item):
                try await runInfer(item)
            case .streamFinal(let value):
                let valid = value.sessionID == session
                if valid {
                    send(["type": "final", "text": value.text, "elapsed_ms": 0,
                          "session_id": value.sessionID, "segment_id": value.segmentID,
                          "revision": value.revision, "start_sample": value.startSample,
                          "forced_cut": value.forcedCut])
                    if !value.text.isEmpty { planTranslation(sessionID: value.sessionID, segmentID: value.segmentID, forcedCut: value.forcedCut, text: value.text) }
                }
            case .finish(let session):
                queueUnit(session: session, unit: planner.flush(session: session))
                if session == self.session {
                    status("ready", "尾句处理完成")
                }
            case .loadTranslator, .unloadTranslator:
                do {
                    try await translatorJob(job)
                } catch {
                    var loadFailed = false
                    if case .loadTranslator = job { loadFailed = true }
                    translatorFailure(error, loadFailed: loadFailed)
                }
            }
        } catch {
            recognition.clear()
            let dropped = jobs
            jobs.removeAll()
            preview = nil
            if dropped.contains(where: { job in if case .loadTranslator = job { return true }; return false }) {
                translatorStatus(translator.isLoaded ? "ready" : "idle")
            }
            status("error", backendErrorText(error))
            send(["type": "error", "message": "识别处理失败 (\(backendErrorKind(error))): \(backendErrorMessage(error))。已确认文字仍保留，可重新加载识别服务恢复。"])
        }
    }

    private func runInfer(_ item: SegmentJob) async throws {
        let recognizer: Transcriber = config.provider == "api" ? apiRecognizer : asr
        let captured = item
        let text: String
        let duration: Int
        (text, duration) = try await recognition.transcribe(recognizer, config: config, item: item) { [weak self] in
            await self?.isObsolete(captured) ?? true
        }
        let valid = item.sessionID == session && (item.final || !finalSegments.contains(item.segmentID))
        if valid {
            send(["type": item.final ? "final" : "partial", "text": text, "elapsed_ms": duration,
                  "session_id": item.sessionID, "segment_id": item.segmentID, "revision": item.revision,
                  "start_sample": item.startSample, "end_sample": item.endSample, "forced_cut": item.forcedCut])
            if item.final {
                planTranslation(sessionID: item.sessionID, segmentID: item.segmentID, forcedCut: item.forcedCut, text: text)
            } else {
                segmenter?.acceptPreview(item: item, text: text)
                drainSink()
            }
        }
        if item.final {
            recognition.forget(item)
            finalSegments.remove(item.segmentID)
        }
    }

    private func isObsolete(_ item: SegmentJob) -> Bool {
        item.sessionID != session || (!item.final && finalSegments.contains(item.segmentID))
    }

    // MARK: - Translation (worker-only; failures never touch the ASR state or its queue)

    private func translatorJob(_ job: BackendJob) async throws {
        switch job {
        case .unloadTranslator:
            cancelTranslations()
            await translator.unload()
            translatorStatus("idle", "实时翻译已关闭")
        case .loadTranslator(let config, let path):
            translatorStatus("loading", "加载翻译模型到本机内存…")
            var config = config
            var resolved = path
            if resolved.isEmpty {
                (resolved, config.revision) = try ModelCache.resolve(modelID: config.modelID, revision: config.revision,
                    cache: root.appendingPathComponent("models"),
                    validate: { try validateTranslator($0) },
                    missing: "翻译模型尚未下载，请在设置 → 翻译中点击「下载翻译模型」。")
            }
            try validateTranslator(URL(fileURLWithPath: resolved))
            // Suspended generators hold the previous model; end them before it is released.
            cancelTranslations()
            try await translator.load(config: config, path: resolved)
            translatorStatus("warming", "正在预热翻译模型…")
            try await translator.warmup()
            config.enabled = true
            config.targetLanguage = translation.targetLanguage
            try config.save(translationPath)
            translation = config
            translatorStatus("ready", "翻译模型已就绪 · 本地推理")
        default:
            break
        }
    }

    private func runTranslation() async {
        do {
            try await translationStep()
        } catch {
            translatorFailure(error, loadFailed: false)
        }
    }

    /// Translator failures never touch the ASR state or its queue (server.py translator_job catch).
    private func translatorFailure(_ error: Error, loadFailed: Bool) {
        cancelTranslations()
        if !translator.isLoaded && translation.enabled {
            translation.enabled = false
            try? translation.save(translationPath)
        }
        let label = loadFailed ? "翻译模型加载失败" : "翻译失败"
        send(["type": "error", "message": "\(label) (\(backendErrorKind(error))): \(backendErrorMessage(error))。原文不受影响。"])
        translatorStatus(translator.isLoaded ? "ready" : "error", "\(label)：\(backendErrorMessage(error))")
    }

    private func planTranslation(sessionID: String, segmentID: Int, forcedCut: Bool, text: String) {
        guard translation.enabled && translation.provider == "local" && translator.isLoaded else { return }
        let unit = planner.add(session: sessionID, segmentID: segmentID, text: text, forcedCut: forcedCut)
        queueUnit(session: sessionID, unit: unit)
    }

    private func queueUnit(session: String, unit: TranslationUnit?) {
        guard let unit, !TranslationText.alreadyInTarget(unit.source, translation.targetLanguage) else { return }
        var dropped: [TranslationJob] = []
        while translations.count >= Self.maxPendingTranslations {
            dropped.append(translations.removeFirst())
        }
        nextUnitID += 1
        let job = TranslationJob(unitID: nextUnitID, sessionID: session, segmentID: unit.anchorSegment, source: unit.source)
        for old in dropped { endTranslation(old) }
        if !dropped.isEmpty && overloadSession != session {
            overloadSession = session
            send(["type": "error", "message": "翻译跟不上语速，已跳过部分句子的译文；原文不受影响。"])
        }
        send(["type": "translation", "session_id": session, "segment_id": job.segmentID,
              "unit_id": job.unitID, "revision": 0, "text": "", "done": false])
        translations.append(job)
        schedule()
    }

    private func translationStep() async throws {
        if translating == nil, !translations.isEmpty {
            translating = translations.removeFirst()
        }
        guard let job = translating else { return }
        if job.cancelled || !translation.enabled || translation.provider != "local" || !translator.isLoaded {
            return finishTranslation(job)
        }
        if job.stream == nil {
            let target = translation.targetLanguage
            let pairs = context.filter { $0.target == target && $0.session == job.sessionID }
                .map { ($0.source, $0.text) }
            job.target = target
            job.text = ""
            job.revision = 0
            job.sent = backendNow()
            job.started = backendNow()
            let stream: AsyncThrowingStream<String, Error> = translator.stream(job.source, target: target, context: pairs)
            job.stream = stream.makeAsyncIterator()
        }
        guard var iterator = job.stream else { return finishTranslation(job) }
        while let text = try await iterator.next() {
            job.text = text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && backendNow() - job.sent >= 0.2 {
                job.revision += 1
                job.sent = backendNow()
                send(["type": "translation", "session_id": job.sessionID, "segment_id": job.segmentID,
                      "unit_id": job.unitID, "revision": job.revision,
                      "text": text.trimmingCharacters(in: .whitespacesAndNewlines), "done": false])
            }
            if !jobs.isEmpty || job.cancelled || !alive {
                job.stream = iterator
                return  // Suspended between tokens; queued ASR work runs first.
            }
        }
        job.stream = nil
        let finalText = job.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty && !TranslationText.sameText(finalText, job.source) {
            context.append((job.target, job.sessionID, job.source, finalText))
            if context.count > TranslationText.contextPairs { context.removeFirst() }
            return finishTranslation(job, text: finalText)
        }
        finishTranslation(job)
    }

    private func finishTranslation(_ job: TranslationJob, text: String = "") {
        if translating === job { translating = nil }
        endTranslation(job, text: text)
    }

    /// An empty final text means skipped: same language, overload, or cancellation.
    private func endTranslation(_ job: TranslationJob, text: String = "") {
        job.stream = nil
        let elapsed = job.started > 0 ? Int((backendNow() - job.started) * 1000) : 0
        send(["type": "translation", "session_id": job.sessionID, "segment_id": job.segmentID,
              "unit_id": job.unitID, "revision": job.revision + 1, "text": text, "done": true,
              "skipped": text.isEmpty, "elapsed_ms": elapsed])
    }

    /// Safe from any thread: queued jobs have no stream; the running one is only flagged.
    private func dropPendingTranslations() {
        let pendingJobs = translations
        translations.removeAll()
        translating?.cancelled = true
        for job in pendingJobs { endTranslation(job) }
        schedule()
    }

    /// Worker thread only, because it closes the running generator.
    private func cancelTranslations() {
        dropPendingTranslations()
        if let job = translating {
            translating = nil
            endTranslation(job)
        }
    }

    // MARK: - Commands (control())

    func control(_ message: [String: Any]) {
        guard alive else { return }
        do {
            if !bootFlushed {
                bootFlushed = true
                for message in bootErrors { send(["type": "error", "message": message]) }
                bootErrors.removeAll()
            }
            guard message["protocol_version"] as? Int == 1 else { throw BackendError.value("协议版本不兼容") }
            request = message["request_id"] as? String ?? ""
            switch message["command"] as? String ?? "" {
            case "hello":
                send(["type": "config", "config": config.asDict])
                translatorStatus(translatorState, translatorDetail)
                status(state, "请加载本地模型，或下载默认模型")
            case "load", "download":
                try handleLoad(message)
            case "translation_settings":
                try handleTranslationSettings(message)
            case "asr_stream_final":
                try handleStreamFinal(message)
            case "cancel_download":
                break  // Downloader arrives in Phase 4; there is nothing to cancel yet.
            case "start":
                try handleStart(message)
            case "stop":
                if message["session_id"] as? String == session { try flush() }
            case "shutdown":
                alive = false
            default:
                throw BackendError.value("未知控制指令")
            }
        } catch {
            send(["type": "error", "message": backendErrorText(error)])
        }
    }

    private func handleLoad(_ message: [String: Any]) throws {
        let cmd = message["command"] as? String ?? ""
        if message["role"] as? String ?? "asr" == "translator" {
            guard !Self.translatorBusy.contains(translatorState) else { throw BackendError.value("请等待翻译模型操作结束") }
            var values = translation.asDict
            if let extra = message["translation"] as? [String: Any] { for (key, value) in extra { values[key] = value } }
            let config = try TranslationConfig.parse(values)
            guard config.provider == "local" else { throw BackendError.value("请先选择本地模型翻译") }
            if cmd == "download" {
                throw BackendError.value("下载功能尚未接入，请等待后续版本更新")
            } else {
                queueTranslatorLoad(config)
            }
            return
        }
        guard message["role"] as? String ?? "asr" == "asr" else { throw BackendError.value("未知模型角色") }
        guard ["idle", "ready", "error"].contains(state), !active, jobs.isEmpty else {
            throw BackendError.value("请等待当前操作结束再切换模型")
        }
        let values = message["config"] as? [String: Any] ?? config.asDict
        let config = try ModelConfig.parse(values)
        if cmd == "download" {
            if config.provider == "api" { throw BackendError.value("API 服务无需下载，请使用加载 / 切换") }
            if !config.localModelPath.isEmpty { throw BackendError.value("本地目录无需下载，请使用加载") }
            throw BackendError.value("下载功能尚未接入，请等待后续版本更新")
        } else {
            status("loading")
            if config.provider == "api" {
                jobs.append(.loadAPI(config, message["api_key"] as? String ?? ""))
            } else {
                jobs.append(.load(config, config.localModelPath))
            }
            schedule()
        }
    }

    private func handleTranslationSettings(_ message: [String: Any]) throws {
        var values = translation.asDict
        for key in ["enabled", "target_language", "provider", "api_profile"] where message[key] != nil {
            values[key] = message[key]!
        }
        let config = try TranslationConfig.parse(values)
        let busy = Self.translatorBusy.contains(translatorState)
        if busy && (config.enabled != translation.enabled || config.provider != translation.provider) {
            throw BackendError.value("请等待翻译模型操作结束")
        }
        try config.save(translationPath)
        translation = config
        if busy {
            translatorStatus(translatorState, translatorDetail)
        } else if !config.enabled || config.provider == "api" {
            dropPendingTranslations()
            if !translator.isLoaded {
                translatorStatus("idle")
            } else {
                translatorStatus("loading", "正在关闭实时翻译…")
                jobs.append(.unloadTranslator)
                schedule()
            }
        } else if !translator.isLoaded {
            queueTranslatorLoad(config)
        } else {
            translatorStatus(translatorState, translatorDetail)
        }
    }

    private func handleStreamFinal(_ message: [String: Any]) throws {
        guard streaming(), message["session_id"] as? String == session,
              ["recording", "finalizing"].contains(state) else { return }  // Late result of an ended session.
        let segment = message["segment_id"]
        let text = message["text"]
        let start = message["start_sample"]
        guard let segment = segment.flatMap({ strictJSONInt($0) }), segment >= 1, !finalSegments.contains(segment),
              let text = text as? String, text.utf8.count <= 200_000,
              let start = start.flatMap({ strictJSONInt($0) }), start >= 0 else {
            throw BackendError.value("流式识别结果无效")
        }
        finalSegments.insert(segment)
        jobs.append(.streamFinal(StreamFinal(sessionID: session, segmentID: segment, revision: 1,
                                             startSample: start, forcedCut: false, text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
        schedule()
    }

    private func handleStart(_ message: [String: Any]) throws {
        guard state == "ready" else { throw BackendError.value("模型尚未就绪") }
        var values = config.asDict
        if let v = message["endpoint_mode"] { values["endpoint_mode"] = v }
        if let v = message["endpoint_silence_ms"] { values["endpoint_silence_ms"] = v }
        let newConfig = try ModelConfig.parse(values)
        if newConfig != config {
            try newConfig.save(configPath)
            config = newConfig
        }
        vad = try WebRTCVAD(aggressiveness: 2)
        session = message["session_id"] as? String ?? ""
        finalSegments.removeAll()
        pending = Data()
        seq = 0
        samples = 0
        // Streaming sessions get audio and sentence ends from the cloud via the app; no local VAD.
        if streaming() {
            segmenter = nil
        } else {
            sink = SegmentSink()
            segmenter = Segmenter(config: config) { [weak sink] in sink?.items.append($0) }
        }
        status("recording", "正在聆听…")
    }

    // MARK: - Audio

    func audio(_ payload: Data) {
        do {
            guard payload.count >= 4 else { throw BackendError.value("音频头过长") }
            let size = (Int(payload[0]) << 24) | (Int(payload[1]) << 16) | (Int(payload[2]) << 8) | Int(payload[3])
            guard size <= 4096, payload.count >= 4 + size else { throw BackendError.value("音频头过长") }
            let header = (try? JSONSerialization.jsonObject(with: payload.subdata(in: 4..<(4 + size))) as? [String: Any]) ?? [:]
            let pcm = payload.subdata(in: (4 + size)..<payload.count)
            guard state == "recording", header["session_id"] as? String == session else { return }
            guard segmenter != nil else { throw BackendError.value("流式识别会话的音频由应用直接发送，后端不接收音频") }
            guard header["sequence"] as? Int == seq, header["start_sample"] as? Int == samples else {
                try flush()
                throw BackendError.value("音频序号不连续，已停止采集并处理已接收音频")
            }
            guard header["sample_rate"] as? Int == Backend.rate, header["channels"] as? Int == 1,
                  header["format"] as? String == "s16le", pcm.count % 2 == 0 else {
                try flush()
                throw BackendError.value("音频格式必须为 16 kHz 单声道 PCM16")
            }
            seq += 1
            samples += pcm.count / 2
            pending.append(pcm)
            while pending.count >= Backend.frame * 2 {
                let frame = pending.prefix(Backend.frame * 2)
                pending.removeFirst(Backend.frame * 2)
                try segmenter?.feed(Data(frame), vad?.isSpeech(Data(frame)) ?? false)
            }
            drainSink()
            // Stop accepting audio before the finite final queue can grow indefinitely.
            if jobs.count >= 6 {
                send(["type": "error", "message": "推理落后：已自动停止录音，正在完成已接收语音。请等待处理完成后再开始。"])
                try flush()
            }
        } catch {
            send(["type": "error", "message": backendErrorText(error)])
        }
    }

    private func streaming() -> Bool {
        config.provider == "api" && config.apiProtocol == "qwen_realtime"
    }

    /// Python's shutdown simply terminates the process; the in-process core releases its engines instead.
    func shutdown() async {
        alive = false
        translating = nil
        translations.removeAll()
        preview = nil
        jobs.removeAll()
        segmenter = nil
        vad = nil
        await asr.unload()
        await translator.unload()
    }
}
