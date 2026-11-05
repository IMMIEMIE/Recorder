import Foundation
import Darwin
import CoreFoundation

/// Owns one bundled native helper. A completed session keeps weights loaded; unloading closes it.
final class HyLocalSession: LiveTranslationSession, @unchecked Sendable {
    var onReady: (() -> Void)?
    var onEvent: ((LiveTranslationSessionEvent) -> Void)?
    var onEnd: ((String?) -> Void)?
    var onLoaded: (() -> Void)?
    var onLoadFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "recorder.hy.state")
    private let writer = DispatchQueue(label: "recorder.hy.stdin")
    private let lifecycle = DispatchQueue(label: "recorder.hy.lifecycle")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var received = Data()
    private var buffered = 0
    private var loaded = false
    private var ready = false
    private var finishing = false
    private var active = false
    private var sessionID = ""
    private var generation = UUID()
    private var epoch = UUID()
    private var deadline: DispatchWorkItem?
    private let loadTimeout: TimeInterval
    private let finishTimeout: TimeInterval

    init(loadTimeout: TimeInterval = 180, finishTimeout: TimeInterval = 90) {
        self.loadTimeout = loadTimeout; self.finishTimeout = finishTimeout
    }
    var isLoaded: Bool { queue.sync { loaded } }

    func load(executableURL: URL, modelURL: URL) throws {
        unload()
        queue.sync {
            let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = ["--model", modelURL.path]
            child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
            process = child; input = stdinPipe.fileHandleForWriting
            output = stdoutPipe.fileHandleForReading; errors = stderrPipe.fileHandleForReading
            let token = generation
            output?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.receive(data)
                }
            }
            // llama.cpp diagnostics never become transcript content or user-visible provider errors.
            errors?.readabilityHandler = { handle in if handle.availableData.isEmpty { handle.readabilityHandler = nil } }
            child.terminationHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token, self.process != nil else { return }
                    self.failRuntime("本地 Hy-SimulMT 进程已退出，请重新加载模型；已有文字已保留")
                }
            }
            // This serial queue waits for any previous process to exit before launching another
            // copy of the 20 GB model. Process waits never block the main or audio state queues.
            lifecycle.async { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    do { try child.run() }
                    catch { self.failRuntime("无法启动本地 Hy-SimulMT，请检查应用内的推理组件"); return }
                    self.arm(self.loadTimeout, message: "Hy-SimulMT 加载超时，请检查可用内存后重新加载")
                }
            }
        }
    }

    func start(configuration: LiveTranslateConfiguration, key: String, sessionID: String) throws {
        try queue.sync {
            guard loaded, process?.isRunning == true, !active else { throw AIError.message("请先加载本地 Hy-SimulMT 模型") }
            guard ["zh", "en"].contains(configuration.language) else { throw AIError.message("本地 Hy-SimulMT 仅支持中英互译") }
            epoch = UUID(); self.sessionID = sessionID; active = true; ready = false; finishing = false
            send(["type": "start", "session_id": sessionID, "language": configuration.language])
            arm(20, message: "Hy-SimulMT 会话启动超时，请重新加载模型")
        }
    }

    func append(_ pcm: Data) -> Bool {
        queue.sync {
            guard active, ready, !finishing, !pcm.isEmpty, pcm.count % 2 == 0, buffered + pcm.count <= 320_000 else { return false }
            // The helper's JSONL limit is per message; the input backlog limit is across all
            // messages. Split a large accepted PCM callback before base64 expands its wire size.
            var offset = 0
            while offset < pcm.count {
                let end = min(pcm.count, offset + 64_000)
                let chunk = pcm.subdata(in: offset..<end)
                send(["type": "audio", "session_id": sessionID, "pcm": chunk.base64EncodedString()], bytes: chunk.count)
                offset = end
            }
            return true
        }
    }
    func finish() {
        queue.async {
            guard self.active, self.ready, !self.finishing else { return }
            self.finishing = true
            self.send(["type": "finish", "session_id": self.sessionID])
            self.arm(self.finishTimeout, message: "Hy-SimulMT 尾句处理超时；已有文字已保留，末句可能不完整")
        }
    }
    func cancel() {
        queue.sync {
            if active { send(["type": "cancel", "session_id": sessionID]) }
            epoch = UUID(); active = false; ready = false; finishing = false; sessionID = ""
            if loaded { deadline?.cancel(); deadline = nil }
        }
    }
    func unload() { queue.sync { closeProcess() } }

    private func send(_ event: [String: Any], bytes: Int = 0) {
        var value = event; value["protocol_version"] = 1
        guard let input, var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10); buffered += bytes
        let token = generation
        writer.async { [weak self] in
            do {
                try input.write(contentsOf: data)
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.buffered -= bytes
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.failRuntime("无法向本地 Hy-SimulMT 发送音频；已有文字已保留")
                }
            }
        }
    }

    private func receive(_ data: Data) {
        received.append(data)
        guard received.count <= 4 * 1024 * 1024 else { failRuntime("Hy-SimulMT 返回的数据超过限制，已停止本地推理"); return }
        while let newline = received.firstIndex(of: 10) {
            let line = received[..<newline]; received.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  Self.integer(event["protocol_version"]) == 1, let type = event["type"] as? String else {
                failRuntime("Hy-SimulMT 本地协议不兼容，请更新应用"); return
            }
            if type == "hello" {
                guard !loaded else { continue }
                guard event["runtime_commit"] as? String == HyRuntimeAvailability.runtimeCommit,
                      let capabilities = event["capabilities"] as? [String],
                      Set(["interleave", "streaming_pcm", "bounded_context", "local_only"]).isSubset(of: Set(capabilities)) else {
                    failRuntime("Hy-SimulMT 推理版本或能力与应用不匹配，暂不可加载"); return
                }
                loaded = true; deadline?.cancel(); deadline = nil
                let token = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queue.sync(execute: { self.generation == token && self.loaded }) else { return }
                    self.onLoaded?()
                }
                continue
            }
            if type == "error", event["session_id"] == nil {
                failRuntime("Hy-SimulMT 无法加载模型，请检查模型文件、可用内存与推理组件"); return
            }
            guard active, event["session_id"] as? String == sessionID else { continue }
            switch type {
            case "ready":
                guard !ready else { continue }
                ready = true; deadline?.cancel(); deadline = nil
                post { $0.onReady?() }
            case "update":
                guard ready, let segment = Self.integer(event["segment_id"]), segment >= 0,
                      let start = Self.integer(event["start_sample"]), start >= 0,
                      let end = Self.integer(event["end_sample"]), end >= start,
                      let source = event["source"] as? String, let text = event["translation"] as? String,
                      let revision = Self.integer(event["revision"]), revision >= 0,
                      let sourceDone = Self.boolean(event["source_done"]),
                      let translationDone = Self.boolean(event["translation_done"]),
                      let committed = Self.boolean(event["committed"]) else {
                    failRuntime("Hy-SimulMT 返回无效字幕数据，已停止本地推理"); return
                }
                let update = LiveTranslationUpdate(segmentID: String(segment), startSample: start, endSample: end,
                    source: source, translation: text, revision: revision, sourceDone: sourceDone,
                    translationDone: translationDone, committed: committed)
                post { $0.onEvent?(.update(update)) }
            case "done":
                guard let complete = Self.boolean(event["complete"]), let cancelled = Self.boolean(event["cancelled"]),
                      let unresolved = Self.integer(event["unresolved_audio_ms"]), unresolved >= 0,
                      let skipped = Self.integer(event["skipped_untranslated_audio_ms"]), skipped >= 0 else {
                    failRuntime("Hy-SimulMT 未返回完整的会话结束状态，末句可能不完整"); return
                }
                end(complete && !cancelled && unresolved == 0 && skipped == 0 ? nil : "本地会话存在未完成翻译的音频；已有文字已保留，末句可能不完整")
            case "warning":
                guard event["code"] as? String == "unresolved_audio",
                      let start = Self.integer(event["start_sample"]), start >= 0,
                      let end = Self.integer(event["end_sample"]), end >= start else {
                    failRuntime("Hy-SimulMT 返回无效的音频处理状态"); return
                }
                post { $0.onEvent?(.untranslatedAudio(startSample: start, endSample: end)) }
            case "error":
                end("Hy-SimulMT 本次推理失败；已有文字已保留，请重新开始或加载模型")
            default: break
            }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["q", "i", "l", "s"].contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func post(_ callback: @escaping (HyLocalSession) -> Void) {
        let token = generation, attempt = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == token && self.epoch == attempt }) else { return }
            callback(self)
        }
    }
    private func end(_ message: String?) {
        guard active else { return }
        active = false; ready = false; finishing = false; deadline?.cancel(); deadline = nil
        post { $0.onEnd?(message) }
    }
    private func arm(_ seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let token = generation, attempt = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.epoch == attempt else { return }
            // A stuck inference cannot be safely reused; release the process and its GPU memory.
            self.failRuntime(message)
        }
        deadline = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func failRuntime(_ message: String) {
        let wasActive = active, callback = onEnd, failure = onLoadFailure
        closeProcess()
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == token }) else { return }
            if wasActive { callback?(message) }; failure?(message)
        }
    }
    private func closeProcess() {
        generation = UUID(); epoch = UUID(); deadline?.cancel(); deadline = nil
        loaded = false; ready = false; active = false; finishing = false; sessionID = ""
        received.removeAll(); buffered = 0
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        let child = process; process = nil
        // Termination also releases a blocked pipe writer. No audio or transcript is written to disk.
        if let child {
            if child.isRunning { child.terminate() }
            lifecycle.async {
                let deadline = Date().addingTimeInterval(2)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                if child.processIdentifier > 0 { child.waitUntilExit() }
            }
        }
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
    }
    deinit { if process?.isRunning == true { process?.terminate() } }
}
