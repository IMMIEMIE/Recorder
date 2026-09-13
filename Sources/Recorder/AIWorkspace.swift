import SwiftUI

enum AIPurpose: String, CaseIterable, Identifiable {
    case summary = "总结摘要", translation = "翻译文本", question = "自定义提问"
    var id: String { rawValue }
}

final class AIWorkspace: ObservableObject {
    @Published var source = ""
    @Published var result = ""
    @Published var error = ""
    @Published var purpose: AIPurpose = .summary
    @Published var targetLanguage = "简体中文"
    @Published var question = ""
    @Published var running = false
    @Published var status = ""
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init() {
        targetLanguage = UserDefaults.standard.string(forKey: "ai.targetLanguage") ?? "简体中文"
    }

    var instruction: String {
        switch purpose {
        case .summary: return "请用简体中文总结以下文本：先给简短摘要，再列关键要点；仅在原文确有提及时列出待办与决定。保留关键数字、姓名和不确定性，不添加事实。"
        case .translation: return "请将以下文本完整、准确地翻译为\(targetLanguage)。保留段落、数字和专有名词，结合上下文表达。只输出译文，不总结、不省略内容。"
        case .question: return question
        }
    }

    func prepare(text: String) {
        guard !running else { return }
        if source != text { source = text; result = ""; error = ""; status = "" }
    }

    func send() {
        guard !running else { return }
        error = ""
        guard !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || purpose != .translation else { error = "请填写目标语言"; return }
        UserDefaults.standard.set(targetLanguage, forKey: "ai.targetLanguage")
        do {
            guard let profile = AIProfiles.shared.selected else { throw AIError.message("请先在设置 → AI 服务中保存配置") }
            let config = profile.configuration
            guard let key = try APIKeyStore.read(endpoint: profile.baseURL), !key.isEmpty else { throw AIError.message("请在设置 → AI 服务中填写并保存 API Key") }
            let text = source, instruction = self.instruction
            _ = try AIClient.request(config: config, key: key, instruction: instruction, text: text)
            requestID = UUID(); let id = requestID
            result = ""; running = true; status = "正在请求…"
            task = Task { @MainActor [weak self] in
                do {
                    try await AIClient().stream(config: config, key: key, instruction: instruction, text: text) { [weak self] delta in
                        guard let self, self.requestID == id else { return }
                        self.result += delta; self.status = "正在生成…"
                    }
                    guard let self, self.requestID == id else { return }
                    self.status = "完成"
                } catch {
                    guard let self, self.requestID == id else { return }
                    if Task.isCancelled { self.status = "已停止" }
                    else { self.error = error.localizedDescription; self.status = "未完成" }
                }
                guard let self, self.requestID == id else { return }
                self.running = false; self.task = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        requestID = UUID()
        task?.cancel(); task = nil
        running = false; status = "已停止，已生成部分保留"
    }
    func copyResult() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
    func saveResult() { TextExport.save(result) { [weak self] message in self?.error = message } }
}

struct AIWorkspaceView: View {
    @ObservedObject var ai: AIWorkspace
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profiles = AIProfiles.shared
    @State private var showSource = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI 提问").font(.title2.bold())
                Spacer()
                Button { ai.copyResult() } label: { Image(systemName: "doc.on.doc") }.help("复制结果").disabled(ai.result.isEmpty)
                Button("另存为…") { ai.saveResult() }.disabled(ai.result.isEmpty)
                Button("关闭") { if ai.running { ai.cancel() }; dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
            Picker("任务", selection: $ai.purpose) { ForEach(AIPurpose.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(ai.running)
            if ai.purpose == .translation { TextField("目标语言", text: $ai.targetLanguage).disabled(ai.running) }
            if ai.purpose == .question {
                TextField("例如：这段内容的主要结论是什么？", text: $ai.question, axis: .vertical).lineLimit(2...4).disabled(ai.running)
            }
            DisclosureGroup("原文（\(ai.source.count) 字，可编辑）", isExpanded: $showSource) {
                TextEditor(text: $ai.source).font(.body).frame(height: 125).disabled(ai.running).border(.secondary.opacity(0.2))
            }
                }
            }.frame(height: showSource ? 220 : ai.purpose == .question ? 160 : ai.purpose == .translation ? 130 : 95)
            Divider()
            ScrollView {
                Text(ai.result.isEmpty ? "AI 回答会显示在这里" : ai.result)
                    .foregroundStyle(ai.result.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }.frame(minHeight: 150)
            if !ai.error.isEmpty { Text(ai.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发送当前原文到 \(profiles.selected?.baseURL ?? "未配置的 AI 服务")")
                    if !ai.status.isEmpty { Text(ai.status) }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                if ai.running { ProgressView().controlSize(.small); Button("停止") { ai.cancel() } }
                else { Button("发送提问") { ai.send() }.buttonStyle(.borderedProminent).disabled(ai.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.padding(24).frame(width: 690, height: 650)
            .onDisappear { if ai.running { ai.cancel() } }
    }
}
