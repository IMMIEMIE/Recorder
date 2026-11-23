import SwiftUI

enum AIPurpose: String, CaseIterable, Identifiable {
    case summary = "总结摘要", translation = "翻译文本", question = "自定义提问"
    var id: String { rawValue }
}

@MainActor
final class AIWorkspace: ObservableObject {
    @Published var source = ""
    @Published private(set) var result = ""
    @Published private(set) var reasoningSummary = ""
    @Published var error = ""
    @Published var purpose: AIPurpose = .summary
    @Published var targetLanguage = "简体中文"
    @Published var question = ""
    @Published private(set) var running = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var recordingID: String?
    private var originalTranscript = ""
    private let service: () throws -> (AIServiceConfiguration, String)

    init(service: @escaping () throws -> (AIServiceConfiguration, String) = {
        guard let profile = AIProfiles.shared.selected else { throw AIError.message("请先在设置 → AI 服务中保存配置") }
        guard let key = try APIKeyStore.read(endpoint: profile.baseURL), !key.isEmpty else {
            throw AIError.message("请在设置 → AI 服务中填写并保存 API Key")
        }
        return (profile.configuration, key)
    }) {
        self.service = service
        targetLanguage = UserDefaults.standard.string(forKey: "ai.targetLanguage") ?? "简体中文"
    }

    var instruction: String {
        switch purpose {
        case .summary: return "请用简体中文总结以下文本：先给简短摘要，再列关键要点；仅在原文确有提及时列出待办与决定。保留关键数字、姓名和不确定性，不添加事实。可用 Markdown 标题和列表组织回答。"
        case .translation: return "请将以下文本完整、准确地翻译为\(targetLanguage)。保留段落、数字和专有名词，结合上下文表达。只输出译文，不总结、不省略内容。"
        case .question: return question
        }
    }

    func prepare(text: String, recordingID: String) {
        let changedRecording = self.recordingID != recordingID
        guard changedRecording || originalTranscript != text else { return }
        if running { cancel() }
        if changedRecording { question = "" }
        self.recordingID = recordingID
        originalTranscript = text
        source = text
        result = ""
        reasoningSummary = ""
        error = ""
        status = ""
    }

    func send() {
        guard !running else { return }
        error = ""
        if purpose == .translation {
            guard !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写目标语言"; return }
            UserDefaults.standard.set(targetLanguage, forKey: "ai.targetLanguage")
        }
        do {
            let (config, key) = try service()
            let text = source, instruction = self.instruction
            _ = try AIClient.request(config: config, key: key, instruction: instruction, text: text)
            let id = UUID()
            requestID = id
            result = ""
            reasoningSummary = ""
            running = true
            status = "正在请求…"
            task = Task { [weak self] in
                do {
                    try await AIClient().stream(config: config, key: key, instruction: instruction, text: text, onReasoning: { [weak self] update in
                        guard let self, self.requestID == id else { return }
                        if case let .summary(delta) = update { self.reasoningSummary += delta }
                        if self.result.isEmpty { self.status = "服务正在推理…" }
                    }) { [weak self] delta in
                        guard let self, self.requestID == id else { return }
                        self.result += delta
                        self.status = "正在生成回答…"
                    }
                    guard let self, self.requestID == id else { return }
                    self.status = "完成"
                } catch {
                    guard let self, self.requestID == id else { return }
                    self.error = error.localizedDescription
                    self.status = "未完成"
                }
                guard let self, self.requestID == id else { return }
                self.running = false
                self.task = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        running = false
        status = result.isEmpty ? "已停止" : "已停止，已保留部分回答"
    }

    func copyResult() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
    func saveResult() { TextExport.save(result) { [weak self] message in self?.error = message } }
}

struct AIWorkspaceView: View {
    @ObservedObject var ai: AIWorkspace
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profiles: AIProfiles = .shared
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 提问", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Button("关闭") {
                    if ai.running { ai.cancel() }
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }

            Picker("任务", selection: $ai.purpose) {
                ForEach(AIPurpose.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(ai.running)
            if ai.purpose == .translation {
                TextField("目标语言", text: $ai.targetLanguage).disabled(ai.running)
            }
            if ai.purpose == .question {
                TextField("例如：这段内容的主要结论是什么？", text: $ai.question, axis: .vertical)
                    .lineLimit(2...4).disabled(ai.running)
            }
            DisclosureGroup("原文（\(ai.source.count) 字，可编辑）", isExpanded: $showSource) {
                TextEditor(text: $ai.source).font(.body).frame(height: 84)
                    .disabled(ai.running).border(.secondary.opacity(0.2))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("回答").font(.headline)
                    Spacer()
                    Button { ai.copyResult() } label: { Label("复制", systemImage: "doc.on.doc") }
                    Button("另存为…") { ai.saveResult() }
                }
                .buttonStyle(.borderless).disabled(ai.result.isEmpty)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !ai.reasoningSummary.isEmpty {
                            DisclosureGroup("服务提供的推理摘要") {
                                Text(verbatim: ai.reasoningSummary)
                                    .font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                            .foregroundStyle(.secondary)
                        }
                        if !ai.result.isEmpty {
                            AIAnswerMarkdown(ai: ai)
                        } else {
                            Text(LocalizedStringKey(ai.status.isEmpty ? "发送提问后，可在这里阅读回答。" : ai.status))
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            if !ai.error.isEmpty { Text(ai.error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let profile = profiles.selected { Text("发送当前原文到 \(profile.baseURL)") }
                    else { Text("尚未配置 AI 服务") }
                    if !ai.status.isEmpty, !ai.result.isEmpty { Text(LocalizedStringKey(ai.status)) }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                if ai.running {
                    ProgressView().controlSize(.small)
                    Button("停止") { ai.cancel() }
                } else {
                    Button("发送提问") { ai.send() }.buttonStyle(.borderedProminent)
                        .disabled(ai.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 690, height: 650)
        .onDisappear { if ai.running { ai.cancel() } }
    }
}
