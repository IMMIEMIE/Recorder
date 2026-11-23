import SwiftUI

/// Session list: "新建会话" on top, groups by last update, newest first.
struct SessionSidebar: View {
    @ObservedObject var model: AppModel
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var deleting: SessionSummary?

    private var groups: [(SessionGroup, [SessionSummary])] {
        let now = Date()
        let grouped = Dictionary(grouping: model.sessionSummaries) { SessionGroup.of(updatedAtMs: $0.updatedAtMs, now: now) }
        return SessionGroup.allCases.compactMap { group in grouped[group].map { (group, $0) } }
    }

    var body: some View {
        List(selection: Binding(get: { model.selectedSessionID }, set: { model.selectSession($0) })) {
            ForEach(groups, id: \.0) { group, items in
                Section(group.title) {
                    ForEach(items) { item in
                        row(item).tag(item.id).contextMenu { menu(item) }
                    }
                }
            }
        }
        .overlay {
            if model.sessionSummaries.isEmpty {
                Text(model.persistSessions ? "还没有会话记录" : "会话记录已关闭\n本次运行的会话不会保存")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Button { model.newSession() } label: {
                Label("新建会话", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).controlSize(.large)
            .disabled(model.sessionLocked)
            .help(model.sessionLocked ? "录制结束后才能新建会话" : "开始一个空白会话；当前会话保留在列表中")
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") { if let item = renaming { model.renameSession(item.id, to: renameText) }; renaming = nil }
        }
        .confirmationDialog("删除此会话？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("删除", role: .destructive) { model.deleteSession(item.id); deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { item in
            Text("「\(item.title)」的文字记录将从本机删除，无法撤销。")
        }
    }

    private func row(_ item: SessionSummary) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.tail)
                Text(Self.time(item.updatedAtMs)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.id == model.recordingSessionID {
                Image(systemName: "record.circle").foregroundStyle(DesignTokens.recording).help("录制中").accessibilityLabel("录制中")
            }
        }.padding(.vertical, 2)
    }

    @ViewBuilder private func menu(_ item: SessionSummary) -> some View {
        Button("重命名…") { renameText = item.title; renaming = item }
        Button("导出会话…") { model.exportRequest = SessionExportRequest(sessionID: item.id) }
        Divider()
        Button("删除…", role: .destructive) { deleting = item }
            .disabled(!model.canDeleteSession(item.id))
    }

    static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm"
            : Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

/// "继续录制 …" and reconnect markers inside a transcript.
struct SessionMarker: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }.padding(.vertical, 2)
    }
}

struct SessionExportSheet: View {
    @ObservedObject var model: AppModel
    let request: SessionExportRequest
    @AppStorage("sessions.export.format") private var format = SessionExportFormat.txt.rawValue
    @AppStorage("sessions.export.content") private var content = SessionExportContent.bilingual.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出会话").font(.title3.bold())
            Text(title).foregroundStyle(.secondary).lineLimit(2)
            Picker("格式", selection: $format) {
                ForEach(SessionExportFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.radioGroup)
            Picker("内容", selection: $content) {
                ForEach(SessionExportContent.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.radioGroup)
            Text("只导出已定稿的文字，不含识别中的文字、录音以及服务地址、API Key 等配置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…") {
                    let id = request.sessionID
                    let format = SessionExportFormat(rawValue: format) ?? .txt
                    let content = SessionExportContent(rawValue: content) ?? .bilingual
                    dismiss()
                    // The save panel attaches to the main window once this sheet has closed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.exportSession(id, format: format, content: content) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
        .onAppear { title = model.sessionForExport(request.sessionID)?.title ?? "" }
    }
}

struct SessionSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("会话记录").font(.title2.bold())
            Toggle("保存会话记录", isOn: $model.persistSessions)
            Text("开启时，每个会话定稿的原文和译文保存在本机（~/Library/Application Support/LocalRecorder/sessions），不会上传。录音、译音和识别中的文字从不保存。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("关闭后不再写入磁盘：已有会话仍可查看、导出和删除，新的会话只在本次运行期间保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("清空全部会话…", role: .destructive) { confirmClear = true }
                    .disabled(model.sessionLocked || model.sessionSummaries.isEmpty)
                Spacer()
                Text("共 \(model.sessionSummaries.count) 个会话").font(.caption).foregroundStyle(.secondary)
            }
            if model.sessionLocked { Text("录制结束后才能清空。").font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("清空全部会话？", isPresented: $confirmClear) {
            Button("清空全部会话", role: .destructive) { model.deleteAllSessions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从本机删除全部 \(model.sessionSummaries.count) 个会话的文字记录，无法撤销。")
        }
    }
}
